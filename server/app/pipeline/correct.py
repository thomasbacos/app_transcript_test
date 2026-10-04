"""
AI correction pass over a transcript, grounded in optional reference documents and a glossary.

Fixes recognition errors (jargon, names, figures, acronyms) WITHOUT rewriting what people said; uses the
plain-text transcript (more accurate) as a reference for the speaker-labelled turns, infers speaker names
when someone states theirs, and returns the list of corrections made.

Safety: corrections are applied per paragraph / turn by index; one that changes a turn's length by more
than 40% is rejected and the original kept.
"""
import concurrent.futures as cf
import logging
import re

log = logging.getLogger("parley.correct")

PROMPT_TEXT = """You are correcting an automatic speech-to-text transcript of a recording (meeting, call,
interview, lecture or conversation).
Fix ONLY recognition errors: misheard technical terms, product / company / people names, acronyms,
figures and units, words split or merged by mistake, and other obvious transcription mistakes.
Use the REFERENCE DOCUMENTS and the GLOSSARY to get terms and names right.
Do NOT summarise, reorder, translate, rephrase, add content or remove content. Keep the original
language of each passage. If unsure, leave the text unchanged.

Return ONLY a JSON object:
{{"items": [{{"i": <index>, "text": "<corrected paragraph>"}} ...only for paragraphs you changed...],
  "corrections": [{{"from": "<wrong>", "to": "<right>", "why": "<short reason, e.g. 'per glossary'>"}}]}}

GLOSSARY: {glossary}

REFERENCE DOCUMENTS (excerpt):
{docs}

PARAGRAPHS TO CORRECT (index: text):
{items}
"""

PROMPT_TURNS = """You are correcting the speaker-labelled transcript of a recording. The speaker model's
wording is less accurate than the REFERENCE TRANSCRIPT (same audio, better text, no speakers).
For each turn, fix recognition errors using the reference transcript, the REFERENCE DOCUMENTS and the
GLOSSARY: misheard terms, names, acronyms, figures, and obvious mistakes. Keep each turn's meaning and
speaker; do NOT summarise, merge, split or add content. If unsure, leave it.
Language: each turn must be in the language actually spoken, i.e. as in the reference transcript. The
speaker model sometimes outputs a turn TRANSLATED (often into English) or invents filler: when the
reference shows that passage in another language, restore the reference wording.
Also: if a speaker clearly states their own name (e.g. "my name is John", "je m'appelle Marie"), or is
clearly addressed by name in a way that identifies them, report it in "names" as
{{"<speaker label>": "<name>"}}; otherwise leave "names" empty.

Return ONLY a JSON object:
{{"items": [{{"i": <turn index>, "text": "<corrected turn>"}} ...only for turns you changed...],
  "names": {{}},
  "corrections": [{{"from": "<wrong>", "to": "<right>", "why": "<short reason>"}}]}}

GLOSSARY: {glossary}

REFERENCE DOCUMENTS (excerpt):
{docs}

REFERENCE TRANSCRIPT (matching passage):
{ref}

TURNS TO CORRECT (index | speaker: text):
{items}
"""

BATCH_WORDS = 1800


def _batches(texts, limit=BATCH_WORDS):
    out, cur, n = [], [], 0
    for i, t in enumerate(texts):
        w = len(t.split())
        if cur and n + w > limit:
            out.append(cur)
            cur, n = [], 0
        cur.append(i)
        n += w
    if cur:
        out.append(cur)
    return out


def _safe(orig, new):
    if not isinstance(new, str) or not new.strip():
        return False
    a, b = len(orig), len(new)
    return a == 0 or 0.6 <= b / a <= 1.4


def merge_corrections(lists, limit=120):
    seen, out = set(), []
    for lst in lists:
        for c in lst or []:
            try:
                key = (str(c.get("from", "")).strip().lower(), str(c.get("to", "")).strip().lower())
            except AttributeError:
                continue
            if key[0] and key[0] != key[1] and key not in seen:
                seen.add(key)
                out.append({"from": str(c.get("from", "")).strip(), "to": str(c.get("to", "")).strip(),
                            "why": str(c.get("why", "")).strip()[:80]})
    return out[:limit]


def paragraphs(text):
    paras = [p for p in re.split(r"\n\s*\n", text) if p.strip()]
    if len(paras) < 3:                                  # one long block: cut into ~sentence groups
        sents = re.split(r"(?<=[\.\!\?])\s+", text)
        paras, cur = [], ""
        for s_ in sents:
            if len((cur + " " + s_).split()) > 120 and cur:
                paras.append(cur.strip())
                cur = s_
            else:
                cur = (cur + " " + s_).strip()
        if cur:
            paras.append(cur)
    return paras


def correct_text(llm, text, glossary, docs_excerpt):
    """Plain transcript -> (corrected text with paragraphs, corrections)."""
    paras = paragraphs(text)
    out, corrs = list(paras), []
    gl = ", ".join(glossary[:150]) or "(none)"

    def run(batch):
        items = "\n".join("%d: %s" % (i, paras[i]) for i in batch)
        return llm.json(PROMPT_TEXT.format(glossary=gl, docs=docs_excerpt or "(none)", items=items))

    batches = _batches(paras)
    with cf.ThreadPoolExecutor(max_workers=6) as ex:
        for (data, _), batch in zip(ex.map(run, batches), batches):
            for it in data.get("items") or []:
                try:
                    i = int(it["i"])
                except (KeyError, TypeError, ValueError):
                    continue
                if i in batch and _safe(paras[i], it.get("text")):
                    out[i] = it["text"].strip()
            corrs.append(data.get("corrections"))
    return "\n\n".join(out), merge_corrections(corrs)


def correct_turns(llm, turns, ref_text, glossary, docs_excerpt):
    """Speaker turns -> (corrected turns, {label: name}, corrections). Each batch gets the proportional
    slice of the reference transcript (+/- 15% margin)."""
    texts = [t["text"] for t in turns]
    ref_words = (ref_text or "").split()
    tot = sum(len(t.split()) for t in texts) or 1
    cum, acc = [], 0
    for t in texts:
        cum.append(acc)
        acc += len(t.split())
    gl = ", ".join(glossary[:150]) or "(none)"
    batches = _batches(texts)
    labels = {t["spk"] for t in turns}

    def run(batch):
        a = cum[batch[0]] / tot
        b = (cum[batch[-1]] + len(texts[batch[-1]].split())) / tot
        lo = max(0, int((a - 0.15) * len(ref_words)))
        hi = min(len(ref_words), int((b + 0.15) * len(ref_words)) + 1)
        ref = " ".join(ref_words[lo:hi]) or "(none)"
        items = "\n".join("%d | %s: %s" % (i, turns[i]["spk"], texts[i]) for i in batch)
        return llm.json(PROMPT_TURNS.format(glossary=gl, docs=docs_excerpt or "(none)", ref=ref, items=items))

    out = [dict(t) for t in turns]
    names, corrs = {}, []
    with cf.ThreadPoolExecutor(max_workers=6) as ex:
        for (data, _), batch in zip(ex.map(run, batches), batches):
            for it in data.get("items") or []:
                try:
                    i = int(it["i"])
                except (KeyError, TypeError, ValueError):
                    continue
                if i in batch and _safe(texts[i], it.get("text")):
                    out[i]["text"] = it["text"].strip()
            for k, v in (data.get("names") or {}).items():
                if isinstance(v, str) and 0 < len(v.strip()) <= 40 and k in labels:
                    names.setdefault(k, v.strip())
            corrs.append(data.get("corrections"))
    return out, names, merge_corrections(corrs)
