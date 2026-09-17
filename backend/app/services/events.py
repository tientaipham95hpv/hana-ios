from __future__ import annotations

import json
import uuid
from datetime import UTC, datetime
from typing import Any

from redis.asyncio import Redis

TERMINAL_TYPES = {"turn.completed", "turn.failed", "turn.cancelled"}


class TurnEventBus:
    def __init__(self, redis: Redis, ttl_s: int = 900) -> None:
        self.redis = redis
        self.ttl_s = ttl_s

    @staticmethod
    def stream_key(turn_id: uuid.UUID | str) -> str:
        return f"ev:turn:{turn_id}"

    async def emit(self, turn_id: uuid.UUID | str, event_type: str, payload: dict[str, Any]) -> str:
        key = self.stream_key(turn_id)
        seq_key = f"seq:turn:{turn_id}"
        seq = await self.redis.incr(seq_key)
        body = {
            "turn_id": str(turn_id),
            "seq": seq,
            "ts": datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            **payload,
        }
        entry_id = await self.redis.xadd(
            key,
            {"type": event_type, "data": json.dumps(body, ensure_ascii=False)},
            maxlen=200,
            approximate=True,
        )
        if event_type in TERMINAL_TYPES:
            await self.redis.expire(key, self.ttl_s)
            await self.redis.expire(seq_key, self.ttl_s)
        return entry_id.decode() if isinstance(entry_id, bytes) else str(entry_id)

    async def cancel(self, turn_id: uuid.UUID | str) -> None:
        await self.redis.set(f"cancel:turn:{turn_id}", "1", ex=900)

    async def is_cancelled(self, turn_id: uuid.UUID | str) -> bool:
        return bool(await self.redis.exists(f"cancel:turn:{turn_id}"))
