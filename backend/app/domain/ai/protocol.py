from __future__ import annotations

import json
import re
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator


class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str


class AiAction(BaseModel):
    model_config = ConfigDict(extra="ignore")
    type: str
    args: dict[str, Any]


class ChatEnvelope(BaseModel):
    model_config = ConfigDict(extra="ignore")
    v: Literal[1] = 1
    reply: str = Field(min_length=1, max_length=2000)
    mode: Literal["normal"] = "normal"
    emotion: Literal["neutral", "happy", "shy", "surprised", "concerned"]
    intensity: Literal["low", "medium", "high"] = "low"
    special_cue: str | None = None
    actions: list[AiAction] = Field(default_factory=list, max_length=5)
    assistant_state: dict[str, Any] | None = None
    memory_candidates: list[dict[str, Any]] = Field(default_factory=list, max_length=5)

    @field_validator("special_cue")
    @classmethod
    def valid_cue(cls, value: str | None) -> str | None:
        if value is not None and not re.fullmatch(r"[a-z][a-z0-9_]{1,31}", value):
            raise ValueError("invalid special cue")
        return value


class EnvelopeError(ValueError):
    pass


def extract_json(raw: str) -> dict[str, Any]:
    text = raw.lstrip("\ufeff").strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, flags=re.DOTALL | re.IGNORECASE)
    if fence:
        text = fence.group(1).strip()
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < start:
        raise EnvelopeError("JSON object not found")
    try:
        value = json.loads(text[start : end + 1])
    except json.JSONDecodeError as exc:
        raise EnvelopeError(str(exc)) from exc
    if not isinstance(value, dict):
        raise EnvelopeError("envelope must be an object")
    return value


def parse_envelope(raw: str) -> ChatEnvelope:
    try:
        return ChatEnvelope.model_validate(extract_json(raw))
    except (ValidationError, EnvelopeError) as exc:
        raise EnvelopeError(str(exc)) from exc


FALLBACKS = {
    "LLM_TIMEOUT": "Em xin lỗi, em đang bị chậm một chút. Anh nhắn lại giúp em nha.",
    "LLM_UNAVAILABLE": "Em xin lỗi, em đang bị chậm một chút. Anh nhắn lại giúp em nha.",
    "LLM_INVALID_OUTPUT": "Em bị rối một chút rồi, anh nói lại giúp em được không?",
    "STT_EMPTY": "Em chưa nghe rõ, anh nói lại giúp em nha.",
    "STT_FAILED": "Em chưa nghe được, anh thử lại hoặc nhắn chữ giúp em nha.",
}


def fallback_envelope(code: str) -> ChatEnvelope:
    return ChatEnvelope(
        reply=FALLBACKS.get(code, FALLBACKS["LLM_UNAVAILABLE"]),
        emotion="concerned",
        intensity="low",
    )


def safe_plain_text(raw: str) -> ChatEnvelope | None:
    value = raw.strip()
    if "{" not in value and 1 <= len(value) <= 2000:
        return ChatEnvelope(reply=value, emotion="neutral", intensity="low")
    return None
