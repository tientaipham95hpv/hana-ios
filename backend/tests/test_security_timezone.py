from datetime import UTC, datetime

import pytest

from app.core.clock import FakeClock
from app.core.config import Settings
from app.core.logging import redact
from app.core.tz import BUSINESS_TZ_NAME, business_today, to_business, utc_z


def test_log_redaction_is_recursive():
    value = redact(
        {
            "Authorization": "Bearer secret",
            "nested": {"api_key": "secret", "count": 2},
            "audio": b"raw",
        }
    )
    assert value["Authorization"] == "[REDACTED]"
    assert value["nested"]["api_key"] == "[REDACTED]"
    assert value["nested"]["count"] == 2
    assert value["audio"] == "[REDACTED]"


def test_prompt_logging_rejected_outside_local():
    with pytest.raises(ValueError):
        Settings(app_env="production", dev_auth_bypass=False, llm_prompt_logging=True)


def test_dev_auth_bypass_rejected_outside_local():
    with pytest.raises(ValueError):
        Settings(app_env="staging", dev_auth_bypass=True)


def test_fake_ai_rejected_outside_local():
    with pytest.raises(ValueError):
        Settings(app_env="production", dev_auth_bypass=False, ai_fake=True)


def test_timezone_boundary_uses_zoneinfo_not_fixed_offset():
    before = FakeClock(datetime(2026, 9, 14, 16, 59, 59, tzinfo=UTC))
    after = FakeClock(datetime(2026, 9, 14, 17, 0, 0, tzinfo=UTC))
    assert BUSINESS_TZ_NAME == "Asia/Ho_Chi_Minh"
    assert str(business_today(before)) == "2026-09-14"
    assert str(business_today(after)) == "2026-09-15"


def test_utc_output_has_z_and_milliseconds():
    assert utc_z(datetime(2026, 1, 1, tzinfo=UTC)) == "2026-01-01T00:00:00.000Z"


def test_naive_datetime_is_rejected():
    with pytest.raises(ValueError):
        to_business(datetime(2026, 1, 1))
