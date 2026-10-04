"""
Push notifications through APNs ("your transcript is ready"), so people can lock their phone while the
server works. Optional: without APNS_* variables the app simply refreshes when it is opened.

Setup: Apple Developer -> Keys -> new key with "Apple Push Notifications service (APNs)" -> download the
.p8; set APNS_KEY_ID, APNS_TEAM_ID and APNS_PRIVATE_KEY (the .p8 content).
"""
import logging
import threading
import time

import jwt

from .config import get_settings
from .db import Install, session

log = logging.getLogger("parley.notify")

_token = {"value": None, "at": 0.0}
_lock = threading.Lock()

TEXTS = {
    "fr": {"done": "Transcription prête", "done_body": "Votre transcription et le résumé sont prêts.",
           "failed": "Transcription interrompue", "failed_body": "Ouvrez Parley pour relancer."},
    "en": {"done": "Transcript ready", "done_body": "Your transcript and summary are ready.",
           "failed": "Transcription interrupted", "failed_body": "Open Parley to try again."},
}


def _provider_token():
    s = get_settings()
    with _lock:
        if _token["value"] and time.time() - _token["at"] < 45 * 60:     # Apple: refresh 20-60 min
            return _token["value"]
        tok = jwt.encode({"iss": s.apns_team_id, "iat": int(time.time())}, s.apns_private_key, algorithm="ES256",
                         headers={"kid": s.apns_key_id})
        _token.update(value=tok, at=time.time())
        return tok


def send(install_id, title, body, data):
    s = get_settings()
    if not s.apns_enabled or not install_id:
        return False
    with session() as db:
        inst = db.get(Install, install_id)
        if not inst or not inst.apns_token:
            return False
        token, env = inst.apns_token, inst.apns_env
    host = "api.sandbox.push.apple.com" if env == "development" else "api.push.apple.com"
    payload = {"aps": {"alert": {"title": title, "body": body}, "sound": "default"}, **data}
    try:
        import httpx
        with httpx.Client(http2=True, timeout=10) as c:
            r = c.post("https://%s/3/device/%s" % (host, token), json=payload,
                       headers={"authorization": "bearer " + _provider_token(), "apns-topic": s.apns_topic,
                                "apns-push-type": "alert", "apns-priority": "10"})
        if r.status_code == 410 or (r.status_code == 400 and "BadDeviceToken" in r.text):
            with session() as db:
                inst = db.get(Install, install_id)
                if inst:
                    inst.apns_token = None
        elif r.status_code != 200:
            log.warning("APNs %s: %s", r.status_code, r.text[:200])
        return r.status_code == 200
    except Exception as e:
        log.warning("APNs send failed: %s", e)
        return False


def _texts(install_id):
    lang = "en"
    try:
        with session() as db:
            inst = db.get(Install, install_id)
            if inst and (inst.locale or "").lower().startswith("fr"):
                lang = "fr"
    except Exception:
        pass
    return TEXTS[lang]


def job_done(install_id, job_id, title):
    if not get_settings().apns_enabled:
        return
    t = _texts(install_id)
    threading.Thread(target=send, args=(install_id, t["done"], title or t["done_body"], {"job_id": job_id}),
                     daemon=True).start()


def job_failed(install_id, job_id):
    if not get_settings().apns_enabled:
        return
    t = _texts(install_id)
    threading.Thread(target=send, args=(install_id, t["failed"], t["failed_body"], {"job_id": job_id}),
                     daemon=True).start()
