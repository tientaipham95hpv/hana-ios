from __future__ import annotations

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from sqlalchemy import text

router = APIRouter(tags=["health"])


@router.get("/healthz")
@router.get("/health")
async def healthz():
    return {"status": "ok", "service": "hana-api"}


@router.get("/readyz")
@router.get("/status")
async def readyz(request: Request):
    state = {"api": "ok", "db": "down", "redis": "down", "nine_router": "unknown"}
    try:
        async with request.app.state.sessions() as session:
            timezone = await session.scalar(text("SHOW timezone"))
            await session.execute(text("SELECT 1"))
            state["db"] = "ok" if str(timezone).upper() == "UTC" else f"invalid_timezone:{timezone}"
    except Exception:
        pass
    try:
        state["redis"] = "ok" if await request.app.state.redis.ping() else "down"
    except Exception:
        pass
    if request.app.state.settings.ai_fake:
        state["nine_router"] = "fake"
    else:
        state["nine_router"] = "ok" if await request.app.state.gateway.health() else "degraded"
    ready = state["db"] == "ok" and state["redis"] == "ok"
    return JSONResponse(
        {"status": "ready" if ready else "not_ready", "dependencies": state},
        status_code=200 if ready else 503,
    )
