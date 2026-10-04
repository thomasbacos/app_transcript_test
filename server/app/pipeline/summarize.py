"""AI summary of a transcript: title, sections of bullets, and action items the app shows as a checklist."""

PROMPT = """You are writing clear, useful notes from an automatic transcript of a recording.
The transcript may contain recognition errors, repetitions and crosstalk; infer the intended meaning,
never invent facts.

First decide what kind of recording it is: "meeting", "call", "interview", "lecture", "podcast",
"brainstorm" or "other", and shape the notes for it (a meeting needs decisions and next steps, a lecture
the key concepts, an interview the main questions and answers...).

Write EVERYTHING in {lang}, including the title and every section heading. Return ONLY a JSON object:
{{
  "kind": "meeting",
  "title": "short descriptive title (max 8 words)",
  "subtitle": "one line: who talked about what (if identifiable)",
  "sections": [
    {{"head": "<'Key takeaways' in {lang}>", "bullets": ["4 to 8 bullets, each one complete sentence that makes a point"]}},
    {{"head": "<theme>", "bullets": ["..."]}},
    ...
    {{"head": "<'Points to verify' in {lang}>", "bullets": ["names, figures or dates the transcript makes uncertain"]}}
  ],
  "actions": [{{"task": "what must be done", "owner": "who (or empty)", "due": "when (or empty)"}}]
}}
Use 2 to 6 thematic sections between the takeaways and the points to verify, fewer for short recordings.
Omit "Points to verify" if nothing is uncertain. "actions" lists only tasks actually stated or agreed;
leave it empty otherwise. Keep every figure exactly as stated and say when a currency or unit was not
stated. Plain text only, no markdown.

TRANSCRIPT:
{text}
"""

MAX_CHARS = 400_000   # ~100k tokens; a 3-hour meeting is ~100k characters

LANG_NAMES = {"fr": "French", "en": "English", "es": "Spanish", "de": "German", "it": "Italian",
              "pt": "Portuguese", "nl": "Dutch", "pl": "Polish", "ro": "Romanian", "sv": "Swedish",
              "da": "Danish", "no": "Norwegian", "nb": "Norwegian", "fi": "Finnish", "cs": "Czech",
              "tr": "Turkish", "el": "Greek", "ru": "Russian", "uk": "Ukrainian", "ar": "Arabic",
              "he": "Hebrew", "hi": "Hindi", "ja": "Japanese", "ko": "Korean", "zh": "Chinese",
              "ca": "Catalan", "hu": "Hungarian", "id": "Indonesian", "vi": "Vietnamese"}
KINDS = {"meeting", "call", "interview", "lecture", "podcast", "brainstorm", "other"}


def language_name(code, fallback="English"):
    return LANG_NAMES.get((code or "").split("-")[0].lower(), fallback)


def summarize(llm, text, lang="English"):
    data, used = llm.json(PROMPT.format(lang=lang, text=text[:MAX_CHARS]))
    sections = []
    for s in data.get("sections") or []:
        if not isinstance(s, dict):
            continue
        bullets = [str(b).strip() for b in (s.get("bullets") or []) if str(b).strip()]
        if bullets:
            sections.append({"head": str(s.get("head", "")).strip(), "bullets": bullets})
    if not sections:
        raise ValueError("the model returned no usable sections")
    actions = []
    for a in data.get("actions") or []:
        if isinstance(a, dict) and str(a.get("task", "")).strip():
            actions.append({"task": str(a["task"]).strip(), "owner": str(a.get("owner") or "").strip(),
                            "due": str(a.get("due") or "").strip()})
    kind = str(data.get("kind") or "other").strip().lower()
    return {"kind": kind if kind in KINDS else "other",
            "title": str(data.get("title") or "").strip(),
            "subtitle": str(data.get("subtitle") or "").strip(),
            "sections": sections, "actions": actions[:30], "model": used}
