"""Accounts, sessions and allowances."""
import datetime as dt
import threading

import jwt
from sqlalchemy import func, select

from . import appstore
from .config import get_settings
from .db import ACTIVE, Account, Install, Job, RevokedTransaction, Usage, aware, utcnow


class AuthError(Exception):
    pass


class TransientError(Exception):
    """Apple could not be reached to verify a purchase: try again later, do not downgrade the user."""


_locks = {}
_locks_guard = threading.Lock()


def account_lock(account_id):
    """Serializes allowance checks and charges per account (the server runs as a single instance), so
    parallel requests cannot each see the same remaining minutes."""
    with _locks_guard:
        return _locks.setdefault(account_id, threading.Lock())


# ------------------------------------------------------------------ sessions ----
def issue_token(account_id, install_id):
    s = get_settings()
    exp = utcnow() + dt.timedelta(hours=s.session_hours)
    tok = jwt.encode({"sub": account_id, "ins": install_id, "exp": exp, "iat": utcnow()}, s.secret_key,
                     algorithm="HS256")
    return tok, exp


def read_token(token):
    try:
        c = jwt.decode(token, get_settings().secret_key, algorithms=["HS256"])
        return c["sub"], c.get("ins")
    except (jwt.PyJWTError, KeyError) as e:
        raise AuthError(str(e)) from e


# ------------------------------------------------------------------ accounts ----
def apply_entitlement(db, ent, now=None):
    """Create / refresh the subscription account from a verified entitlement."""
    now = now or utcnow()
    acc = db.get(Account, ent.account_id)
    if acc is None:
        acc = Account(id=ent.account_id)
        db.add(acc)
    key, end = appstore.period_of(ent, now)
    acc.plan, acc.product_id, acc.is_trial = ent.plan, ent.product_id, ent.is_trial
    acc.period_key, acc.period_end, acc.expires_at = key, end, ent.expires
    acc.transaction_id, acc.purchase_at = ent.transaction_id, ent.purchase
    acc.environment, acc.revoked = ent.environment, False
    return acc


def roll_period(acc, now=None):
    """A yearly subscription gets a fresh allowance every month even if the app has not opened a new
    session since: recompute the window from the stored purchase date."""
    if acc is None or acc.is_trial or not acc.purchase_at or not acc.transaction_id:
        return
    now = now or utcnow()
    end = aware(acc.period_end)
    if end is not None and now < end:
        return
    ent = appstore.Entitlement(plan=acc.plan, product_id=acc.product_id or "", is_trial=False,
                               original_transaction_id=acc.id.split(":", 1)[-1], transaction_id=acc.transaction_id,
                               purchase=aware(acc.purchase_at), expires=aware(acc.expires_at),
                               environment=acc.environment or "")
    acc.period_key, acc.period_end = appstore.period_of(ent, now)


def free_account(db, install_id):
    acc_id = "inst:" + install_id
    acc = db.get(Account, acc_id)
    if acc is None:
        acc = Account(id=acc_id, plan="none")
        db.add(acc)
    return acc


def open_session(db, install_id, transactions, apns_token=None, apns_env=None, locale=None, app_version=None):
    """Verify the device's transactions, pick the best entitlement, link the install to its account."""
    ents, errors, transient = [], [], False
    for jws in (transactions or [])[:10]:
        try:
            ents.append(appstore.entitlement_from(appstore.verify_transaction(jws)))
        except appstore.InvalidTransaction as e:
            errors.append(str(e))
            transient = transient or e.retryable
    # a refunded transaction stays refunded, even if an old signed copy of it is presented again
    ents = [e for e in ents if e and db.get(RevokedTransaction, e.transaction_id) is None]
    ent = appstore.best(ents)
    if ent is None and transient:
        raise TransientError("purchase verification temporarily unavailable")
    acc = apply_entitlement(db, ent) if ent else free_account(db, install_id)
    inst = db.get(Install, install_id)
    if inst is None:
        inst = Install(id=install_id)
        db.add(inst)
    inst.account_id = acc.id
    if apns_token:
        inst.apns_token, inst.apns_env = apns_token[:200], (apns_env or "production")[:20]
    inst.locale = (locale or inst.locale or "")[:20] or None
    inst.app_version = (app_version or inst.app_version or "")[:40] or None
    db.flush()
    return acc, errors


