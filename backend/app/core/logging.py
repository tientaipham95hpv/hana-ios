from __future__ import annotations

import logging
from collections.abc import Mapping
from typing import Any

import structlog

SENSITIVE_PARTS = (
    "authorization",
    "api_key",
    "password",
    "pin",
    "token",
    "audio",
    "prompt",
    "content",
    "transcript",
    "reply",
    "text",
    "private",
)


def redact(value: Any) -> Any:
    if isinstance(value, Mapping):
        return {
            key: "[REDACTED]"
            if any(part in str(key).lower() for part in SENSITIVE_PARTS)
            else redact(item)
            for key, item in value.items()
        }
    if isinstance(value, (list, tuple)):
        return [redact(item) for item in value]
    if isinstance(value, bytes):
        return "[REDACTED_BYTES]"
    return value


def _redact_processor(_: Any, __: str, event_dict: dict[str, Any]) -> dict[str, Any]:
    return redact(event_dict)


def configure_logging(level: str = "INFO") -> None:
    logging.basicConfig(level=level.upper(), format="%(message)s")
    structlog.configure(
        processors=[
            _redact_processor,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso", utc=True),
            structlog.processors.JSONRenderer(),
        ]
    )


def logger(name: str = "hana") -> structlog.stdlib.BoundLogger:
    return structlog.get_logger(name)
