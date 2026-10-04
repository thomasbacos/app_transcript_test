"""
One job, end to end (the desktop app's App.work, without files or UI):

    reference docs -> vocabulary            (grounding)
    text pass  ----------------------------> correct text -> summary      (in a side thread, as soon as
    speaker pass (chunked, parallel) ------> correct turns + names         the text lands)

Every finished piece goes through the job's Cache, so a retry after a failure only redoes what is missing.
"""
import logging
import re
import threading

from . import correct, grounding, summarize, transcribe
from .llm import LLM

log = logging.getLogger("parley.process")

# Overall progress = weighted stages. The speaker pass dominates wall time.
WEIGHTS = {"preparing": (0.00, 0.08), "text": (0.08, 0.25), "speakers": (0.25, 0.85),
           "correcting": (0.85, 0.95), "finalizing": (0.95, 1.00)}


def process(audio_path, doc_paths, opts, client, models, llm_models, cache, workdir, progress=None,
            cancelled=None, parallel=8, on_duration=None):
    """-> result dict (see README "API"). opts: languages, terms, speakers, correct, summary,
    summary_language ("auto" or a code), ui_language."""
    progress = progress or (lambda stage, overall: None)
    cancelled = cancelled or (lambda: False)
    llm = LLM(client, *llm_models)
    lock = threading.Lock()
    with_speakers = bool(opts.get("speakers", True))

    def report(stage, frac):
        lo, hi = WEIGHTS.get(stage, (0, 1))
        if stage == "text" and not with_speakers:
            lo, hi = 0.08, 0.80
        with lock:
            progress(stage, lo + (hi - lo) * max(0.0, min(1.0, frac)))

    warnings = []
    ctx = {"terms": [], "excerpt": "", "docs": []}
    if doc_paths:
        try:
            ctx = grounding.load(doc_paths)
        except Exception as e:
            log.warning("reference documents unreadable: %s", e)
            warnings.append("docs_unreadable")
    keywords = transcribe.clean_keywords(list(opts.get("terms") or []) + list(ctx["terms"]))[:100]
    languages = [l for l in (opts.get("languages") or []) if isinstance(l, str) and l][:5]
    box = {"corrections": []}

    def summary_lang(langs):
        want = (opts.get("summary_language") or "auto").lower()
        if want != "auto":
            return summarize.language_name(want)
        detected = languages or langs
        if len(detected) == 1:
            return summarize.language_name(detected[0], summarize.language_name(opts.get("ui_language"), "English"))
        return summarize.language_name(opts.get("ui_language"), "English")

    def after_text(text, langs):
        """Runs alongside the speaker pass: correct the text, then summarise the corrected text."""
        if cancelled() or not text.strip():
            return
        if opts.get("correct", True):
            key = [llm_models, text, ctx["terms"], ctx["excerpt"], keywords]
            try:
                hit = cache.get("corr_text", key)
                if hit is None:
                    fixed, corrs = correct.correct_text(llm, text, keywords, ctx["excerpt"])
                    hit = {"text": fixed, "corrections": corrs}
                    cache.put("corr_text", key, hit)
                box["text_fixed"] = hit["text"]
                box["corrections"] += hit["corrections"]
            except Exception as e:
                log.warning("text correction failed: %s", str(e)[:200])
                warnings.append("correction_failed")
        if opts.get("summary", True) and not cancelled():
            src = box.get("text_fixed") or text
            lang = summary_lang(langs)
            key = [llm_models, lang, src]
            try:
                hit = cache.get("summary", key)
                if hit is None:
                    hit = summarize.summarize(llm, src, lang)
                    cache.put("summary", key, hit)
                box["summary"] = hit
            except Exception as e:
                log.warning("summary failed: %s", str(e)[:200])
                warnings.append("summary_failed")

    side = {}

    def on_text(text, langs):
        t = threading.Thread(target=after_text, args=(text, langs), daemon=True)
        side["t"] = t
        t.start()

    res = transcribe.run(audio_path, workdir, client, models, languages=languages, keywords=keywords,
                         speakers=with_speakers, on_text=on_text, cache=cache,
                         progress=report, cancelled=cancelled, parallel=parallel, on_duration=on_duration)
    if side.get("t"):
        report("correcting", 0.2)
        side["t"].join()
    if cancelled():
        raise transcribe.Cancelled()

    flat_text = box.get("text_fixed") or res["text"]
    turns, names = res["turns"], {}
    if turns and opts.get("correct", True):
        report("correcting", 0.5)
        key = [llm_models, turns, flat_text, ctx["terms"], ctx["excerpt"], keywords]
        try:
            hit = cache.get("corr_turns", key)
            if hit is None:
                fixed_turns, names, corrs = correct.correct_turns(llm, turns, flat_text, keywords, ctx["excerpt"])
                hit = {"turns": fixed_turns, "names": names, "corrections": corrs}
                cache.put("corr_turns", key, hit)
            turns, names = hit["turns"], hit["names"]
            box["corrections"] += hit["corrections"]
        except Exception as e:
            log.warning("turn correction failed: %s", str(e)[:200])
            if "correction_failed" not in warnings:
                warnings.append("correction_failed")
    report("finalizing", 0.5)

    dur = res["duration"]
    words = len(flat_text.split())
    if dur > 15 and words < (dur / 60) * 30:
        warnings.append("low_speech")
    if res["foreign"]:
        warnings.append("foreign_script")
    if res["dia_lang_warning"]:
        warnings.append("speaker_language")
    if with_speakers and not res["anchored"]:
        warnings.append("speakers_not_anchored")
    summary = box.get("summary")
    langs = languages or res["langs"]
    return {
        "version": 1,
        "duration": round(dur, 2),
        "language": langs[0] if len(langs) == 1 else None,
        "languages": langs,
        "title": (summary or {}).get("title") or "",
        "text": flat_text,
        "raw_text": res["text"],
        "turns": turns,
        "names": names,
        "summary": summary,
        "corrections": correct.merge_corrections([box["corrections"]]),
        "warnings": warnings,
        "splits": res["splits"],
        "docs": [re.sub(r"^\d+_", "", d["name"]) for d in ctx["docs"]],
        "word_count": words,
    }
