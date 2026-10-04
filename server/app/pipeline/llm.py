"""JSON completions with a model fallback (e.g. a newer model not enabled on the key -> previous one).
Once the preferred model is refused, the server remembers it for an hour instead of paying a failed call
on every request."""
import json
import threading
import time

_refused = {}
_lock = threading.Lock()
REMEMBER_S = 3600


def not_allowed(e):
    """The key has no access to this model (403 model_not_found) or it does not exist (404)."""
    return getattr(e, "status_code", None) in (403, 404) or "model_not_found" in str(e)


class LLM:
    def __init__(self, client, model, fallback=None):
        self.client, self.model, self.fallback = client, model, fallback

    def _preferred(self):
        with _lock:
            t = _refused.get(self.model)
        if self.fallback and t and time.time() - t < REMEMBER_S:
            return self.fallback
        return self.model

    def _ask(self, model, prompt):
        try:
            r = self.client.chat.completions.create(model=model, messages=[{"role": "user", "content": prompt}],
                                                    response_format={"type": "json_object"})
            return r.choices[0].message.content
        except Exception as first:
            # Some newer models are only served through the Responses API.
            try:
                r = self.client.responses.create(model=model, input=prompt, text={"format": {"type": "json_object"}})
                return r.output_text
            except Exception:
                raise first

    def json(self, prompt):
        """-> (parsed dict, model used)"""
        model = self._preferred()
        try:
            raw = self._ask(model, prompt)
        except Exception as e:
            if not self.fallback or model == self.fallback or not not_allowed(e):
                raise
            with _lock:
                _refused[self.model] = time.time()
            model = self.fallback
            raw = self._ask(model, prompt)
        return json.loads(raw), model
