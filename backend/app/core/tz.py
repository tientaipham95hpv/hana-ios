from __future__ import annotations

from datetime import UTC, date, datetime
from zoneinfo import ZoneInfo

from .clock import Clock

BUSINESS_TZ_NAME = "Asia/Ho_Chi_Minh"
BUSINESS_TZ = ZoneInfo(BUSINESS_TZ_NAME)


def now_utc(clock: Clock) -> datetime:
    value = clock.now_utc()
    if value.tzinfo is None:
        raise ValueError("clock returned a naive datetime")
    return value.astimezone(UTC)


def to_business(instant: datetime) -> datetime:
    if instant.tzinfo is None:
        raise ValueError("instant must be timezone-aware")
    return instant.astimezone(BUSINESS_TZ)


def business_today(clock: Clock) -> date:
    return to_business(now_utc(clock)).date()


def utc_z(instant: datetime) -> str:
    if instant.tzinfo is None:
        raise ValueError("instant must be timezone-aware")
    return instant.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
