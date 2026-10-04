"""Allowance and access edge cases found in review: parallel requests, lying file headers, replayed
refunds, sandbox renewals, jobs outliving a subscription."""
import concurrent.futures as cf
import datetime as dt
import time

import jwt

from app import appstore
from conftest import BUNDLE, FakeOpenAI, xcode_transaction
from test_api import client_for, create, session, wait_done


def test_parallel_creations_cannot_exceed_the_allowance(env, monkeypatch):
    monkeypatch.setenv("PLAN_TRIAL_MINUTES", "10")
    monkeypatch.setenv("MAX_ACTIVE_JOBS", "50")
    from app import config
    config.reset_settings()
    with client_for(FakeOpenAI()) as c:
        h, _ = session(c, [xcode_transaction(trial=True)])
        with cf.ThreadPoolExecutor(8) as ex:
            codes = list(ex.map(lambda _: create(c, h, 240).status_code, range(8)))
        assert codes.count(200) == 2, codes          # 2 x 4 min fit in 10 min, the 3rd does not
        assert codes.count(402) == 6


def test_a_lying_file_header_is_caught_before_any_api_call(env, audio_file, monkeypatch):
    monkeypatch.setenv("PLAN_TRIAL_MINUTES", "1")
    from app import config, main
    config.reset_settings()
    monkeypatch.setattr(main, "probe_duration", lambda path: 30.0)     # header says 30 s, audio is 150 s
    fake = FakeOpenAI()
    with client_for(fake) as c:
        h, _ = session(c, [xcode_transaction(trial=True)])
        job = create(c, h, 30).json()
        with open(audio_file, "rb") as fh:
            assert c.put(job["upload_path"], headers=h, content=fh.read()).status_code == 200
        j = wait_done(c, h, job["id"])
        assert j["status"] == "failed" and j["error_code"] == "quota_exceeded" and not j["retryable"]
        assert fake.calls["flat"] == fake.calls["dia"] == fake.calls["probe"] == 0
        assert c.get("/v1/account", headers=h).json()["used_seconds"] == 0


def test_a_refunded_transaction_cannot_be_replayed(env):
    tx = xcode_transaction("pro.monthly", otid="777")
    with client_for(FakeOpenAI()) as c:
        _, acc = session(c, [tx])
        assert acc["active"]
        payload = jwt.encode({"notificationType": "REFUND", "notificationUUID": "n1", "version": "2.0",
                              "signedDate": int(time.time() * 1000),
                              "data": {"environment": "Xcode", "bundleId": BUNDLE, "signedTransactionInfo": tx}},
                             "xcode-local-signing-key-for-tests-only-000", algorithm="HS256")
        assert c.post("/v1/appstore/notifications", json={"signedPayload": payload}).status_code == 200
        _, acc = session(c, [tx])
        assert not acc["active"]


def test_sandbox_renewals_share_one_monthly_allowance():
    utc = dt.timezone.utc
    now = dt.datetime(2026, 5, 20, tzinfo=utc)
    a = appstore.Entitlement("pro", "x.pro.monthly", False, "42", "1001", now, now + dt.timedelta(minutes=5), "Sandbox")
    b = appstore.Entitlement("pro", "x.pro.monthly", False, "42", "1002", now, now + dt.timedelta(minutes=10), "Sandbox")
    assert appstore.period_of(a, now)[0] == appstore.period_of(b, now)[0] == "sbx:42:2026-05"


def test_jobs_stay_reachable_from_their_installation(env, audio_file):
    with client_for(FakeOpenAI()) as c:
        h, _ = session(c, [xcode_transaction(trial=True)], install="install-0042")
        job = create(c, h, 150).json()
        with open(audio_file, "rb") as fh:
            c.put(job["upload_path"], headers=h, content=fh.read())
        # the trial ends while the job runs: the next session lands on the free account...
        h2, acc = session(c, [], install="install-0042")
        assert not acc["active"]
        # ...but this iPhone still gets its transcript
        assert wait_done(c, h2, job["id"])["status"] == "done"
        assert c.get("/v1/jobs/%s/result" % job["id"], headers=h2).status_code == 200
        # another installation does not
        h3, _ = session(c, [], install="install-0099")
        assert c.get("/v1/jobs/" + job["id"], headers=h3).status_code == 404
