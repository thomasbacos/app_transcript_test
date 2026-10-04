"""
Parley API.

    POST   /v1/auth/session          verify App Store transactions -> session token + allowance
    GET    /v1/account               allowance (plan, minutes used / left, reset date)
    DELETE /v1/account               delete everything stored for this account
    GET    /v1/plans                 plans and allowances (public)
    POST   /v1/jobs                  create a job (options + optional reference documents)
    PUT    /v1/jobs/{id}/audio       upload the audio (raw body) -> queued
    GET    /v1/jobs                  this account's recent jobs
    GET    /v1/jobs/{id}             status, stage, progress, error
    GET    /v1/jobs/{id}/result      transcript, speakers, summary
    POST   /v1/jobs/{id}/retry       resume a failed job (finished pieces are reused)
    DELETE /v1/jobs/{id}             cancel / delete the job and its data
    POST   /v1/appstore/notifications  App Store Server Notifications V2 (refunds, renewals)
    GET    /legal/privacy, /legal/terms, /support   pages linked from the app and App Store Connect
"""
import collections
import datetime as dt
import json
import logging
import os
import re
import threading
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, Response
from pydantic import BaseModel, Field
from sqlalchemy import func, select

from . import accounts, appstore, legal
from .config import get_settings
from .db import ACTIVE, Account, Install, Job, Usage, init_db, session, utcnow
from .jobs import Runner, audio_path, job_dir
from .pipeline import grounding
from .pipeline.transcribe import probe_duration

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                    format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("parley.api")

AUDIO_EXT = {"m4a", "mp4", "mp3", "wav", "caf", "aac", "mov", "aif", "aiff", "m4v", "webm", "ogg", "flac"}
MAX_DOCS, MAX_DOC_MB = 5, 15

runner: Runner | None = None


def create_app(client_factory=None):
    @asynccontextmanager
    async def lifespan(_app):
        global runner
        s = get_settings()
        init_db(s.database_url)
        if not s.openai_api_key and client_factory is None:
            log.warning("OPENAI_API_KEY is not set: jobs will fail until it is")
        runner = Runner(client_factory)
        runner.start()
        yield
        runner.stop()

    app = FastAPI(title="Parley API", version="1.0.0", lifespan=lifespan)

    @app.exception_handler(accounts.QuotaError)
    async def _quota(_req, e: accounts.QuotaError):
        return JSONResponse({"error": {"code": e.code, "message": e.message, **e.extra}}, status_code=e.http)

    @app.exception_handler(HTTPException)
    async def _http(_req, e: HTTPException):
        d = e.detail if isinstance(e.detail, dict) else {"code": "error", "message": str(e.detail)}
        return JSONResponse({"error": d}, status_code=e.status_code, headers=getattr(e, "headers", None))

    _routes(app)
    return app


def err(status, code, message, **extra):
    return HTTPException(status, {"code": code, "message": message, **extra})


# ------------------------------------------------------------------ helpers ----
class _RateLimit:
    def __init__(self, per_minute):
        self.per_minute, self.hits, self.lock = per_minute, collections.defaultdict(collections.deque), threading.Lock()

    def check(self, key):
        now = time.time()
        with self.lock:
            q = self.hits[key]
            while q and now - q[0] > 60:
                q.popleft()
            if len(q) >= self.per_minute:
                raise err(429, "rate_limited", "Too many requests, try again in a minute.")
            q.append(now)


_session_limit = _RateLimit(30)


def auth(authorization: str = Header(default="")):
    if not authorization.lower().startswith("bearer "):
        raise err(401, "unauthorized", "Missing session token.")
    try:
        return accounts.read_token(authorization[7:].strip())
    except accounts.AuthError:
        raise err(401, "unauthorized", "Session expired.")


def _own_job(db, job_id, account_id):
    j = db.get(Job, job_id)
    if j is None or j.account_id != account_id or j.status in ("deleted",):
        raise err(404, "not_found", "Unknown job.")
    return j


def job_out(j):
    return {"id": j.id, "status": j.status, "stage": j.stage, "progress": round(j.progress or 0.0, 3),
            "error_code": j.error_code, "error_message": j.error_message,
            "retryable": bool(j.retryable), "needs_upload": j.status == "awaiting_audio",
            "duration": j.duration_seconds or j.declared_seconds, "title": j.title,
            "created_at": j.created_at.isoformat() if j.created_at else None}


