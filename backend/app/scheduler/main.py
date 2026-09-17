from __future__ import annotations

import asyncio
import os
import socket
from datetime import UTC, datetime

from redis.asyncio import Redis
from sqlalchemy import select

from app.core.config import get_settings
from app.core.logging import configure_logging, logger
from app.db.models import MediaObject
from app.db.session import SessionFactory
from app.services.media import MediaStore


async def cleanup_expired_media() -> int:
    """Delete expired audio files and metadata; never logs voice content."""
    store = MediaStore(get_settings())
    async with SessionFactory() as session:
        expired = (
            await session.scalars(
                select(MediaObject).where(MediaObject.expires_at <= datetime.now(UTC)).limit(200)
            )
        ).all()
        for item in expired:
            store.delete(item.storage_key)
            await session.delete(item)
        await session.commit()
        return len(expired)


async def run() -> None:
    settings = get_settings()
    configure_logging(settings.log_level)
    log = logger("hana.scheduler")
    redis = Redis.from_url(settings.redis_url, decode_responses=True)
    owner = f"{socket.gethostname()}:{os.getpid()}"
    last_cleanup = 0.0
    try:
        while True:
            acquired = await redis.set("scheduler:leader", owner, nx=True, px=30000)
            if not acquired and await redis.get("scheduler:leader") == owner:
                await redis.pexpire("scheduler:leader", 30000)
                acquired = True
            if acquired:
                if asyncio.get_running_loop().time() - last_cleanup >= 60:
                    removed = await cleanup_expired_media()
                    last_cleanup = asyncio.get_running_loop().time()
                    if removed:
                        log.info("expired_media_cleaned", count=removed)
            await asyncio.sleep(15)
    finally:
        if await redis.get("scheduler:leader") == owner:
            await redis.delete("scheduler:leader")
        await redis.aclose()


if __name__ == "__main__":
    asyncio.run(run())
