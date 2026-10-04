"""Test setup: temporary data dir + SQLite, a fake OpenAI client, synthetic audio, Xcode-signed
(i.e. unsigned) StoreKit transactions as produced by Xcode's local StoreKit testing."""
import os
import sys
import tempfile
import threading
import time
import types
import json
import re

import numpy as np
import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.environ["TRANSCRIBE_DIA_CHUNK_S"] = "60"        # several speaker chunks on a 2.5-min test file

BUNDLE = "com.thomasbacos.parley"


def make_audio(path, seconds=150, rate=16000):
    """Speech-like bursts (harmonic tones, amplitude-modulated) separated by short silences."""
    from app.pipeline.transcribe import _Enc
    t = np.arange(int(seconds * rate)) / rate
    sig = np.zeros_like(t)
    pos = 0.0
    k = 0
    while pos < seconds - 1:
        dur = 4 + (k % 3) * 2
        f0 = 140 if k % 2 == 0 else 220
        m = (t >= pos) & (t < pos + dur)
        tt = t[m] - pos
        env = 0.5 + 0.5 * np.sin(2 * np.pi * 3 * tt)
        sig[m] = env * (np.sin(2 * np.pi * f0 * tt) + 0.5 * np.sin(2 * np.pi * 2 * f0 * tt))
        pos += dur + 1.0
        k += 1
    pcm = (sig / (np.abs(sig).max() or 1) * 0.6 * 32767).astype(np.int16)
    enc = _Enc(path, rate, 48000)
    enc.write(pcm)
    enc.close()
    return path


class FakeOpenAI:
    """Just enough of the OpenAI SDK surface used by the pipeline."""

    def __init__(self, sol_allowed=False, fail_dia_chunk=None):
        self.calls = {"flat": 0, "probe": 0, "dia": 0, "chat": 0, "refs": 0}
        self.lock = threading.Lock()
        self.sol_allowed = sol_allowed
        self.fail_dia_chunk = fail_dia_chunk
        self.models_seen = set()
        self.summary_langs = []
        self.audio = types.SimpleNamespace(transcriptions=types.SimpleNamespace(create=self._transcribe))
        self.chat = types.SimpleNamespace(completions=types.SimpleNamespace(create=self._chat))
        self.responses = types.SimpleNamespace(create=self._responses)

    def _transcribe(self, model, file, **kw):
        name = os.path.basename(file.name)
        with self.lock:
            self.models_seen.add(model)
        if model == "gpt-transcribe":
            with self.lock:
                self.calls["probe" if name == "probe.m4a" else "flat"] += 1
            return types.SimpleNamespace(
                text="Bonjour à tous, merci d'être là. On parle du lancement de Parlé aujourd'hui. "
                     "Marie présente les chiffres du trimestre. Ensuite on décide du calendrier.",
                languages=[{"code": "fr"}])
        assert model == "gpt-4o-transcribe-diarize"
        assert kw.get("response_format") == "diarized_json"
        assert kw.get("language") == "fr", kw.get("language")
        idx = int(name[1:3])
        with self.lock:
            self.calls["dia"] += 1
            if (kw.get("extra_body") or {}).get("known_speaker_references"):
                self.calls["refs"] += 1
        if self.fail_dia_chunk is not None and idx == self.fail_dia_chunk:
            raise Quota()
        segs = []
        for n in range(6):
            segs.append(types.SimpleNamespace(type="transcript.text.segment", speaker="A" if n % 2 == 0 else "B",
                                              start=n * 4.5 + 0.5, end=n * 4.5 + 4.0,
                                              text="Bonjour, je m'appelle Marie." if n == 0 else "Phrase %d du bloc %d." % (n, idx)))
        return iter(segs)

    def _answer(self, model, prompt):
        with self.lock:
            self.calls["chat"] += 1
            self.models_seen.add(model)
        if model == "gpt-6-sol" and not self.sol_allowed:
            raise NotAllowed()
        if "PARAGRAPHS TO CORRECT" in prompt:
            return {"items": [{"i": 0, "text": "Bonjour à tous, merci d'être là. On parle du lancement de Parley "
                                              "aujourd'hui. Marie présente les chiffres du trimestre. Ensuite on "
                                              "décide du calendrier."}],
                    "corrections": [{"from": "Parlé", "to": "Parley", "why": "per glossary"}]}
        if "TURNS TO CORRECT" in prompt:
            return {"items": [], "names": {"A": "Marie"}, "corrections": []}
        m = re.search(r"Write EVERYTHING in (\w+)", prompt)
        with self.lock:
            self.summary_langs.append(m.group(1) if m else None)
        return {"kind": "meeting", "title": "Lancement de Parley", "subtitle": "Marie présente les chiffres",
                "sections": [{"head": "Points clés", "bullets": ["Le lancement est confirmé."]},
                             {"head": "Calendrier", "bullets": ["Décision du calendrier en fin de réunion."]}],
                "actions": [{"task": "Envoyer le calendrier", "owner": "Marie", "due": "vendredi"}]}

    def _chat(self, model, messages, response_format=None, **_):
        data = self._answer(model, messages[0]["content"])
        return types.SimpleNamespace(choices=[types.SimpleNamespace(message=types.SimpleNamespace(
            content=json.dumps(data, ensure_ascii=False)))])

    def _responses(self, model, input, **_):
        data = self._answer(model, input)
        return types.SimpleNamespace(output_text=json.dumps(data, ensure_ascii=False))


class Quota(Exception):
    status_code = 429

    def __str__(self):
        return "Error code: 429 - {'error': {'code': 'insufficient_quota'}}"


class NotAllowed(Exception):
    status_code = 403

    def __str__(self):
        return "Error code: 403 - model_not_found"


def xcode_transaction(product="pro.monthly", otid="2000000000000001", tid=None, trial=False,
                      purchase=None, expires=None, bundle=BUNDLE, env="Xcode"):
    """A StoreKit transaction as Xcode's local StoreKit testing signs it (not by Apple)."""
    import jwt
    now = int(time.time() * 1000)
    purchase = purchase or now - 60_000
    claims = {"transactionId": tid or otid, "originalTransactionId": otid, "bundleId": bundle,
              "productId": "%s.%s" % (BUNDLE, product), "purchaseDate": purchase,
              "originalPurchaseDate": purchase, "expiresDate": expires or purchase + 30 * 86400 * 1000,
              "type": "Auto-Renewable Subscription", "inAppOwnershipType": "PURCHASED",
              "signedDate": now, "environment": env, "transactionReason": "PURCHASE",
              "storefront": "FRA", "currency": "EUR", "price": 0 if trial else 14990}
    if trial:
        claims.update(offerType=1, offerDiscountType="FREE_TRIAL")
    return jwt.encode(claims, "xcode-local-signing-key-for-tests-only-000", algorithm="HS256")


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path / "data"))
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("SECRET_KEY", "test-secret-test-secret-test-secret-0123456789")
    monkeypatch.setenv("APPLE_ENVIRONMENTS", "Xcode,Sandbox")
    monkeypatch.setenv("APP_BUNDLE_ID", BUNDLE)
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    from app import appstore, config
    config.reset_settings()
    appstore.reset()
    yield tmp_path
    config.reset_settings()
    appstore.reset()


@pytest.fixture(scope="session")
def audio_file():
    d = tempfile.mkdtemp()
    return make_audio(os.path.join(d, "meeting.m4a"))
