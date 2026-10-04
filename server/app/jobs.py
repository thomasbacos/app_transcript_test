"""
Background job runner: a small thread pool inside the API process.

Audio is uploaded to DATA_DIR/jobs/<id>/, processed, then deleted as soon as the job finishes (results
are text only and are deleted when the app has fetched them, or after RESULT_RETENTION_HOURS).
Transient failures (network, OpenAI 5xx / rate limits) are retried automatically; finished pieces are
cached, so a retry only redoes what was missing.

Runs on ONE instance (the uploaded audio is on that instance's disk): plenty for thousands of users,
since the heavy lifting happens at OpenAI.
"""
import concurrent.futures as cf
import datetime as dt
import glob
import json
import logging
import os
import shutil
import threading
import time

from sqlalchemy import select, update

from . import accounts, notify
from .config import get_settings
from .db import Account, Job, aware, session, utcnow
from .pipeline import process as proc
from .pipeline import transcribe

log = logging.getLogger("parley.jobs")

MAX_ATTEMPTS = 3


def job_dir(job_id):
    return os.path.join(get_settings().data_dir, "jobs", job_id)


def audio_path(job_id, ext=None):
    d = job_dir(job_id)
    if ext:
        return os.path.join(d, "audio." + ext)
    hits = glob.glob(os.path.join(d, "audio.*"))
    return hits[0] if hits else None


def classify(e):
    """-> (error_code, retryable, message for the app)."""
    s = str(e).lower()
    code = getattr(e, "status_code", None)
    if isinstance(e, ValueError) and "no_audio_stream" in s:
        return "invalid_audio", False, "This file contains no audio track."
    if isinstance(e, ValueError) and "audio_too_short" in s:
        return "audio_too_short", False, "The recording is too short to transcribe."
    if "insufficient_quota" in s or "exceeded your current quota" in s or "billing" in s:
        return "service_unavailable", True, "The transcription service is temporarily unavailable."
    if code in (401, 403) and ("api key" in s or "invalid_api_key" in s or "incorrect api key" in s):
        return "service_unavailable", True, "The transcription service is temporarily unavailable."
    if code == 429 or "rate limit" in s:
        return "busy", True, "The service is busy. Your recording will be retried automatically."
    if code and 500 <= code < 600:
        return "upstream_error", True, "The transcription service had a problem. Retrying."
    if "timed out" in s or "timeout" in s or "connection" in s:
        return "network", True, "Connection problem with the transcription service."
    if isinstance(e, (OSError,)) and "no space" in s:
        return "server_full", True, "The server is out of space."
    return "internal", True, "Something went wrong while processing this recording."


