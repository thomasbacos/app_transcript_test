"""
App Store subscriptions, verified on the server.

The app sends the signed transactions StoreKit 2 gives it (Transaction.currentEntitlements, JWS strings).
They are verified here with Apple's official library against Apple's root certificates, so a modified
app cannot fake a subscription. No user account is needed: the subscription's originalTransactionId is
the account (same Apple ID on several devices = same allowance).

Free trial = the App Store introductory offer (7 days, configured in App Store Connect). Apple grants it
once per Apple ID, which is what stops trial farming; the server caps it at PLAN_TRIAL_MINUTES.
"""
import calendar
import datetime as dt
import glob
import logging
import os
from dataclasses import dataclass

import jwt
from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier, VerificationException

from .config import PLAN_ORDER, get_settings

log = logging.getLogger("parley.appstore")

CERT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "certs")
GRACE = dt.timedelta(hours=1)   # renewal not yet synced to the device


class InvalidTransaction(Exception):
    pass


@dataclass
class Entitlement:
    plan: str
    product_id: str
    is_trial: bool
    original_transaction_id: str
    transaction_id: str
    purchase: dt.datetime
    expires: dt.datetime | None
    environment: str

    @property
    def account_id(self):
        return "ot:" + self.original_transaction_id


_verifiers = {}


def _root_certs():
    return [open(p, "rb").read() for p in sorted(glob.glob(os.path.join(CERT_DIR, "*.cer")))]


def _verifier(env_name):
    s = get_settings()
    if env_name not in s.apple_environments:
        raise InvalidTransaction("environment %s not accepted by this server" % env_name)
    if env_name not in _verifiers:
        env = Environment(env_name)
        if env == Environment.PRODUCTION and s.apple_app_id is None:
            raise InvalidTransaction("APPLE_APP_ID is not set: production purchases cannot be verified")
        _verifiers[env_name] = SignedDataVerifier(_root_certs(), s.apple_online_checks, env, s.bundle_id,
                                                  s.apple_app_id if env == Environment.PRODUCTION else None)
    return _verifiers[env_name]


def reset():
    _verifiers.clear()


def _env_of(jws):
    try:
        return str(jwt.decode(jws, options={"verify_signature": False}).get("environment") or "")
    except jwt.PyJWTError as e:
        raise InvalidTransaction("not a JWS") from e


def verify_transaction(jws):
    """-> verified JWSTransactionDecodedPayload. The environment is read first (unverified) only to pick
    the matching verifier; the verifier then checks signature, chain, bundle id and environment."""
    env = _env_of(jws)
    try:
        return _verifier(env).verify_and_decode_signed_transaction(jws)
    except VerificationException as e:
        raise InvalidTransaction("verification failed: %s" % e) from e


def verify_notification(signed_payload):
    env = None
    try:
        claims = jwt.decode(signed_payload, options={"verify_signature": False})
        env = (claims.get("data") or claims.get("summary") or {}).get("environment")
    except jwt.PyJWTError as e:
        raise InvalidTransaction("not a JWS") from e
    try:
        return _verifier(str(env or "")).verify_and_decode_notification(signed_payload)
    except VerificationException as e:
        raise InvalidTransaction("verification failed: %s" % e) from e


def plan_for_product(product_id):
    pm = get_settings().product_map
    for suffix, plan in pm.items():
        if product_id == suffix or product_id.endswith("." + suffix):
            return plan
    return None


def _ms(v):
    return dt.datetime.fromtimestamp(v / 1000, tz=dt.timezone.utc) if v else None


def entitlement_from(payload, now=None):
    """Verified transaction -> Entitlement, or None if it does not (or no longer) grant access."""
    now = now or dt.datetime.now(dt.timezone.utc)
    if payload.revocationDate:
        return None
    plan = plan_for_product(payload.productId or "")
    if not plan:
        return None
    expires = _ms(payload.expiresDate)
    if expires and expires + GRACE < now:
        return None
    is_trial = payload.rawOfferType == 1 and (payload.rawOfferDiscountType in (None, "FREE_TRIAL"))
    return Entitlement(plan=plan, product_id=payload.productId, is_trial=bool(is_trial),
                       original_transaction_id=str(payload.originalTransactionId),
                       transaction_id=str(payload.transactionId),
                       purchase=_ms(payload.purchaseDate) or now, expires=expires,
                       environment=payload.rawEnvironment or "")


def best(entitlements):
    """Several active entitlements (rare: upgrade in progress) -> the highest plan, latest expiry."""
    ents = [e for e in entitlements if e]
    if not ents:
        return None
    return max(ents, key=lambda e: (PLAN_ORDER.index(e.plan) if e.plan in PLAN_ORDER else -1,
                                    e.expires or dt.datetime.max.replace(tzinfo=dt.timezone.utc)))


def add_months(d, n):
    m = d.month - 1 + n
    y, m = d.year + m // 12, m % 12 + 1
    return d.replace(year=y, month=m, day=min(d.day, calendar.monthrange(y, m)[1]))


def period_of(ent, now=None):
    """Allowance period for this entitlement -> (period_key, period_end).
    Trial: one allowance for the whole trial. Paid: monthly windows anchored on the purchase date of the
    current transaction (a monthly renewal is a new transaction; a yearly one is cut into 12 windows)."""
    now = now or dt.datetime.now(dt.timezone.utc)
    if ent.is_trial:
        return "trial:" + ent.original_transaction_id, ent.expires
    start = ent.purchase
    idx = max(0, (now.year - start.year) * 12 + (now.month - start.month))
    while idx > 0 and add_months(start, idx) > now:
        idx -= 1
    end = add_months(start, idx + 1)
    if ent.expires and ent.expires < end:
        end = ent.expires
    return "%s:%d" % (ent.transaction_id, idx), end
