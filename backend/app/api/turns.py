from __future__ import annotations

import json
import uuid
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path

from arq.connections import ArqRedis
from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, Request, UploadFile
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, Field
from redis.asyncio import Redis
from sqlalchemy import desc, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import Principal, require_user
from app.core.config import Settings, get_settings
from app.core.ids import uuid7
from app.db.models import Conversation, MediaObject, Message, Turn
from app.db.session import get_session
from app.domain.conversation.orchestrator import TERMINAL, message_json
from app.domain.voice.providers import TextToSpeechProvider
from app.domain.voice.speech import normalize_speech, segment_speech
from app.services.events import TERMINAL_TYPES, TurnEventBus
from app.services.media import MediaStore

router = APIRouter(prefix="/v1", tags=["turns"])


class ResponseMode(StrEnum):
    AUTO = "AUTO"
    TEXT_ONLY = "TEXT_ONLY"
    VOICE_REPLY = "VOICE_REPLY"


class SemanticMode(StrEnum):
    DAILY = "daily"
    ASSISTANT = "assistant"
    WORK = "work"
    RELATIONSHIP = "relationship"
    PRIVATE = "private"


class TurnCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    client_id: uuid.UUID
    text: str = Field(min_length=1, max_length=4000)
    response_mode: ResponseMode = ResponseMode.AUTO
    auto_play_voice: bool = True
    semantic_mode: SemanticMode = SemanticMode.DAILY
    speak: bool | None = None
    supersede: bool = False


def _should_speak(
    *,
    input_kind: str,
    response_mode: ResponseMode,
    auto_play_voice: bool,
    legacy_speak: bool | None,
) -> bool:
    if legacy_speak is not None:
        return legacy_speak
    if not auto_play_voice or response_mode == ResponseMode.TEXT_ONLY:
        return False
    return response_mode == ResponseMode.VOICE_REPLY or input_kind == "voice"


def _validate_semantic_mode(mode: SemanticMode) -> None:
    if mode == SemanticMode.PRIVATE:
        raise HTTPException(
            status_code=403,
            detail={
                "error": {
                    "code": "PRIVATE_MODE_DISABLED",
                    "message": "Private AI is disabled until the production security phase",
                    "retryable": False,
                    "details": {},
                }
            },
        )


async def _conversation(session: AsyncSession, user_id: uuid.UUID) -> Conversation:
    value = await session.scalar(
        select(Conversation)
        .where(Conversation.user_id == user_id)
        .order_by(desc(Conversation.updated_at))
        .limit(1)
    )
    if value:
        return value
    value = Conversation(id=uuid7(), user_id=user_id, title="Hana")
    session.add(value)
    await session.flush()
    return value


