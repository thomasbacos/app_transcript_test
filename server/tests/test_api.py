import datetime as dt
import json
import time

from fastapi.testclient import TestClient

from app import appstore
from conftest import FakeOpenAI, xcode_transaction


def client_for(fake):
    from app import main
    return TestClient(main.create_app(client_factory=lambda: fake))


def session(c, transactions=(), install="install-0001"):
    r = c.post("/v1/auth/session", json={"install_id": install, "transactions": list(transactions),
                                         "locale": "fr_FR", "app_version": "1.0"})
    assert r.status_code == 200, r.text
    body = r.json()
    return {"Authorization": "Bearer " + body["token"]}, body["account"]


def create(c, h, duration, options=None, docs=None):
    files = [("docs", (name, data, "text/plain")) for name, data in (docs or [])]
    return c.post("/v1/jobs", headers=h, data={"duration": str(duration),
                                                "options": json.dumps(options or {"ui_language": "fr"})},
                  files=files or None)


def wait_done(c, h, job_id, timeout=90):
    t0 = time.time()
    while time.time() - t0 < timeout:
        j = c.get("/v1/jobs/" + job_id, headers=h).json()
        if j["status"] in ("done", "failed", "cancelled"):
            return j
        time.sleep(0.3)
    raise AssertionError("job did not finish: %s" % j)


def test_no_subscription_cannot_transcribe(env):
    with client_for(FakeOpenAI()) as c:
        h, acc = session(c)
        assert acc["plan"] == "none" and not acc["active"]
        r = create(c, h, 60)
        assert r.status_code == 402 and r.json()["error"]["code"] == "subscription_required"


def test_trial_end_to_end(env, audio_file):
    fake = FakeOpenAI()
    with client_for(fake) as c:
        h, acc = session(c, [xcode_transaction(trial=True, expires=int(time.time() * 1000) + 7 * 86400 * 1000)])
        assert acc["active"] and acc["is_trial"] and acc["quota_seconds"] == 3600
        r = create(c, h, 150, {"ui_language": "fr", "terms": ["Parley", "Marie"]},
                   docs=[("agenda.txt", "Ordre du jour : lancement de Parley, chiffres du trimestre.")])
        assert r.status_code == 200, r.text
        job = r.json()
        assert job["status"] == "awaiting_audio" and job["needs_upload"]
        # reserved while running: what is left already accounts for it
        assert c.get("/v1/account", headers=h).json()["remaining_seconds"] == 3600 - 150

        with open(audio_file, "rb") as fh:
            r = c.put(job["upload_path"], headers={**h, "X-Audio-Ext": "m4a"}, content=fh.read())
        assert r.status_code == 200, r.text
        assert r.json()["status"] == "queued"

        j = wait_done(c, h, job["id"])
        assert j["status"] == "done", j
        assert j["title"] == "Lancement de Parley"
        res = c.get("/v1/jobs/%s/result" % job["id"], headers=h).json()
        assert res["names"] == {"A": "Marie"} and res["turns"] and res["summary"]["sections"]
        assert res["docs"] == ["agenda.txt"]

        acc = c.get("/v1/account", headers=h).json()
        assert 3600 - 160 < acc["remaining_seconds"] < 3600 - 140, acc
        assert acc["used_seconds"] > 140

        # the trial allowance is a total: a recording longer than what is left is refused up front
        r = create(c, h, 3500)
        assert r.status_code == 402 and r.json()["error"]["code"] == "quota_exceeded"

        # the app deletes the server copy once it has the result
        assert c.delete("/v1/jobs/" + job["id"], headers=h).status_code == 204
        assert c.get("/v1/jobs/%s/result" % job["id"], headers=h).status_code == 404
        # ...but deleting does not give minutes back
        assert c.get("/v1/account", headers=h).json()["used_seconds"] > 140


def test_paid_plan_limits(env):
    with client_for(FakeOpenAI()) as c:
        h, acc = session(c, [xcode_transaction("essential.monthly")])
        assert acc["plan"] == "essential" and not acc["is_trial"] and acc["quota_seconds"] == 240 * 60
        r = create(c, h, 3 * 3600)
        assert r.status_code == 413 and r.json()["error"]["code"] == "file_too_long"
        # several entitlements (upgrade): the highest plan wins
        h, acc = session(c, [xcode_transaction("essential.monthly", otid="11"),
                             xcode_transaction("pro.yearly", otid="22",
                                               expires=int(time.time() * 1000) + 365 * 86400 * 1000)])
        assert acc["plan"] == "pro" and acc["quota_seconds"] == 600 * 60
        assert create(c, h, 60).status_code == 200
        assert create(c, h, 60).status_code == 200
        r = create(c, h, 60)
        assert r.status_code == 429 and r.json()["error"]["code"] == "too_many_jobs"