def _clean_options(raw):
    try:
        o = json.loads(raw or "{}")
    except ValueError:
        raise err(400, "bad_options", "options must be JSON.")
    if not isinstance(o, dict):
        raise err(400, "bad_options", "options must be an object.")
    langs = [str(l).strip().lower()[:8] for l in (o.get("languages") or []) if re.fullmatch(r"[A-Za-z-]{2,8}", str(l))]
    terms = o.get("terms") or []
    if isinstance(terms, str):
        terms = re.split(r"[,;\n]", terms)
    terms = [str(t).strip()[:60] for t in terms if str(t).strip()][:100]
    sl = str(o.get("summary_language") or "auto").lower()[:8]
    return {"languages": langs[:5], "terms": terms, "speakers": bool(o.get("speakers", True)),
            "correct": bool(o.get("correct", True)), "summary": bool(o.get("summary", True)),
            "summary_language": sl if re.fullmatch(r"auto|[a-z]{2}(-[a-z]{2})?", sl) else "auto",
            "ui_language": str(o.get("ui_language") or "en")[:8]}


# ------------------------------------------------------------------- routes ----
class SessionIn(BaseModel):
    install_id: str = Field(min_length=8, max_length=64)
    transactions: list[str] = Field(default_factory=list, max_length=10)
    apns_token: str | None = Field(default=None, max_length=200)
    apns_env: str | None = Field(default=None, max_length=20)
    locale: str | None = Field(default=None, max_length=20)
    app_version: str | None = Field(default=None, max_length=40)


class NotificationIn(BaseModel):
    signedPayload: str


