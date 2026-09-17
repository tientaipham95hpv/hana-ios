from __future__ import annotations

from contextlib import asynccontextmanager
from datetime import UTC, datetime

from arq import create_pool
from arq.connections import RedisSettings
from fastapi import FastAPI, Request
from redis.asyncio import Redis

from app.api.deps import ensure_dev_owner
from app.api.health import router as health_router
from app.api.media import router as media_router
from app.api.turns import router as turns_router
from app.core.config import get_settings
from app.core.logging import configure_logging
from app.core.tz import utc_z
from app.db.session import SessionFactory
from app.domain.ai.gateway import NineRouterClient
from app.integrations.voice_providers import create_tts_provider

settings = get_settings()
configure_logging(settings.log_level)


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.settings = settings
    app.state.sessions = SessionFactory
    app.state.redis = Redis.from_url(settings.redis_url, decode_responses=False)
    app.state.queue = await create_pool(
        RedisSettings.from_dsn(settings.redis_url), default_queue_name=settings.worker_queue_name
    )
    app.state.gateway = NineRouterClient(settings)
    app.state.tts = create_tts_provider(settings)
    if settings.app_env in {"local", "test"} and settings.dev_auth_bypass:
        async with SessionFactory() as session:
            await ensure_dev_owner(session)
    yield
    await app.state.gateway.close()
    if hasattr(app.state.tts, "close"):
        await app.state.tts.close()
    await app.state.queue.close()
    await app.state.redis.aclose()


app = FastAPI(title="Hana Local API", version="0.1.0", lifespan=lifespan)
app.include_router(health_router)
app.include_router(turns_router)
app.include_router(media_router)


@app.middleware("http")
async def server_time(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Server-Time"] = utc_z(datetime.now(UTC))
    return response
