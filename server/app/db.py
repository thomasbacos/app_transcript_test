"""Database: SQLite locally, Postgres in production (DATABASE_URL). Tables are created on start-up."""
import contextlib
import datetime as dt

from sqlalchemy import Boolean, DateTime, Float, Integer, String, Text, create_engine, event
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker


def utcnow():
    return dt.datetime.now(dt.timezone.utc)


def aware(d):
    """SQLite hands datetimes back without a timezone; everything here is UTC."""
    if d is None:
        return None
    return d if d.tzinfo else d.replace(tzinfo=dt.timezone.utc)


class Base(DeclarativeBase):
    pass


class Account(Base):
    """One per App Store subscription ("ot:<originalTransactionId>"), or one per install for people who
    have not subscribed yet ("inst:<install id>", plan "none": they can look around but not transcribe)."""
    __tablename__ = "accounts"
    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    plan: Mapped[str] = mapped_column(String(20), default="none")
    product_id: Mapped[str | None] = mapped_column(String(200), nullable=True)
    is_trial: Mapped[bool] = mapped_column(Boolean, default=False)
    period_key: Mapped[str | None] = mapped_column(String(160), nullable=True)
    period_end: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    expires_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # current transaction: monthly allowance windows are anchored on its purchase date
    transaction_id: Mapped[str | None] = mapped_column(String(80), nullable=True)
    purchase_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    environment: Mapped[str | None] = mapped_column(String(20), nullable=True)
    revoked: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class Install(Base):
    __tablename__ = "installs"
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    account_id: Mapped[str | None] = mapped_column(String(80), nullable=True, index=True)
    apns_token: Mapped[str | None] = mapped_column(String(200), nullable=True)
    apns_env: Mapped[str | None] = mapped_column(String(20), nullable=True)
    locale: Mapped[str | None] = mapped_column(String(20), nullable=True)
    app_version: Mapped[str | None] = mapped_column(String(40), nullable=True)
    updated_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class Usage(Base):
    """Seconds of audio transcribed per account and allowance period. Kept after account deletion (it is
    an anonymous counter) so deleting data cannot be used to reset an allowance."""
    __tablename__ = "usage"
    account_id: Mapped[str] = mapped_column(String(80), primary_key=True)
    period_key: Mapped[str] = mapped_column(String(160), primary_key=True)
    seconds: Mapped[float] = mapped_column(Float, default=0.0)
    updated_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class Job(Base):
    __tablename__ = "jobs"
    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    account_id: Mapped[str] = mapped_column(String(80), index=True)
    install_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # awaiting_audio -> queued -> processing -> done | failed ; cancelled
    status: Mapped[str] = mapped_column(String(20), default="awaiting_audio", index=True)
    stage: Mapped[str | None] = mapped_column(String(20), nullable=True)
    progress: Mapped[float] = mapped_column(Float, default=0.0)
    error_code: Mapped[str | None] = mapped_column(String(40), nullable=True)
    error_message: Mapped[str | None] = mapped_column(Text, nullable=True)
    retryable: Mapped[bool] = mapped_column(Boolean, default=False)
    declared_seconds: Mapped[float] = mapped_column(Float, default=0.0)
    duration_seconds: Mapped[float | None] = mapped_column(Float, nullable=True)
    period_key: Mapped[str | None] = mapped_column(String(160), nullable=True)
    charged: Mapped[bool] = mapped_column(Boolean, default=False)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    options_json: Mapped[str] = mapped_column(Text, default="{}")
    result_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    title: Mapped[str | None] = mapped_column(String(300), nullable=True)
    audio_ext: Mapped[str | None] = mapped_column(String(10), nullable=True)
    created_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
    updated_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
    finished_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


ACTIVE = ("awaiting_audio", "queued", "processing")

_engine = None
_Session = None


def init_db(url):
    global _engine, _Session
    kw = {"pool_pre_ping": True}
    if url.startswith("sqlite"):
        kw["connect_args"] = {"check_same_thread": False, "timeout": 30}
    _engine = create_engine(url, **kw)
    if url.startswith("sqlite"):
        @event.listens_for(_engine, "connect")
        def _wal(conn, _):                      # concurrent readers while a worker writes progress
            cur = conn.cursor()
            cur.execute("PRAGMA journal_mode=WAL")
            cur.close()
    Base.metadata.create_all(_engine)
    _Session = sessionmaker(_engine, expire_on_commit=False)
    return _engine


@contextlib.contextmanager
def session():
    s = _Session()
    try:
        yield s
        s.commit()
    except Exception:
        s.rollback()
        raise
    finally:
        s.close()
