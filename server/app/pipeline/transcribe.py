"""
Audio -> flat text + speaker turns, through the OpenAI API. Ported from the desktop app's transcribe.py,
with the same hard-won behaviour:

  - 25 MB upload cap          -> text pass gets 16 kHz mono AAC (~4 KB/s); longer files are cut in chunks
  - diarize cap (1400 s)      -> speaker pass runs in 5-min chunks cut at silences, never mid-sentence
  - labels reset per request  -> chunks 2..n are anchored on chunk 1's voices (2-8 s reference clips)
  - the speaker model TRANSLATES French into English at 16 kHz / <=64 kbps, and drifts into English
    when no language is given -> speaker chunks are encoded at 24 kHz / 80 kbps, and in auto-detect mode
    a 30-s text probe supplies the language
  - the `languages` param is rejected (400) by diarize: pass `language=` instead

Server differences: the source is decoded ONCE to a 16 kHz WAV on disk plus a 200 ms loudness envelope,
so memory stays flat even on a 4-hour recording; progress is reported per stage / per speaker chunk.
"""
import base64
import concurrent.futures as cf
import hashlib
import io
import json
import logging
import os
import re
import wave

import av
import numpy as np

log = logging.getLogger("parley.pipeline")

RATE = 16000
WIN = 0.2                                   # loudness envelope resolution (s)
DIARIZE_MAX_S = float(os.environ.get("TRANSCRIBE_CHUNK_S", 1400))
DIA_RATE, DIA_BITRATE = 24000, 80000
DIA_CHUNK_S = float(os.environ.get("TRANSCRIBE_DIA_CHUNK_S", 300))
UPLOAD_MAX_MB = 24


class Cancelled(Exception):
    pass


class Cache:
    """Finished pieces of one job (text, language probe, each speaker chunk, AI passes), so a retry
    resumes where the failure happened. Text only, never audio. Keyed by inputs."""

    def __init__(self, folder):
        self.dir = folder
        self.hits = 0

    def _path(self, name, inputs):
        h = hashlib.sha1(json.dumps(inputs, sort_keys=True, ensure_ascii=False, default=str)
                         .encode("utf-8")).hexdigest()[:12]
        return os.path.join(self.dir, "%s_%s.json" % (name, h))

    def get(self, name, inputs):
        try:
            with open(self._path(name, inputs), encoding="utf-8") as fh:
                v = json.load(fh)
            self.hits += 1
            return v
        except (OSError, ValueError):
            return None

    def put(self, name, inputs, value):
        try:
            os.makedirs(self.dir, exist_ok=True)
            p = self._path(name, inputs)
            with open(p + ".tmp", "w", encoding="utf-8") as fh:
                json.dump(value, fh, ensure_ascii=False)
            os.replace(p + ".tmp", p)
        except OSError as e:
            log.warning("cache write failed: %s", e)


# ------------------------------------------------------------------ audio ----
def _decode_iter(path, rate):
    """Any container (m4a, mp4, mov, wav, mp3...) -> int16 mono blocks at `rate`. Video is ignored."""
    inp = av.open(path)
    try:
        if not inp.streams.audio:
            raise ValueError("no_audio_stream")
        r = av.AudioResampler(format="s16", layout="mono", rate=rate)
        for fr in inp.decode(audio=0):
            fr.pts = None
            for rf in r.resample(fr):
                yield rf.to_ndarray().reshape(-1).astype(np.int16)
        for rf in r.resample(None):
            yield rf.to_ndarray().reshape(-1).astype(np.int16)
    finally:
        inp.close()


def probe_duration(path):
    """Seconds of audio, read from the container, decoding only if the container does not say."""
    inp = av.open(path)
    try:
        if not inp.streams.audio:
            raise ValueError("no_audio_stream")
        st = inp.streams.audio[0]
        if st.duration and st.time_base:
            return float(st.duration * st.time_base)
        if inp.duration:
            return inp.duration / 1_000_000
    finally:
        inp.close()
    n = sum(len(b) for b in _decode_iter(path, 8000))
    return n / 8000