# ---------------------------------------------------------------- allowances ----
def is_active(acc, now=None):
    now = now or utcnow()
    if acc is None or acc.plan == "none" or acc.revoked:
        return False
    exp = aware(acc.expires_at)
    return exp is None or exp + appstore.GRACE >= now


def plan_of(acc):
    plans = get_settings().plans
    if not is_active(acc):
        return None
    return plans["trial"] if acc.is_trial else plans.get(acc.plan)


def used_seconds(db, acc_id, period_key):
    u = db.get(Usage, (acc_id, period_key))
    return u.seconds if u else 0.0


def reserved_seconds(db, acc_id, period_key, exclude_job=None):
    q = select(func.coalesce(func.sum(func.coalesce(Job.duration_seconds, Job.declared_seconds)), 0.0)).where(
        Job.account_id == acc_id, Job.period_key == period_key, Job.status.in_(ACTIVE), Job.charged.is_(False))
    if exclude_job:
        q = q.where(Job.id != exclude_job)
    return float(db.execute(q).scalar() or 0.0)


def status(db, acc):
    """What the app shows: plan, allowance, what is left, when it resets."""
    roll_period(acc)
    plan = plan_of(acc)
    out = {"plan": acc.plan if plan else "none", "is_trial": bool(acc.is_trial and plan),
           "product_id": acc.product_id if plan else None, "active": bool(plan),
           "expires_at": aware(acc.expires_at).isoformat() if acc.expires_at and plan else None,
           "period_end": aware(acc.period_end).isoformat() if acc.period_end and plan else None,
           "quota_seconds": 0, "used_seconds": 0.0, "reserved_seconds": 0.0, "remaining_seconds": 0.0,
           "max_file_seconds": 0}
    if plan:
        used = used_seconds(db, acc.id, acc.period_key)
        res = reserved_seconds(db, acc.id, acc.period_key)
        quota = plan.minutes * 60
        out.update(quota_seconds=quota, used_seconds=round(used, 1), reserved_seconds=round(res, 1),
                   remaining_seconds=round(max(0.0, quota - used - res), 1), max_file_seconds=plan.max_file_minutes * 60)
    return out


class QuotaError(Exception):
    def __init__(self, code, message, http=402, **extra):
        super().__init__(message)
        self.code, self.message, self.http, self.extra = code, message, http, extra


def check_can_start(db, acc, seconds, exclude_job=None):
    """Raise QuotaError if this account may not transcribe `seconds` of audio now."""
    roll_period(acc)
    plan = plan_of(acc)
    if plan is None:
        raise QuotaError("subscription_required", "An active subscription or free trial is required.")
    if seconds > plan.max_file_minutes * 60 + 5:
        raise QuotaError("file_too_long", "This recording is longer than your plan allows per file.",
                         http=413, max_file_seconds=plan.max_file_minutes * 60)
    used = used_seconds(db, acc.id, acc.period_key)
    res = reserved_seconds(db, acc.id, acc.period_key, exclude_job=exclude_job)
    left = plan.minutes * 60 - used - res
    if seconds > left + 5:                      # a few seconds of tolerance on rounding
        raise QuotaError("quota_exceeded", "Not enough transcription time left for this recording.",
                         remaining_seconds=max(0.0, round(left, 1)), is_trial=bool(acc.is_trial))
    return plan


def revoke(db, transaction_id, original_transaction_id):
    if transaction_id and db.get(RevokedTransaction, str(transaction_id)) is None:
        db.add(RevokedTransaction(transaction_id=str(transaction_id)))
    acc = db.get(Account, "ot:%s" % original_transaction_id)
    if acc and (acc.transaction_id is None or acc.transaction_id == str(transaction_id)):
        acc.revoked = True


def charge(db, job):
    """Count a finished job against its period, once. Call under account_lock(job.account_id)."""
    if job.charged or not job.period_key:
        return
    u = db.get(Usage, (job.account_id, job.period_key))
    if u is None:
        u = Usage(account_id=job.account_id, period_key=job.period_key, seconds=0.0)
        db.add(u)
    u.seconds = (u.seconds or 0.0) + float(job.duration_seconds or job.declared_seconds or 0.0)
    job.charged = True