class Runner:
    def __init__(self, client_factory=None):
        s = get_settings()
        self.pool = cf.ThreadPoolExecutor(max_workers=s.workers, thread_name_prefix="job")
        self.client_factory = client_factory or self._openai
        self.cancel = {}
        self.lock = threading.Lock()
        self._stop = threading.Event()
        self._janitor = None

    @staticmethod
    def _openai():
        from openai import OpenAI
        key = get_settings().openai_api_key
        if not key:
            raise RuntimeError("OPENAI_API_KEY is not set")
        return OpenAI(api_key=key, timeout=1800.0, max_retries=3)

    # ------------------------------------------------------------ lifecycle ----
    def start(self):
        self.recover()
        self._janitor = threading.Thread(target=self._janitor_loop, daemon=True, name="janitor")
        self._janitor.start()

    def stop(self):
        """Shutdown (deploy, restart): running jobs are NOT cancelled. Their rows stay "processing" with
        the audio on disk, and recover() re-queues them when the server is back."""
        self._stop.set()
        self.pool.shutdown(wait=False, cancel_futures=True)

    def recover(self):
        """After a restart: re-queue what was running if its audio is still here, else fail it so the app
        re-uploads (it keeps the recording locally)."""
        requeue = []
        with session() as db:
            for j in db.scalars(select(Job).where(Job.status.in_(("queued", "processing")))):
                if audio_path(j.id):
                    j.status, j.stage = "queued", "queued"
                    requeue.append(j.id)
                else:
                    j.status, j.error_code, j.retryable = "failed", "audio_missing", True
                    j.error_message = "The server restarted before processing finished. Upload again."
        for job_id in requeue:              # after the commit: the worker must see "queued"
            self.submit(job_id)

    def submit(self, job_id, delay=0):
        self.cancel.setdefault(job_id, threading.Event())
        if delay:
            t = threading.Timer(delay, self._submit_now, args=(job_id,))
            t.daemon = True
            t.start()
        else:
            self._submit_now(job_id)

    def _submit_now(self, job_id):
        if self._stop.is_set() or self.cancel.get(job_id, threading.Event()).is_set():
            return
        try:
            self.pool.submit(self._run, job_id)
        except RuntimeError:            # pool shut down
            pass

    def request_cancel(self, job_id):
        ev = self.cancel.get(job_id)
        if ev:
            ev.set()

    # ------------------------------------------------------------------ run ----
    def _run(self, job_id):
        ev = self.cancel.setdefault(job_id, threading.Event())
        with session() as db:
            claimed = db.execute(update(Job).where(Job.id == job_id, Job.status == "queued")
                                 .values(status="processing", stage="preparing")).rowcount
            if claimed != 1:
                return
            j = db.get(Job, job_id)
            j.attempts = (j.attempts or 0) + 1
            j.error_code = j.error_message = None
            opts = json.loads(j.options_json or "{}")
            owner = j.account_id
        src = audio_path(job_id)
        d = job_dir(job_id)
        docs = sorted(glob.glob(os.path.join(d, "docs", "*")))
        work = os.path.join(d, "work")
        cache = transcribe.Cache(os.path.join(d, "cache"))
        s = get_settings()
        last = {"t": 0.0, "p": 0.0, "stage": None}

        def progress(stage, overall):
            now = time.time()
            if overall < last["p"]:
                return
            if stage == last["stage"] and now - last["t"] < 1.5 and overall - last["p"] < 0.05:
                last["p"] = overall
                return
            last.update(t=now, p=overall, stage=stage)
            try:
                with session() as db2:
                    jj = db2.get(Job, job_id)
                    if jj and jj.status == "processing":
                        jj.stage, jj.progress = stage, round(overall, 3)
            except Exception as e:          # progress is cosmetic
                log.debug("progress update failed: %s", e)

        def on_duration(real):
            """The decoded length is the truth (a file header can lie): check it before any API call."""
            with accounts.account_lock(owner), session() as db:
                jj = db.get(Job, job_id)
                if jj is None or real <= (jj.duration_seconds or jj.declared_seconds) * 1.05 + 10:
                    return
                accounts.check_can_start(db, db.get(Account, owner), real, exclude_job=job_id)
                jj.duration_seconds = real

        try:
            if not src:
                raise FileNotFoundError("audio_missing")
            client = self.client_factory()
            models = transcribe.Models(s.transcribe_model, s.diarize_model)
            result = proc.process(src, docs, opts, client, models, (s.llm_model, s.llm_fallback_model), cache,
                                  work, progress=progress, cancelled=ev.is_set, parallel=s.diarize_parallel,
                                  on_duration=on_duration)
        except transcribe.Cancelled:
            with session() as db:
                j = db.get(Job, job_id)
                if j and j.status == "processing":
                    j.status, j.stage = "cancelled", None
            self._cleanup(job_id, everything=True)
            return
        except Exception as e:
            self._failed(job_id, e)
            return
        finally:
            shutil.rmtree(work, ignore_errors=True)

        try:
            with accounts.account_lock(owner), session() as db:
                j = db.get(Job, job_id)
                if j is None or j.status != "processing":      # deleted meanwhile
                    self._cleanup(job_id, everything=True)
                    return
                j.duration_seconds = result["duration"]
                j.result_json = json.dumps(result, ensure_ascii=False)
                j.title = (result.get("title") or "")[:300] or None
                j.status, j.stage, j.progress, j.finished_at = "done", "done", 1.0, utcnow()
                accounts.charge(db, j)
                install_id, title = j.install_id, j.title
        except Exception as e:                              # never leave a job "processing" forever
            self._failed(job_id, e)
            return
        self._cleanup(job_id)                               # audio and cache: no longer needed
        self.cancel.pop(job_id, None)
        notify.job_done(install_id, job_id, title)
        log.info("job %s done (%.0fs audio)", job_id, result["duration"])

    def _failed(self, job_id, e):
        if isinstance(e, FileNotFoundError) and "audio_missing" in str(e):
            code, retryable, msg = "audio_missing", True, "The audio is no longer on the server. Upload again."
        elif isinstance(e, accounts.QuotaError):
            code, retryable, msg = e.code, False, e.message
        else:
            code, retryable, msg = classify(e)
        log.warning("job %s failed: %s: %s", job_id, code, str(e)[:300])
        with session() as db:
            j = db.get(Job, job_id)
            if j is None or j.status != "processing":        # deleted meanwhile
                return
            auto = retryable and code != "audio_missing" and (j.attempts or 0) < MAX_ATTEMPTS
            if auto:
                j.status, j.stage = "queued", "retrying"
                j.error_code, j.error_message = code, msg
                delay = 20 * (j.attempts or 1) ** 2
            else:
                j.status, j.error_code, j.error_message, j.retryable = "failed", code, msg, retryable
                j.finished_at = utcnow()
                install_id = j.install_id
        if auto:
            self.submit(job_id, delay=delay)
        else:
            notify.job_failed(install_id, job_id)
            if not retryable:
                self._cleanup(job_id, everything=True)

    def _cleanup(self, job_id, everything=False):
        d = job_dir(job_id)
        if everything:
            shutil.rmtree(d, ignore_errors=True)
            return
        for p in glob.glob(os.path.join(d, "audio.*")):
            try:
                os.remove(p)
            except OSError:
                pass
        shutil.rmtree(os.path.join(d, "docs"), ignore_errors=True)
        shutil.rmtree(os.path.join(d, "cache"), ignore_errors=True)
        try:
            os.rmdir(d)
        except OSError:
            pass

    # ------------------------------------------------------------- janitor ----
    def _janitor_loop(self):
        while not self._stop.wait(600):
            try:
                self.purge()
            except Exception as e:
                log.warning("purge failed: %s", e)

    def purge(self, now=None):
        """Retention: results after RESULT_RETENTION_HOURS, failed jobs' audio after AUDIO_RETENTION_HOURS,
        uploads never completed after 6 h."""
        s = get_settings()
        now = now or utcnow()
        with session() as db:
            for j in db.scalars(select(Job)):
                age = now - (aware(j.finished_at) or aware(j.created_at))
                if j.status == "done" and age > dt.timedelta(hours=s.result_retention_hours):
                    j.result_json, j.status = None, "expired"
                elif j.status in ("failed", "cancelled") and age > dt.timedelta(hours=s.audio_retention_hours):
                    self._cleanup(j.id, everything=True)
                    if j.status == "failed":
                        j.status = "expired"
                elif j.status == "awaiting_audio" and age > dt.timedelta(hours=6):
                    j.status = "expired"
                    self._cleanup(j.id, everything=True)
