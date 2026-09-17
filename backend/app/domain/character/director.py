from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.core.ids import uuid7
from app.domain.ai.protocol import ChatEnvelope


class CharacterCue(BaseModel):
    model_config = ConfigDict(extra="forbid")
    cue_id: str
    source: Literal["reply", "system", "proactive"] = "reply"
    emotion: Literal["neutral", "happy", "shy", "surprised", "concerned"]
    intensity: Literal["low", "medium", "high"]
    special_cue: str | None
    stage_context: Literal["daily", "assistant", "relationship", "private"] | None
    reason: str = Field(pattern=r"^[a-z][a-z0-9_]{1,31}$")


ALLOWED_CUES = {"greeting", "playful", "goodnight", "celebrate", "comfort"}


def direct(envelope: ChatEnvelope, action_statuses: list[str] | None = None) -> CharacterCue:
    business_action = bool(action_statuses)
    special = envelope.special_cue if envelope.special_cue in ALLOWED_CUES else None
    return CharacterCue(
        cue_id=str(uuid7()),
        emotion=envelope.emotion,
        intensity=envelope.intensity,
        special_cue=special,
        stage_context="assistant" if business_action else "daily",
        reason="reply",
    )


def system_cue(reason: str) -> CharacterCue:
    return CharacterCue(
        cue_id=str(uuid7()),
        source="system",
        emotion="concerned",
        intensity="low",
        special_cue=None,
        stage_context=None,
        reason=reason,
    )