def _routes(app):
    @app.get("/healthz")
    def healthz():
        return {"ok": True, "time": utcnow().isoformat()}

    @app.get("/v1/plans")
    def plans():
        s = get_settings()
        by_plan = collections.defaultdict(list)
        for suffix, p in s.product_map.items():
            by_plan[p].append(suffix)
        return {"trial": {"days": 7, "minutes": s.plans["trial"].minutes,
                          "max_file_minutes": s.plans["trial"].max_file_minutes},
                "plans": [{"id": p.id, "minutes": p.minutes, "max_file_minutes": p.max_file_minutes,
                           "products": sorted(by_plan.get(p.id, []))}
                          for pid, p in s.plans.items() if pid != "trial"]}

    @app.post("/v1/auth/session")
    def open_session(body: SessionIn, request: Request):
        _session_limit.check(request.client.host if request.client else "?")
        if not re.fullmatch(r"[A-Za-z0-9-]{8,64}", body.install_id):
            raise err(400, "bad_install_id", "Invalid install id.")
        with session() as db:
            acc, errors = accounts.open_session(db, body.install_id, body.transactions, body.apns_token,
                                                body.apns_env, body.locale, body.app_version)
            if errors:
                log.info("session %s: %d transaction(s) rejected: %s", body.install_id[:8], len(errors), errors[:2])
            token, exp = accounts.issue_token(acc.id, body.install_id)
            return {"token": token, "expires_at": exp.isoformat(), "account": accounts.status(db, acc),
                    "rejected_transactions": len(errors)}

    @app.get("/v1/account")
    def account(who=Depends(auth)):
        with session() as db:
            acc = db.get(Account, who[0])
            if acc is None:
                raise err(401, "unauthorized", "Unknown account.")
            return accounts.status(db, acc)

    @app.delete("/v1/account", status_code=204)
    def delete_account(who=Depends(auth)):
        acc_id, install_id = who
        with session() as db:
            for j in db.scalars(select(Job).where(Job.account_id == acc_id)):
                _scrub(j)
            for inst in db.scalars(select(Install).where(Install.account_id == acc_id)):
                db.delete(inst)
            inst = db.get(Install, install_id) if install_id else None
            if inst:
                db.delete(inst)
        return Response(status_code=204)

    @app.post("/v1/jobs")
    async def create_job(options: str = Form("{}"), duration: float = Form(...),
                         docs: list[UploadFile] | None = File(default=None), who=Depends(auth)):
        acc_id, install_id = who
        s = get_settings()
        opts = _clean_options(options)
        if not (0 < duration < 24 * 3600):
            raise err(400, "bad_duration", "duration (seconds) is required.")
        docs = [d for d in (docs or []) if d and d.filename][:MAX_DOCS]
        with session() as db:
            acc = db.get(Account, acc_id)
            if acc is None:
                raise err(401, "unauthorized", "Unknown account.")
            active = db.execute(select(func.count()).select_from(Job).where(
                Job.account_id == acc_id, Job.status.in_(ACTIVE))).scalar()
            if active >= s.max_active_jobs:
                raise err(429, "too_many_jobs", "Wait for the current transcriptions to finish.")
            since = utcnow() - dt.timedelta(days=1)
            today = db.execute(select(func.count()).select_from(Job).where(
                Job.account_id == acc_id, Job.created_at >= since)).scalar()
            if today >= s.jobs_per_day:
                raise err(429, "daily_limit", "Daily limit reached, try again tomorrow.")
            accounts.check_can_start(db, acc, duration)
            j = Job(id=uuid.uuid4().hex, account_id=acc_id, install_id=install_id, status="awaiting_audio",
                    declared_seconds=float(duration), period_key=acc.period_key,
                    options_json=json.dumps(opts, ensure_ascii=False))
            db.add(j)
            db.flush()
            jid = j.id
            out = job_out(j)
        if docs:
            ddir = os.path.join(job_dir(jid), "docs")
            os.makedirs(ddir, exist_ok=True)
            for i, d in enumerate(docs):
                name = re.sub(r"[^\w.\- ]", "_", os.path.basename(d.filename))[-80:] or "doc.txt"
                if grounding.kind(name) != "doc":
                    continue
                data = await d.read(MAX_DOC_MB * 1024 * 1024 + 1)
                if len(data) > MAX_DOC_MB * 1024 * 1024:
                    raise err(413, "doc_too_large", "Reference documents are limited to %d MB." % MAX_DOC_MB)
                with open(os.path.join(ddir, "%d_%s" % (i, name)), "wb") as fh:
                    fh.write(data)
        out["upload_path"] = "/v1/jobs/%s/audio" % jid
        return out

    @app.put("/v1/jobs/{job_id}/audio")
    async def upload_audio(job_id: str, request: Request, x_audio_ext: str = Header(default="m4a"), who=Depends(auth)):
        acc_id, _ = who
        s = get_settings()
        ext = x_audio_ext.lower().strip(".")
        if ext not in AUDIO_EXT:
            raise err(400, "bad_format", "Unsupported audio format.")
        with session() as db:
            j = _own_job(db, job_id, acc_id)
            if j.status == "failed" and j.error_code == "audio_missing":
                j.status = "awaiting_audio"
            if j.status != "awaiting_audio":
                return job_out(j)              # already uploaded (e.g. a retried background upload)
        d = job_dir(job_id)
        os.makedirs(d, exist_ok=True)
        old = audio_path(job_id)
        if old:
            os.remove(old)
        path, tmp = audio_path(job_id, ext), os.path.join(d, "upload.part")
        limit, n = s.max_upload_mb * 1024 * 1024, 0
        try:
            with open(tmp, "wb") as fh:
                async for chunk in request.stream():
                    n += len(chunk)
                    if n > limit:
                        raise err(413, "file_too_large", "The file is larger than %d MB." % s.max_upload_mb)
                    fh.write(chunk)
            if n == 0:
                raise err(400, "empty_upload", "No audio received.")
            os.replace(tmp, path)
            try:
                real = probe_duration(path)
            except Exception:
                raise err(400, "invalid_audio", "This file could not be read as audio.")
        except HTTPException:
            for p in (tmp, path):
                if os.path.exists(p):
                    os.remove(p)
            raise
        refused = None
        with session() as db:
            j = _own_job(db, job_id, acc_id)
            acc = db.get(Account, acc_id)
            if real > j.declared_seconds * 1.05 + 10:      # the app under-declared: check the real length
                try:
                    accounts.check_can_start(db, acc, real, exclude_job=job_id)
                except accounts.QuotaError as e:
                    j.status, j.error_code, j.error_message, j.retryable = "failed", e.code, e.message, False
                    refused = e
            if refused is None:
                j.duration_seconds, j.audio_ext, j.status, j.stage, j.progress = real, ext, "queued", "queued", 0.0
            out = job_out(j)
        if refused is not None:
            os.remove(path)
            raise refused
        runner.submit(job_id)
        return out

    @app.get("/v1/jobs")
    def list_jobs(who=Depends(auth)):
        with session() as db:
            rows = db.scalars(select(Job).where(Job.account_id == who[0], Job.status != "deleted")
                              .order_by(Job.created_at.desc()).limit(50))
            return {"jobs": [job_out(j) for j in rows]}

    @app.get("/v1/jobs/{job_id}")
    def get_job(job_id: str, who=Depends(auth)):
        with session() as db:
            return job_out(_own_job(db, job_id, who[0]))

    @app.get("/v1/jobs/{job_id}/result")
    def get_result(job_id: str, who=Depends(auth)):
        with session() as db:
            j = _own_job(db, job_id, who[0])
            if j.status == "expired":
                raise err(410, "expired", "This result is no longer stored on the server.")
            if j.status != "done" or not j.result_json:
                raise err(409, "not_ready", "Not finished yet.")
            return Response(j.result_json, media_type="application/json")

    @app.post("/v1/jobs/{job_id}/retry")
    def retry(job_id: str, who=Depends(auth)):
        with session() as db:
            j = _own_job(db, job_id, who[0])
            if j.status not in ("failed",) or not j.retryable:
                return job_out(j)
            acc = db.get(Account, who[0])
            accounts.check_can_start(db, acc, j.duration_seconds or j.declared_seconds, exclude_job=job_id)
            j.period_key = acc.period_key
            j.error_code = j.error_message = None
            j.attempts = 0
            if audio_path(job_id):
                j.status, j.stage, j.progress = "queued", "queued", 0.0
                submit = True
            else:
                j.status, submit = "awaiting_audio", False
            out = job_out(j)
        if submit:
            runner.submit(job_id)
        return out

    @app.delete("/v1/jobs/{job_id}", status_code=204)
    def delete_job(job_id: str, who=Depends(auth)):
        with session() as db:
            j = db.get(Job, job_id)
            if j is not None and j.account_id == who[0]:
                _scrub(j)
        return Response(status_code=204)

    @app.post("/v1/appstore/notifications")
    def appstore_notification(body: NotificationIn):
        try:
            n = appstore.verify_notification(body.signedPayload)
        except appstore.InvalidTransaction as e:
            log.warning("App Store notification rejected: %s", e)
            raise err(400, "invalid", "Invalid notification.")
        kind = n.rawNotificationType or ""
        info = n.data.signedTransactionInfo if n.data else None
        if info:
            try:
                tx = appstore.verify_transaction(info)
            except appstore.InvalidTransaction as e:
                log.warning("notification transaction rejected: %s", e)
                return {"ok": True}
            with session() as db:
                acc_id = "ot:" + str(tx.originalTransactionId)
                if kind in ("REFUND", "REVOKE"):
                    acc = db.get(Account, acc_id)
                    if acc:
                        acc.revoked = True
                else:
                    ent = appstore.entitlement_from(tx)
                    if ent:
                        accounts.apply_entitlement(db, ent)
                    elif kind == "EXPIRED":
                        acc = db.get(Account, acc_id)
                        if acc:
                            acc.expires_at = utcnow()
        log.info("App Store notification %s %s", kind, n.rawSubtype or "")
        return {"ok": True}

    # ---------------------------------------------------------------- pages ----
    @app.get("/", response_class=HTMLResponse)
    def home(request: Request):
        return legal.page("home", legal.lang_of(request))

    @app.get("/legal/privacy", response_class=HTMLResponse)
    def privacy(request: Request):
        return legal.page("privacy", legal.lang_of(request))

    @app.get("/legal/terms", response_class=HTMLResponse)
    def terms(request: Request):
        return legal.page("terms", legal.lang_of(request))

    @app.get("/support", response_class=HTMLResponse)
    def support(request: Request):
        return legal.page("support", legal.lang_of(request))

    @app.get("/admin/stats")
    def stats(x_admin_token: str = Header(default="")):
        s = get_settings()
        if not s.admin_token or x_admin_token != s.admin_token:
            raise err(403, "forbidden", "Forbidden.")
        with session() as db:
            since = utcnow() - dt.timedelta(days=30)
            by_plan = dict(db.execute(select(Account.plan, func.count()).where(Account.id.like("ot:%"))
                                      .group_by(Account.plan)).all())
            jobs = dict(db.execute(select(Job.status, func.count()).where(Job.created_at >= since)
                                   .group_by(Job.status)).all())
            secs = db.execute(select(func.coalesce(func.sum(Job.duration_seconds), 0.0))
                              .where(Job.charged.is_(True), Job.created_at >= since)).scalar()
            trials = db.execute(select(func.count()).select_from(Account).where(Account.is_trial.is_(True))).scalar()
        hours = float(secs or 0) / 3600
        return {"subscribers_by_plan": by_plan, "trials": trials, "jobs_30d": jobs,
                "audio_hours_30d": round(hours, 1), "estimated_openai_cost_usd_30d": round(hours * 1.0, 2)}


def _scrub(j):
    """Delete a job's content (audio, documents, transcript); keep the anonymous row for allowance
    accounting."""
    if j.status in ACTIVE and runner:
        runner.request_cancel(j.id)
    import shutil
    shutil.rmtree(job_dir(j.id), ignore_errors=True)
    j.status, j.result_json, j.title, j.options_json = "deleted", None, None, "{}"


app = create_app()
