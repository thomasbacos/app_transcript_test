"""
Server settings. Everything comes from environment variables (see `.env.example`), so the same Docker
image runs locally, on Render, Railway, Fly.io or any VPS. The OpenAI key never leaves the server.
"""
import json
import logging
import os
import secrets
from dataclasses import dataclass, field
from functools import lru_cache

log = logging.getLogger("parley")


def _str(name, default=""):
    v = os.environ.get(name)
    return v.strip() if v is not None and v.strip() != "" else default


def _int(name, default):
    try:
        return int(_str(name, str(default)))
    except ValueError:
        return default


def _float(name, default):
    try:
        return float(_str(name, str(default)))
    except ValueError:
        return default


def _bool(name, default=False):
    v = _str(name, "")
    return default if v == "" else v.lower() in ("1", "true", "yes", "on")


# Plans: minutes of audio per period. The trial is the App Store free trial (7 days, configured in App
# Store Connect); its allowance is a total for the whole trial. Paid plans reset every month (yearly
# subscriptions too: the allowance is monthly). Tune with PLAN_<NAME>_MINUTES without an app update:
# the app reads these values from GET /v1/plans.
PLAN_ORDER = ["essential", "pro"]          # low -> high, used when several entitlements are active


@dataclass
class Plan:
    id: str
    minutes: int
    max_file_minutes: int


def _plans():
    defaults = {"trial": (60, 60), "essential": (240, 120), "pro": (600, 240)}
    out = {}
    for pid, (minutes, max_file) in defaults.items():
        up = pid.upper()
        out[pid] = Plan(pid, _int("PLAN_%s_MINUTES" % up, minutes), _int("PLAN_%s_MAX_FILE_MINUTES" % up, max_file))
    return out


def _product_map():
    """productId suffix -> plan. Product IDs are '<bundle id>.<suffix>' (see ios/Config/Products.storekit)."""
    m = {"essential.monthly": "essential", "pro.monthly": "pro", "pro.yearly": "pro"}
    raw = _str("PRODUCT_PLAN_MAP")
    if raw:
        try:
            m.update({str(k): str(v) for k, v in json.loads(raw).items()})
        except ValueError:
            log.warning("PRODUCT_PLAN_MAP is not valid JSON, ignored")
    return m


def _database_url(data_dir):
    url = _str("DATABASE_URL", "sqlite:///" + os.path.join(data_dir, "parley.db").replace("\\", "/"))
    # Render / Heroku hand out postgres:// URLs; SQLAlchemy wants an explicit driver.
    if url.startswith("postgres://"):
        url = "postgresql+psycopg://" + url[len("postgres://"):]
    elif url.startswith("postgresql://"):
        url = "postgresql+psycopg://" + url[len("postgresql://"):]
    return url


@dataclass
class Settings:
    openai_api_key: str = ""
    secret_key: str = ""
    data_dir: str = ""
    database_url: str = ""
    public_url: str = ""

    bundle_id: str = "com.thomasbacos.parley"
    apple_app_id: int | None = None
    apple_environments: list = field(default_factory=list)
    apple_online_checks: bool = True

    transcribe_model: str = "gpt-transcribe"
    diarize_model: str = "gpt-4o-transcribe-diarize"
    llm_model: str = "gpt-6-sol"
    llm_fallback_model: str = "gpt-6-astra"

    workers: int = 3
    diarize_parallel: int = 8
    max_upload_mb: int = 400
    max_active_jobs: int = 2
    jobs_per_day: int = 30
    result_retention_hours: int = 72
    audio_retention_hours: int = 24
    session_hours: int = 12

    plans: dict = field(default_factory=dict)
    product_map: dict = field(default_factory=dict)

    apns_key_id: str = ""
    apns_team_id: str = ""
    apns_private_key: str = ""
    apns_topic: str = ""

    operator_name: str = ""
    contact_email: str = ""
    admin_token: str = ""

    @property
    def apns_enabled(self):
        return bool(self.apns_key_id and self.apns_team_id and self.apns_private_key)


@lru_cache
def get_settings() -> Settings:
    data_dir = os.path.abspath(_str("DATA_DIR", os.path.join(os.getcwd(), "data")))
    os.makedirs(data_dir, exist_ok=True)
    secret = _str("SECRET_KEY")
    if not secret:
        secret = secrets.token_urlsafe(48)
        log.warning("SECRET_KEY is not set: using a random one (sessions will not survive a restart)")
    app_id = _str("APPLE_APP_ID")
    bundle = _str("APP_BUNDLE_ID", "com.thomasbacos.parley")
    envs = [e.strip() for e in _str("APPLE_ENVIRONMENTS", "Production,Sandbox").split(",") if e.strip()]
    return Settings(
        openai_api_key=_str("OPENAI_API_KEY"),
        secret_key=secret,
        data_dir=data_dir,
        database_url=_database_url(data_dir),
        public_url=_str("PUBLIC_URL").rstrip("/"),
        bundle_id=bundle,
        apple_app_id=int(app_id) if app_id.isdigit() else None,
        apple_environments=envs,
        apple_online_checks=_bool("APPLE_ONLINE_CHECKS", True),
        transcribe_model=_str("TRANSCRIBE_MODEL", "gpt-transcribe"),
        diarize_model=_str("DIARIZE_MODEL", "gpt-4o-transcribe-diarize"),
        llm_model=_str("LLM_MODEL", "gpt-6-sol"),
        llm_fallback_model=_str("LLM_FALLBACK_MODEL", "gpt-6-astra"),
        workers=max(1, _int("WORKERS", 3)),
        diarize_parallel=max(1, _int("DIARIZE_PARALLEL", 8)),
        max_upload_mb=_int("MAX_UPLOAD_MB", 400),
        max_active_jobs=_int("MAX_ACTIVE_JOBS", 2),
        jobs_per_day=_int("JOBS_PER_DAY", 30),
        result_retention_hours=_int("RESULT_RETENTION_HOURS", 72),
        audio_retention_hours=_int("AUDIO_RETENTION_HOURS", 24),
        session_hours=_int("SESSION_HOURS", 12),
        plans=_plans(),
        product_map=_product_map(),
        apns_key_id=_str("APNS_KEY_ID"),
        apns_team_id=_str("APNS_TEAM_ID"),
        apns_private_key=_str("APNS_PRIVATE_KEY").replace("\\n", "\n"),
        apns_topic=_str("APNS_TOPIC", bundle),
        operator_name=_str("OPERATOR_NAME", "Parley"),
        contact_email=_str("CONTACT_EMAIL", "support@example.com"),
        admin_token=_str("ADMIN_TOKEN"),
    )


def reset_settings():
    """Tests change the environment, then call this."""
    get_settings.cache_clear()
