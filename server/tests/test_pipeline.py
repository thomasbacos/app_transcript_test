import os

import pytest

from app.pipeline import process as proc
from app.pipeline import transcribe
from conftest import FakeOpenAI, Quota

MODELS = transcribe.Models()
LLM_MODELS = ("gpt-6-sol", "gpt-6-astra")


def run(audio_file, tmp_path, client, opts=None, progress=None):
    cache = transcribe.Cache(str(tmp_path / "cache"))
    return proc.process(audio_file, [], opts or {"ui_language": "fr"}, client, MODELS, LLM_MODELS, cache,
                        str(tmp_path / "work"), progress=progress, parallel=4)


def test_full_pipeline(audio_file, tmp_path):
    client = FakeOpenAI()
    seen = []
    res = run(audio_file, tmp_path, client, progress=lambda st, p: seen.append((st, p)))
    assert 140 < res["duration"] < 160
    assert res["language"] == "fr"
    assert client.calls["probe"] == 1, "auto-detect probes the language for the speaker model"
    assert client.calls["dia"] >= 3, "150 s with 60-s chunks -> several speaker chunks"
    assert client.calls["refs"] == client.calls["dia"] - 1, "chunks 2..n are anchored on chunk 1's voices"
    assert "Parley" in res["text"] and "Parlé" in res["raw_text"]
    assert res["names"] == {"A": "Marie"}
    assert res["summary"]["title"] == "Lancement de Parley"
    assert client.summary_langs == ["French"], "summary follows the detected language"
    assert res["summary"]["actions"][0]["owner"] == "Marie"
    assert res["summary"]["model"] == "gpt-6-astra", "falls back when the preferred model is refused"
    assert res["corrections"] == [{"from": "Parlé", "to": "Parley", "why": "per glossary"}]
    assert res["turns"] and all(t["end"] >= t["start"] for t in res["turns"])
    assert [t["start"] for t in res["turns"]] == sorted(t["start"] for t in res["turns"])
    stages = {s for s, _ in seen}
    assert {"preparing", "text", "speakers", "correcting", "finalizing"} <= stages


def test_resume_after_failure_reuses_finished_pieces(audio_file, tmp_path):
    broken = FakeOpenAI(fail_dia_chunk=2)
    with pytest.raises(Quota):
        run(audio_file, tmp_path, broken)
    first = dict(broken.calls)
    ok = FakeOpenAI()
    res = run(audio_file, tmp_path, ok)
    assert res["turns"]
    assert ok.calls["flat"] == 0 and ok.calls["probe"] == 0, "text and probe come from the cache"
    assert ok.calls["dia"] < first["dia"], "only the missing speaker chunk(s) are redone"


def test_text_only(audio_file, tmp_path):
    client = FakeOpenAI()
    res = run(audio_file, tmp_path, client, {"speakers": False, "summary_language": "en", "languages": ["fr"]})
    assert res["turns"] == [] and client.calls["dia"] == 0 and client.calls["probe"] == 0
    assert client.summary_langs == ["English"], "explicit summary language wins"


def test_plan_cuts_on_silence(audio_file, tmp_path):
    os.makedirs(tmp_path / "w", exist_ok=True)
    a = transcribe.Audio(audio_file, str(tmp_path / "w"))
    chunks = transcribe.plan(a, 60)
    assert len(chunks) >= 3
    assert all(e - s <= 30.01 for s, e in chunks), "limit is max_s - 30"
    for s, _ in chunks[1:]:
        i = int(s / transcribe.WIN)
        assert a.env[i] < a.env.max() * 0.2, "each cut lands in a quiet window"
