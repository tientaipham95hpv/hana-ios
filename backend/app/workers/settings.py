from __future__ import annotations

from arq.connections import RedisSettings
from redis.asyncio import Redis

from app.core.config import get_settings
from app.db.session import SessionFactory
from app.domain.ai.gateway import FakeChatGateway, NineRouterClient
from app.domain.conversation.orchestrator import TurnOrchestrator
from app.integrations.voice_providers import create_stt_provider, create_tts_provider
from app.services.events import TurnEventBus


async def startup(ctx):
    settings = get_settings()
    redis = Redis.from_url(settings.redis_url, decode_responses=False)
    if settings.ai_fake:
        gateway = FakeChatGateway()
    else:
        gateway = NineRouterClient(settings)
    stt = create_stt_provider(settings)
    tts = create_tts_provider(settings)
    ctx["redis"] = redis
    ctx["gateway"] = gateway
    ctx["stt"] = stt
    ctx["tts"] = tts
    ctx["orchestrator"] = TurnOrchestrator(
        settings=settings,
        sessions=SessionFactory,
        events=TurnEventBus(redis, settings.turn_stream_ttl_s),
        gateway=gateway,
        stt=stt,
        tts=tts,
    )


async def shutdown(ctx):
    if hasattr(ctx.get("gateway"), "close"):
        await ctx["gateway"].close()
    for name in ("stt", "tts"):
        provider = ctx.get(name)
        if provider is not None and hasattr(provider, "close"):
            await provider.close()
    await ctx["redis"].aclose()


async def process_turn(ctx, turn_id: str):
    await ctx["orchestrator"].process(turn_id)


class WorkerSettings:
    settings = get_settings()
    functions = [process_turn]
    on_startup = startup
    on_shutdown = shutdown
    redis_settings = RedisSettings.from_dsn(settings.redis_url)
    queue_name = settings.worker_queue_name
    max_jobs = 10
    job_timeout = 90
    # Infrastructure failures bubble to ARQ and are bounded; provider/output
    # failures are converted to durable terminal turn states by the orchestrator.
    max_tries = 3