async def _rate_limit(redis: Redis, principal: Principal, settings: Settings) -> None:
    bucket = int(datetime.now(UTC).timestamp() // 60)
    key = f"rl:turn:{principal.user_id}:{bucket}"
    count = await redis.incr(key)
    if count == 1:
        await redis.expire(key, 65)
    if count > settings.rate_limit_turns_per_minute:
        raise HTTPException(
            status_code=429,
            detail={
                "error": {
                    "code": "RATE_LIMITED",
                    "message": "Qua nhieu yeu cau",
                    "retryable": True,
                    "details": {},
                }
            },
            headers={"Retry-After": "60"},
        )


async def _active_turn(session: AsyncSession, user_id: uuid.UUID) -> Turn | None:
    return await session.scalar(
        select(Turn)
        .where(Turn.user_id == user_id, Turn.state.not_in(TERMINAL))
        .order_by(desc(Turn.created_at))
        .limit(1)
    )


async def _supersede(
    active: Turn, new_id: uuid.UUID, bus: TurnEventBus, session: AsyncSession
) -> None:
    active.state = "cancelled"
    active.superseded_by_turn_id = new_id
    active.completed_at = datetime.now(UTC)
    await bus.cancel(active.id)
    await bus.emit(active.id, "turn.cancelled", {"superseded": True})


async def _enqueue(request: Request, turn: Turn) -> None:
    queue: ArqRedis = request.app.state.queue
    await queue.enqueue_job("process_turn", str(turn.id), _job_id=f"turn:{turn.id}")


def _accepted(turn: Turn, message: Message | None = None) -> dict:
    result = {"turn_id": str(turn.id), "events_url": f"/v1/turns/{turn.id}/events"}
    if message:
        result["user_message"] = message_json(message)
    return result


@router.post("/turns", status_code=202)
async def create_text_turn(
    body: TurnCreate,
    request: Request,
    principal: Principal = Depends(require_user),
    settings: Settings = Depends(get_settings),
    session: AsyncSession = Depends(get_session),
):
    _validate_semantic_mode(body.semantic_mode)
    redis: Redis = request.app.state.redis
    await _rate_limit(redis, principal, settings)
    duplicate = await session.scalar(
        select(Turn).where(Turn.user_id == principal.user_id, Turn.client_id == body.client_id)
    )
    if duplicate:
        message = (
            await session.get(Message, duplicate.user_message_id)
            if duplicate.user_message_id
            else None
        )
        return _accepted(duplicate, message)
    new_id = uuid7()
    active = await _active_turn(session, principal.user_id)
    bus = TurnEventBus(redis, settings.turn_stream_ttl_s)
    if active and not body.supersede:
        raise HTTPException(
            status_code=409,
            detail={
                "error": {
                    "code": "TURN_IN_PROGRESS",
                    "message": "Dang co luot xu ly",
                    "retryable": True,
                    "details": {"turn_id": str(active.id)},
                }
            },
        )
    conversation = await _conversation(session, principal.user_id)
    speak = _should_speak(
        input_kind="text",
        response_mode=body.response_mode,
        auto_play_voice=body.auto_play_voice,
        legacy_speak=body.speak,
    )
    turn = Turn(
        id=new_id,
        user_id=principal.user_id,
        conversation_id=conversation.id,
        client_id=body.client_id,
        input_kind="text",
        state="queued",
        speak=speak,
        response_mode=body.response_mode.value,
        semantic_mode=body.semantic_mode.value,
    )
    message = Message(
        id=uuid7(),
        user_id=principal.user_id,
        conversation_id=conversation.id,
        turn_id=new_id,
        role="user",
        origin="chat",
        text=body.text.strip(),
        receipts=[],
    )
    turn.user_message_id = message.id
    if active:
        await _supersede(active, new_id, bus, session)
    session.add_all([turn, message])
    await session.commit()
    await bus.emit(turn.id, "turn.accepted", {"state": "queued"})
    await _enqueue(request, turn)
    return _accepted(turn, message)


@router.post("/turns/voice", status_code=202)
async def create_voice_turn(
    request: Request,
    client_id: uuid.UUID = Form(...),
    duration_ms: int = Form(..., ge=400, le=62000),
    response_mode: ResponseMode = Form(ResponseMode.AUTO),
    auto_play_voice: bool = Form(True),
    semantic_mode: SemanticMode = Form(SemanticMode.DAILY),
    speak: bool | None = Form(None),
    supersede: bool = Form(False),
    audio: UploadFile = File(...),
    principal: Principal = Depends(require_user),
    settings: Settings = Depends(get_settings),
    session: AsyncSession = Depends(get_session),
):
    _validate_semantic_mode(semantic_mode)
    allowed = {"audio/mp4", "audio/m4a", "audio/aac", "audio/ogg", "application/octet-stream"}
    if audio.content_type not in allowed:
        raise HTTPException(
            status_code=422,
            detail={
                "error": {
                    "code": "AUDIO_INVALID",
                    "message": "Dinh dang audio khong hop le",
                    "retryable": False,
                    "details": {},
                }
            },
        )
    data = await audio.read(2 * 1024 * 1024 + 1)
    if not data or len(data) > 2 * 1024 * 1024:
        raise HTTPException(
            status_code=422,
            detail={
                "error": {
                    "code": "AUDIO_INVALID",
                    "message": "Audio rong hoac qua lon",
                    "retryable": False,
                    "details": {},
                }
            },
        )
    duplicate = await session.scalar(
        select(Turn).where(Turn.user_id == principal.user_id, Turn.client_id == client_id)
    )
    if duplicate:
        return _accepted(duplicate)
    redis: Redis = request.app.state.redis
    await _rate_limit(redis, principal, settings)
    new_id, media_id = uuid7(), uuid7()
    active = await _active_turn(session, principal.user_id)
    bus = TurnEventBus(redis, settings.turn_stream_ttl_s)
    if active and not supersede:
        raise HTTPException(
            status_code=409,
            detail={
                "error": {
                    "code": "TURN_IN_PROGRESS",
                    "message": "Dang co luot xu ly",
                    "retryable": True,
                    "details": {},
                }
            },
        )
    store = MediaStore(settings)
    suffix = Path(audio.filename or "voice.m4a").suffix.lower()
    stored = store.write(
        media_id=media_id, kind="voice", data=data, suffix=suffix, ttl_s=settings.voice_upload_ttl_s
    )
    conversation = await _conversation(session, principal.user_id)
    media = MediaObject(
        id=media_id,
        user_id=principal.user_id,
        kind="voice_input",
        storage_key=stored.key,
        mime=audio.content_type or "audio/mp4",
        bytes=stored.bytes,
        duration_ms=duration_ms,
        sha256=stored.sha256,
        cache_key=None,
        expires_at=stored.expires_at,
    )
    resolved_speak = _should_speak(
        input_kind="voice",
        response_mode=response_mode,
        auto_play_voice=auto_play_voice,
        legacy_speak=speak,
    )
    turn = Turn(
        id=new_id,
        user_id=principal.user_id,
        conversation_id=conversation.id,
        client_id=client_id,
        input_kind="voice",
        state="queued",
        speak=resolved_speak,
        response_mode=response_mode.value,
        semantic_mode=semantic_mode.value,
        input_media_id=media_id,
    )
    if active:
        await _supersede(active, new_id, bus, session)
    session.add_all([media, turn])
    await session.commit()
    await bus.emit(turn.id, "turn.accepted", {"state": "queued"})
    await _enqueue(request, turn)
    return _accepted(turn)


@router.post("/turns/{turn_id}/cancel", status_code=202)
async def cancel_turn(
    turn_id: uuid.UUID,
    request: Request,
    principal: Principal = Depends(require_user),
    session: AsyncSession = Depends(get_session),
):
    turn = await session.scalar(
        select(Turn).where(Turn.id == turn_id, Turn.user_id == principal.user_id).with_for_update()
    )
    if turn is None:
        raise HTTPException(
            status_code=404,
            detail={
                "error": {
                    "code": "TURN_NOT_FOUND",
                    "message": "Khong tim thay luot",
                    "retryable": False,
                    "details": {},
                }
            },
        )
    if turn.state not in TERMINAL:
        turn.state = "cancelled"
        turn.completed_at = datetime.now(UTC)
        await session.commit()
        bus = TurnEventBus(request.app.state.redis, request.app.state.settings.turn_stream_ttl_s)
        await bus.cancel(turn.id)
        await bus.emit(turn.id, "turn.cancelled", {})
    return {"turn_id": str(turn.id), "state": turn.state}


@router.post("/turns/{turn_id}/speech")
async def synthesize_turn_reply(
    turn_id: uuid.UUID,
    request: Request,
    principal: Principal = Depends(require_user),
    settings: Settings = Depends(get_settings),
    session: AsyncSession = Depends(get_session),
):
    """Generate disposable speech for an already-visible assistant reply.

    This endpoint powers the per-message speaker button. A provider failure is
    deliberately non-terminal: the persisted text turn is never rolled back.
    """
    turn = await session.scalar(
        select(Turn).where(Turn.id == turn_id, Turn.user_id == principal.user_id)
    )
    if turn is None or not turn.assistant_message_id:
        raise HTTPException(
            status_code=404,
            detail={
                "error": {
                    "code": "REPLY_NOT_FOUND",
                    "message": "Reply not found",
                    "retryable": False,
                    "details": {},
                }
            },
        )
    message = await session.get(Message, turn.assistant_message_id)
    if message is None:
        raise HTTPException(status_code=404, detail="Reply not found")
    speech = normalize_speech(message.text)
    if len(speech) > 1200:
        speech = speech[:1000].rsplit(" ", 1)[0] + "."
    provider: TextToSpeechProvider = request.app.state.tts
    output: list[dict] = []
    segments = segment_speech(speech)
    try:
        for segment in segments:
            result = await provider.synthesize(
                text=segment.text,
                voice=settings.tts_voice,
                speed=1.0,
                style=None,
                timeout_s=15,
            )
            media_id = uuid7()
            suffix = ".wav" if result.mime == "audio/wav" else ".mp3"
            stored = MediaStore(settings).write(
                media_id=media_id,
                kind="tts",
                data=result.audio_bytes,
                suffix=suffix,
                ttl_s=settings.tts_ttl_s,
            )
            session.add(
                MediaObject(
                    id=media_id,
                    user_id=turn.user_id,
                    kind="tts_audio",
                    storage_key=stored.key,
                    mime=result.mime,
                    bytes=stored.bytes,
                    duration_ms=result.duration_ms,
                    sha256=stored.sha256,
                    cache_key=None,
                    expires_at=stored.expires_at,
                )
            )
            output.append(
                {
                    "index": segment.index,
                    "media_id": str(media_id),
                    "media_url": f"/v1/media/{media_id}",
                    "mime": result.mime,
                    "duration_ms": result.duration_ms,
                    "is_last": segment.index == len(segments) - 1,
                    "tts_latency_ms": result.latency_ms,
                }
            )
        await session.commit()
        MediaStore(settings).prune("tts", settings.tts_cache_max_bytes)
    except Exception as exc:
        await session.rollback()
        raise HTTPException(
            status_code=503,
            detail={
                "error": {
                    "code": "TTS_FAILED",
                    "message": "Voice playback is temporarily unavailable",
                    "retryable": True,
                    "details": {},
                }
            },
        ) from exc
    return {"turn_id": str(turn.id), "segments": output}


async def _turn_payload(session: AsyncSession, turn: Turn) -> dict:
    user = await session.get(Message, turn.user_message_id) if turn.user_message_id else None
    assistant = (
        await session.get(Message, turn.assistant_message_id) if turn.assistant_message_id else None
    )
    return {
        "turn_id": str(turn.id),
        "state": turn.state,
        "error": turn.error_code,
        "response_mode": turn.response_mode,
        "semantic_mode": turn.semantic_mode,
        "user_message": message_json(user) if user else None,
        "assistant_message": message_json(assistant) if assistant else None,
        "character_cue": assistant.character_cue if assistant else None,
        "tts_segments": [],
    }


@router.get("/turns/{turn_id}")
async def get_turn(
    turn_id: uuid.UUID,
    principal: Principal = Depends(require_user),
    session: AsyncSession = Depends(get_session),
):
    turn = await session.scalar(
        select(Turn).where(Turn.id == turn_id, Turn.user_id == principal.user_id)
    )
    if turn is None:
        raise HTTPException(
            status_code=404,
            detail={
                "error": {
                    "code": "TURN_NOT_FOUND",
                    "message": "Khong tim thay luot",
                    "retryable": False,
                    "details": {},
                }
            },
        )
    return await _turn_payload(session, turn)


@router.get("/turns/{turn_id}/events")
async def turn_events(
    turn_id: uuid.UUID,
    request: Request,
    last_event_id: str | None = Header(default=None, alias="Last-Event-ID"),
    principal: Principal = Depends(require_user),
    session: AsyncSession = Depends(get_session),
):
    turn = await session.scalar(
        select(Turn).where(Turn.id == turn_id, Turn.user_id == principal.user_id)
    )
    if turn is None:
        raise HTTPException(
            status_code=404,
            detail={
                "error": {
                    "code": "TURN_NOT_FOUND",
                    "message": "Khong tim thay luot",
                    "retryable": False,
                    "details": {},
                }
            },
        )
    redis: Redis = request.app.state.redis
    key = TurnEventBus.stream_key(turn_id)

    async def stream():
        cursor = last_event_id or "0-0"
        empty = 0
        if not await redis.exists(key) and turn.state in TERMINAL:
            payload = await _turn_payload(session, turn)
            seq = 1
            if payload["assistant_message"]:
                data = {
                    "turn_id": str(turn_id),
                    "seq": seq,
                    "ts": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
                    "assistant_message": payload["assistant_message"],
                }
                yield f"id: snapshot-{seq}\nevent: reply.ready\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"
                seq += 1
            data = {
                "turn_id": str(turn_id),
                "seq": seq,
                "ts": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
                "state": turn.state,
                "code": turn.error_code,
            }
            yield f"id: snapshot-{seq}\nevent: turn.{turn.state}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"
            return
        while not await request.is_disconnected():
            rows = await redis.xread({key: cursor}, count=50, block=1000)
            if not rows:
                empty += 1
                if empty % 15 == 0:
                    yield ": keepalive\n\n"
                continue
            empty = 0
            for _, entries in rows:
                for entry_id, fields in entries:
                    cursor = entry_id.decode() if isinstance(entry_id, bytes) else str(entry_id)
                    event_type = fields.get(b"type", fields.get("type"))
                    raw_data = fields.get(b"data", fields.get("data"))
                    event_type = (
                        event_type.decode() if isinstance(event_type, bytes) else event_type
                    )
                    raw_data = raw_data.decode() if isinstance(raw_data, bytes) else raw_data
                    yield f"id: {cursor}\nevent: {event_type}\ndata: {raw_data}\n\n"
                    if event_type in TERMINAL_TYPES:
                        return

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