class Audio:
    """The source decoded once: a 16 kHz mono WAV on disk (random access for chunks and voice clips)
    and a 200 ms RMS envelope (cut planning)."""

    def __init__(self, src, workdir):
        self.src = src
        self.wav = os.path.join(workdir, "pcm16k.wav")
        W = int(RATE * WIN)
        env, carry, n = [], np.zeros(0, np.int16), 0
        with wave.open(self.wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            for blk in _decode_iter(src, RATE):
                w.writeframes(blk.tobytes())
                n += len(blk)
                buf = np.concatenate([carry, blk])
                k = len(buf) // W
                if k:
                    env.append(np.sqrt(np.mean(buf[:k * W].reshape(k, W).astype(np.float64) ** 2, axis=1)))
                carry = buf[k * W:]
        self.env = np.concatenate(env) if env else np.zeros(0)
        self.samples = n
        self.duration = n / RATE

    def read(self, start_s, end_s):
        a = max(0, int(start_s * RATE))
        b = min(self.samples, int(end_s * RATE))
        if b <= a:
            return np.zeros(0, np.int16)
        with wave.open(self.wav, "rb") as w:
            w.setpos(a)
            return np.frombuffer(w.readframes(b - a), dtype=np.int16)

    def blocks(self, start_s, end_s, block_s=60):
        t = start_s
        while t < end_s:
            yield self.read(t, min(end_s, t + block_s))
            t += block_s


class _Enc:
    """Streaming mono AAC encoder."""

    def __init__(self, path, rate, bitrate):
        self.out = av.open(path, "w")
        self.st = self.out.add_stream("aac", rate=rate)
        self.st.bit_rate = bitrate
        try:
            self.st.layout = "mono"
        except Exception:
            self.st.codec_context.layout = "mono"
        self.rate = rate
        self.res = av.AudioResampler(format="fltp", layout="mono", rate=rate)

    def write(self, arr):
        for i in range(0, len(arr), self.rate):
            f = av.AudioFrame.from_ndarray(arr[i:i + self.rate].reshape(1, -1), format="s16", layout="mono")
            f.sample_rate = self.rate
            f.pts = None
            for rf in self.res.resample(f):
                for p in self.st.encode(rf):
                    self.out.mux(p)

    def close(self):
        for rf in self.res.resample(None):
            for p in self.st.encode(rf):
                self.out.mux(p)
        for p in self.st.encode(None):
            self.out.mux(p)
        self.out.close()


def encode_range(audio, start_s, end_s, path, bitrate=32000):
    enc = _Enc(path, RATE, bitrate)
    for blk in audio.blocks(start_s, end_s):
        enc.write(blk)
    enc.close()


def encode_chunks_hq(src, chunks, folder):
    """One streaming pass over the source: each chunk re-encoded at DIA_RATE/DIA_BITRATE for the
    speaker model."""
    bounds = [int(e * DIA_RATE) for _, e in chunks]
    paths = [os.path.join(folder, "d%02d.m4a" % i) for i in range(len(chunks))]
    k, pos, enc = 0, 0, _Enc(paths[0], DIA_RATE, DIA_BITRATE)

    def feed(a):
        nonlocal k, pos, enc
        while len(a):
            room = bounds[k] - pos if k < len(bounds) - 1 else len(a)
            part, a = a[:room], a[room:]
            enc.write(part)
            pos += len(part)
            if len(a) and k < len(bounds) - 1:
                enc.close()
                k += 1
                enc = _Enc(paths[k], DIA_RATE, DIA_BITRATE)

    for blk in _decode_iter(src, DIA_RATE):
        feed(blk)
    enc.close()
    return paths[:k + 1]


EN_WORDS = {"the", "and", "is", "you", "what", "my", "name", "i", "to", "of", "it", "that", "this", "we",
            "are", "have", "for", "with", "your", "but", "so", "was", "be", "not", "they", "there"}


def looks_english(text):
    w = re.findall(r"[a-z']+", (text or "").lower())
    return len(w) >= 6 and sum(x in EN_WORDS for x in w) / len(w) > 0.18


def quietest(env, lo, hi):
    """Centre (s) of the quietest 200 ms window in [lo, hi]. Among near-ties take the LATEST, so chunks
    run as long as the cap allows."""
    i0, i1 = int(lo / WIN), min(len(env), int(hi / WIN))
    seg = env[i0:i1]
    if len(seg) == 0:
        return (lo + hi) / 2
    near = np.where(seg <= seg.min() * 1.1 + 1.0)[0]
    return (i0 + int(near[-1])) * WIN + WIN / 2


def plan(audio, max_s=None):
    """Cut points so every chunk stays under max_s, each cut on a silence."""
    limit = (max_s or DIARIZE_MAX_S) - 30
    dur = audio.duration
    cuts, start = [0.0], 0.0
    while dur - start > limit:
        lo = start + max(limit - 300, limit * 0.5)
        b = quietest(audio.env, lo, start + limit)
        cuts.append(b)
        start = b
    cuts.append(dur)
    return list(zip(cuts[:-1], cuts[1:]))


# -------------------------------------------------------------------- api ----
def langs_of(r):
    out = set()
    for l in (getattr(r, "languages", None) or []):
        try:
            c = l.get("code") if isinstance(l, dict) else getattr(l, "code", None)
            if c:
                out.add(c)
        except Exception:
            pass
    lang = getattr(r, "language", None)
    if isinstance(lang, str) and 1 < len(lang) <= 5:
        out.add(lang.lower())
    return out


def clean_keywords(raw):
    """'Acme, Kubernetes; Marie' or a list -> clean list. The API rejects the whole request if a
    keyword contains <, > or a line break."""
    items = raw if isinstance(raw, list) else re.split(r"[,;\n]", raw or "")
    out, seen = [], set()
    for k in items:
        k = re.sub(r"[<>\r\n]", " ", str(k)).strip()
        if k and len(k) <= 60 and k.lower() not in seen:
            seen.add(k.lower())
            out.append(k)
    return out[:100]


def _rejected(e):
    return getattr(e, "status_code", None) == 400


class Models:
    def __init__(self, transcribe="gpt-transcribe", diarize="gpt-4o-transcribe-diarize"):
        self.transcribe, self.diarize = transcribe, diarize


def flat(client, models, path, languages=None, keywords=None):
    extra, kw = {}, {}
    if languages:
        extra["languages"] = list(languages)
    if keywords:
        extra["keywords"] = list(keywords)
        kw["prompt"] = ("Expected names and terms: " + ", ".join(keywords))[:800]
    with open(path, "rb") as fh:
        try:
            r = client.audio.transcriptions.create(model=models.transcribe, file=fh, extra_body=extra or None, **kw)
        except Exception as e:
            if not (extra or kw) or not _rejected(e):
                raise
            log.info("language/term hints rejected (%s), retrying without", str(e)[:120])
            fh.seek(0)
            r = client.audio.transcriptions.create(model=models.transcribe, file=fh)
    return (r.text or "").strip(), langs_of(r)


def diarize(client, models, path, refs=None, language=None, on_seg=None):
    extra = {}
    if refs:
        extra = {"known_speaker_names": [n for n, _ in refs], "known_speaker_references": [d for _, d in refs]}
    kw = {"language": language} if language else {}
    segs = []

    def call(with_lang):
        return client.audio.transcriptions.create(
            model=models.diarize, file=fh, response_format="diarized_json", chunking_strategy="auto",
            stream=True, extra_body=extra or None, **(kw if with_lang else {}))

    with open(path, "rb") as fh:
        try:
            stream = call(True)
        except Exception as e:
            if not kw or not _rejected(e):
                raise
            log.info("speakers: language hint rejected (%s), retrying without", str(e)[:120])
            fh.seek(0)
            stream = call(False)
        for ev in stream:
            if getattr(ev, "type", "") == "transcript.text.segment":
                segs.append([getattr(ev, "speaker", "?"), float(getattr(ev, "start", 0) or 0),
                             float(getattr(ev, "end", 0) or 0), (getattr(ev, "text", "") or "").strip()])
                if on_seg:
                    on_seg(segs[-1][2])
    return segs


def diarize_anchored(client, models, path, refs, language=None, on_seg=None):
    """Try with voice references; if the API rejects them, fall back rather than fail."""
    if refs:
        try:
            return diarize(client, models, path, refs, language, on_seg), True
        except Exception as e:
            log.info("speakers: anchored pass rejected (%s), retrying unanchored", str(e)[:120])
    return diarize(client, models, path, None, language, on_seg), False


FOREIGN = re.compile(r"[^\x00-\x7F -ɏ -⁯€™]+")
LATIN_LANGS = {"fr", "en", "pl", "de", "es", "it", "pt", "nl", "ro", "cs", "sk", "hu", "sv", "da", "no",
               "nb", "fi", "tr", "hr", "sl", "lt", "lv", "et", "ca", "ga", "is", "mt", "sq", "id", "ms",
               "vi", "sw", "af", "eu", "gl", "cy", "lb", "tl"}


def foreign_script(text):
    return [m.group() for m in FOREIGN.finditer(text or "") if len(m.group().strip()) > 1]


def build_refs(audio, segs, offset):
    """2-8 s clip of each main voice in chunk 1, as data URLs, to anchor later chunks."""
    talk = {}
    for s in segs:
        talk[s[0]] = talk.get(s[0], 0) + (s[2] - s[1])
    refs = []
    for sp in sorted(talk, key=talk.get, reverse=True):
        best = max((s for s in segs if s[0] == sp), key=lambda s: s[2] - s[1])
        st, en = best[1], min(best[2], best[1] + 8.0)
        if en - st < 2.0:
            continue
        clip = audio.read(st + offset, en + offset)
        bio = io.BytesIO()
        w = wave.open(bio, "wb")
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(clip.tobytes())
        w.close()
        refs.append((sp, "data:audio/wav;base64," + base64.b64encode(bio.getvalue()).decode()))
        if len(refs) == 4:          # API maximum
            break
    return refs


# -------------------------------------------------------------------- run ----
def run(src, workdir, client, models, languages=None, keywords=None, speakers=True, on_text=None,
        cache=None, progress=None, cancelled=None, parallel=8, on_duration=None):
    """Transcribe `src`. Returns {"text", "langs", "foreign", "turns", "duration", "anchored",
    "splits", "dia_lang_warning"}. progress(stage, fraction) with stage in preparing / text / speakers."""
    progress = progress or (lambda *_: None)
    cancelled = cancelled or (lambda: False)
    cache = cache or Cache(os.path.join(workdir, "cache"))
    languages = [l for l in (languages or []) if l]
    keywords = keywords or []
    one_lang = languages[0] if len(languages) == 1 else None
    os.makedirs(workdir, exist_ok=True)
    res = {"text": "", "langs": [], "foreign": [], "turns": [], "duration": 0.0, "anchored": True,
           "splits": [], "dia_lang_warning": False}

    def check():
        if cancelled():
            raise Cancelled()

    progress("preparing", 0.05)
    audio = Audio(src, workdir)
    dur = res["duration"] = audio.duration
    if dur < 0.5:
        raise ValueError("audio_too_short")
    if on_duration:                 # e.g. check the allowance against the decoded length, before any API call
        on_duration(dur)
    full = os.path.join(workdir, "full.m4a")
    encode_range(audio, 0, dur, full)
    if os.path.getsize(full) / 1024 / 1024 < UPLOAD_MAX_MB:
        flat_inputs = [full]
    else:
        flat_inputs = []
        for i, (s, e) in enumerate(plan(audio)):
            p = os.path.join(workdir, "c%02d.m4a" % i)
            encode_range(audio, s, e, p)
            flat_inputs.append(p)
    chunks = plan(audio, min(DIA_CHUNK_S, DIARIZE_MAX_S))
    paths = encode_chunks_hq(src, chunks, workdir) if speakers else []
    log.info("duration %.0fs | %d text input(s) | %d speaker chunk(s)", dur, len(flat_inputs), len(chunks))
    progress("preparing", 1.0)
    check()

    n_flat = len(flat_inputs)

    def flat_c(i, p):
        key = [i, n_flat, languages, keywords, models.transcribe]
        hit = cache.get("flat", key)
        if hit:
            return hit["text"], set(hit["langs"])
        t, l = flat(client, models, p, languages, keywords)
        cache.put("flat", key, {"text": t, "langs": sorted(l)})
        return t, l

    chunk_done = {}

    def spk_progress():
        if paths:
            progress("speakers", sum(chunk_done.values()) / len(paths))

    def dia_c(i, lang, refs=None):
        key = [i, list(chunks[i]), lang, models.diarize]
        hit = cache.get("dia", key)
        if hit:
            chunk_done[i] = 1.0
            spk_progress()
            return hit["segs"], hit["ok"]
        check()
        length = max(1.0, chunks[i][1] - chunks[i][0])

        def on_seg(end):
            chunk_done[i] = min(0.97, end / length)
            spk_progress()

        if i == 0:
            sg, ok = diarize(client, models, paths[0], None, lang, on_seg), True
        else:
            sg, ok = diarize_anchored(client, models, paths[i], refs, lang, on_seg)
        cache.put("dia", key, {"segs": sg, "ok": ok})
        chunk_done[i] = 1.0
        spk_progress()
        return sg, ok

    if speakers and not languages:
        # Auto-detect: the speaker model has no language detection of its own and drifts into English.
        probe = cache.get("probe", [models.transcribe])
        if probe is None:
            p30 = os.path.join(workdir, "probe.m4a")
            encode_range(audio, 0, min(30, dur), p30)
            try:
                _, pl = flat(client, models, p30)
                probe = sorted(pl)
                cache.put("probe", [models.transcribe], probe)
            except Exception as e:          # never block the transcript for this
                log.info("language probe failed (%s)", str(e)[:120])
                probe = []
        if len(probe) == 1:
            one_lang = probe[0]

    progress("text", 0.0)
    with cf.ThreadPoolExecutor(max_workers=parallel + len(flat_inputs)) as ex:
        flat_futs = [ex.submit(flat_c, i, p) for i, p in enumerate(flat_inputs)]
        first = ex.submit(dia_c, 0, one_lang) if speakers else None

        parts, langs = [], set()
        for f in flat_futs:
            t, l = f.result()
            parts.append(t)
            langs |= l
        text = "\n\n".join(p for p in parts if p)
        res["text"], res["langs"] = text, sorted(langs)
        progress("text", 1.0)
        if all(l.split("-")[0] in LATIN_LANGS for l in languages):
            res["foreign"] = foreign_script(text)
        if on_text:                 # e.g. start correction + summary now, alongside the speaker pass
            on_text(text, sorted(langs))
        if not speakers:
            return res

        check()
        s1, _ = first.result()
        refs = build_refs(audio, s1, chunks[0][0]) if len(paths) > 1 else []
        rest = [ex.submit(dia_c, i, one_lang, refs) for i in range(1, len(paths))]
        results, errors = [(s1, True)], []
        for f in rest:                  # let every chunk finish (and be cached) before failing
            try:
                results.append(f.result())
            except Exception as e:
                errors.append(e)
        if errors:
            raise errors[0]

        # safety net: a chunk that came back in English while the meeting was not -> retry once
        expect = languages or sorted(langs)
        if expect and "en" not in expect:
            for i, (sg, ok) in enumerate(results):
                if looks_english(" ".join(s[3] for s in sg)):
                    check()
                    again = diarize(client, models, paths[i], refs if i else None, expect[0])
                    if looks_english(" ".join(s[3] for s in again)):
                        res["dia_lang_warning"] = True
                    else:
                        results[i] = (again, ok)
                        cache.put("dia", [i, list(chunks[i]), one_lang, models.diarize], {"segs": again, "ok": ok})

    res["anchored"] = all(ok for _, ok in results[1:]) if len(results) > 1 else True
    res["splits"] = [round(s, 2) for s, _ in chunks[1:]]
    turns = []
    for (sg, _), (off, _) in zip(results, chunks):
        for sp, st, en, tx in sg:
            if not tx:
                continue
            st, en = round(st + off, 2), round(en + off, 2)
            if turns and turns[-1]["spk"] == sp:
                turns[-1]["text"] += " " + tx
                turns[-1]["end"] = en
            else:
                turns.append({"spk": sp, "start": st, "end": en, "text": tx})
    res["turns"] = turns
    return res