def test_rejected_transactions(env):
    with client_for(FakeOpenAI()) as c:
        expired = xcode_transaction(purchase=int(time.time() * 1000) - 40 * 86400 * 1000,
                                    expires=int(time.time() * 1000) - 10 * 86400 * 1000)
        _, acc = session(c, [expired])
        assert acc["plan"] == "none"
        _, acc = session(c, [xcode_transaction(bundle="com.evil.app")])
        assert acc["plan"] == "none"
        _, acc = session(c, [xcode_transaction(env="Production")])      # Production not enabled here
        assert acc["plan"] == "none"
        _, acc = session(c, ["not-a-jws"])
        assert acc["plan"] == "none"
        r = c.post("/v1/appstore/notifications", json={"signedPayload": "garbage"})
        assert r.status_code == 400


def test_upload_rejects_non_audio(env):
    with client_for(FakeOpenAI()) as c:
        h, _ = session(c, [xcode_transaction()])
        job = create(c, h, 60).json()
        r = c.put(job["upload_path"], headers={**h, "X-Audio-Ext": "m4a"}, content=b"this is not audio" * 100)
        assert r.status_code == 400 and r.json()["error"]["code"] == "invalid_audio"
        assert c.get("/v1/jobs/" + job["id"], headers=h).json()["needs_upload"]


def test_failure_is_retried_then_resumable(env, audio_file, monkeypatch):
    from app import jobs
    monkeypatch.setattr(jobs, "MAX_ATTEMPTS", 1)
    fake = FakeOpenAI(fail_dia_chunk=2)
    with client_for(fake) as c:
        h, _ = session(c, [xcode_transaction()])
        job = create(c, h, 150).json()
        with open(audio_file, "rb") as fh:
            c.put(job["upload_path"], headers=h, content=fh.read())
        j = wait_done(c, h, job["id"])
        assert j["status"] == "failed" and j["retryable"] and j["error_code"] == "service_unavailable"
        assert c.get("/v1/account", headers=h).json()["used_seconds"] == 0, "failures are not charged"
        fake.fail_dia_chunk = None
        before = fake.calls["flat"]
        assert c.post("/v1/jobs/%s/retry" % job["id"], headers=h).json()["status"] == "queued"
        j = wait_done(c, h, job["id"])
        assert j["status"] == "done"
        assert fake.calls["flat"] == before, "the retry reuses the finished text pass"


def test_public_pages(env):
    with client_for(FakeOpenAI()) as c:
        p = c.get("/v1/plans").json()
        assert p["trial"]["days"] == 7 and {x["id"] for x in p["plans"]} == {"essential", "pro"}
        assert "Politique de confidentialité" in c.get("/legal/privacy", headers={"accept-language": "fr-FR"}).text
        assert "Privacy policy" in c.get("/legal/privacy?lang=en").text
        assert c.get("/legal/terms").status_code == 200 and c.get("/support").status_code == 200
        assert c.get("/healthz").json()["ok"]
        assert c.get("/v1/account").status_code == 401


def test_periods():
    utc = dt.timezone.utc
    ent = appstore.Entitlement("pro", "x.pro.yearly", False, "1", "9", dt.datetime(2026, 1, 31, tzinfo=utc),
                               dt.datetime(2027, 1, 31, tzinfo=utc), "Sandbox")
    key, end = appstore.period_of(ent, dt.datetime(2026, 3, 15, tzinfo=utc))
    assert key == "9:1" and end == dt.datetime(2026, 3, 31, tzinfo=utc)
    key, end = appstore.period_of(ent, dt.datetime(2026, 2, 27, tzinfo=utc))
    assert key == "9:0" and end == dt.datetime(2026, 2, 28, tzinfo=utc)
    trial = appstore.Entitlement("pro", "x.pro.monthly", True, "5", "5", dt.datetime(2026, 1, 1, tzinfo=utc),
                                 dt.datetime(2026, 1, 8, tzinfo=utc), "Sandbox")
    assert appstore.period_of(trial)[0] == "trial:5"
