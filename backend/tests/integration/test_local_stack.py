from __future__ import annotations

import asyncio
import json
import os
import uuid

import asyncpg
import httpx
import pytest
from redis import Redis

pytestmark = pytest.mark.integration

if os.getenv("RUN_HANA_STACK_TESTS") != "1":
    pytest.skip("set RUN_HANA_STACK_TESTS=1 for the local Docker stack", allow_module_level=True)

BASE = os.getenv("HANA_TEST_API", "http://127.0.0.1:18000")
POSTGRES = os.getenv(
    "HANA_TEST_POSTGRES",
    "postgresql://hana_app:hana_local@127.0.0.1:15432/hana",
)
REDIS = os.getenv("HANA_TEST_REDIS", "redis://127.0.0.1:16379/0")


def _create_text(*, speak: bool = True, client_id: str | None = None) -> dict:
    response = httpx.post(
        f"{BASE}/v1/turns",
        json={
            "client_id": client_id or str(uuid.uuid4()),
            "text": "Xin chào Hana",
            "speak": speak,
            "supersede": False,
        },
        timeout=10,
    )
    response.raise_for_status()
    assert response.status_code == 202
    return response.json()


def _events(path: str, last_id: str | None = None) -> list[dict]:
    headers = {"Last-Event-ID": last_id} if last_id else {}
    result: list[dict] = []
    with httpx.stream("GET", f"{BASE}{path}", headers=headers, timeout=20) as response:
        response.raise_for_status()
        event_id = event_type = None
        data: list[str] = []
        for line in response.iter_lines():
            if line == "":
                if event_type and data:
                    result.append(
                        {
                            "id": event_id,
                            "type": event_type,
                            "data": json.loads("\n".join(data)),
                        }
                    )
                    if event_type in {"turn.completed", "turn.failed", "turn.cancelled"}:
                        break
                event_id = event_type = None
                data = []
            elif line.startswith("id: "):
                event_id = line[4:]
            elif line.startswith("event: "):
                event_type = line[7:]
            elif line.startswith("data: "):
                data.append(line[6:])
    return result


def _all_keys(value):
    if isinstance(value, dict):
        yield from value.keys()
        for nested in value.values():
            yield from _all_keys(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from _all_keys(nested)


def test_health_checks_db_redis_without_coupling_readiness_to_router():
    response = httpx.get(f"{BASE}/readyz", timeout=10)
    response.raise_for_status()
    body = response.json()
    assert body["status"] == "ready"
    assert body["dependencies"]["db"] == "ok"
    assert body["dependencies"]["redis"] == "ok"
    assert body["dependencies"]["nine_router"] in {"fake", "ok", "degraded"}


def test_text_turn_persistence_sse_reconnect_and_semantic_boundary():
    accepted = _create_text()
    events = _events(accepted["events_url"])
    types = [event["type"] for event in events]
    assert types[0] == "turn.accepted"
    assert "reply.ready" in types
    assert "character.cue" in types
    assert "tts.segment" in types
    assert types[-1] == "turn.completed"
    assert all(event["data"]["turn_id"] == accepted["turn_id"] for event in events)
    assert [event["data"]["seq"] for event in events] == list(range(1, len(events) + 1))
    forbidden = {
        "asset_id",
        "filename",
        "path",
        "sensitivity",
        "allowed_modes",
        "weight",
        "delivery_class",
    }
    assert forbidden.isdisjoint(set(_all_keys([event["data"] for event in events])))

    replay = _events(accepted["events_url"], events[0]["id"])
    assert replay
    assert replay[0]["data"]["seq"] > events[0]["data"]["seq"]
    assert replay[-1]["type"] == "turn.completed"

    state = httpx.get(f"{BASE}/v1/turns/{accepted['turn_id']}", timeout=10).json()
    assert state["state"] == "completed"
    assert state["assistant_message"]["text"]
    segment = next(event for event in events if event["type"] == "tts.segment")
    audio = httpx.get(f"{BASE}{segment['data']['media_url']}", timeout=10)
    assert audio.status_code == 200
    assert audio.content
    assert audio.headers["cache-control"] == "private, no-store"

    async def query_db():
        connection = await asyncpg.connect(POSTGRES)
        try:
            turn = await connection.fetchrow(
                "SELECT state, completed_at FROM hana.turns WHERE id=$1",
                uuid.UUID(accepted["turn_id"]),
            )
            message_count = await connection.fetchval(
                "SELECT count(*) FROM hana.messages WHERE turn_id=$1",
                uuid.UUID(accepted["turn_id"]),
            )
            timezone = await connection.fetchval("SHOW timezone")
            return turn, message_count, timezone
        finally:
            await connection.close()

    turn, message_count, timezone = asyncio.run(query_db())
    assert turn["state"] == "completed"
    assert turn["completed_at"].utcoffset().total_seconds() == 0
    assert message_count == 2
    assert timezone == "UTC"

    redis = Redis.from_url(REDIS)
    try:
        assert redis.exists(f"ev:turn:{accepted['turn_id']}") == 1
    finally:
        redis.close()


def test_idempotent_retry_does_not_create_duplicate_turn():
    client_id = str(uuid.uuid4())
    first = _create_text(speak=False, client_id=client_id)
    _events(first["events_url"])
    second = _create_text(speak=False, client_id=client_id)
    assert second["turn_id"] == first["turn_id"]


def test_voice_fake_stt_tts_pipeline_and_audio_delivery():
    response = httpx.post(
        f"{BASE}/v1/turns/voice",
        data={
            "client_id": str(uuid.uuid4()),
            "duration_ms": "900",
            "speak": "true",
            "supersede": "false",
        },
        files={"audio": ("voice.m4a", b"fake-m4a", "audio/m4a")},
        timeout=10,
    )
    response.raise_for_status()
    events = _events(response.json()["events_url"])
    types = [event["type"] for event in events]
    assert "transcript.final" in types
    assert "reply.ready" in types
    assert "tts.segment" in types
    assert types[-1] == "turn.completed"


def test_auto_typed_text_is_silent_then_manual_speech_keeps_turn_completed():
    response = httpx.post(
        f"{BASE}/v1/turns",
        json={"client_id": str(uuid.uuid4()), "text": "Xin chào Hana"},
        timeout=10,
    )
    response.raise_for_status()
    accepted = response.json()
    events = _events(accepted["events_url"])
    types = [event["type"] for event in events]
    assert "reply.ready" in types
    assert "tts.segment" not in types
    assert types[-1] == "turn.completed"

    manual = httpx.post(f"{BASE}/v1/turns/{accepted['turn_id']}/speech", timeout=20)
    manual.raise_for_status()
    segments = manual.json()["segments"]
    assert segments
    assert all(item["media_url"].startswith("/v1/media/") for item in segments)
    assert httpx.get(f"{BASE}{segments[0]['media_url']}", timeout=10).status_code == 200
    state = httpx.get(f"{BASE}/v1/turns/{accepted['turn_id']}", timeout=10).json()
    assert state["state"] == "completed"
    assert state["assistant_message"]["text"]


def test_relationship_semantic_mode_is_persisted_without_model_id_in_api():
    response = httpx.post(
        f"{BASE}/v1/turns",
        json={
            "client_id": str(uuid.uuid4()),
            "text": "Xin chào Hana",
            "semantic_mode": "relationship",
            "response_mode": "TEXT_ONLY",
        },
        timeout=10,
    )
    response.raise_for_status()
    accepted = response.json()
    events = _events(accepted["events_url"])
    assert events[-1]["type"] == "turn.completed"
    state = httpx.get(f"{BASE}/v1/turns/{accepted['turn_id']}", timeout=10).json()
    assert state["semantic_mode"] == "relationship"
    assert state["response_mode"] == "TEXT_ONLY"
    assert "model" not in state


def test_terminal_snapshot_survives_expired_redis_stream():
    accepted = _create_text(speak=False)
    _events(accepted["events_url"])
    redis = Redis.from_url(REDIS)
    try:
        redis.delete(f"ev:turn:{accepted['turn_id']}")
    finally:
        redis.close()
    recovered = _events(accepted["events_url"])
    assert [event["type"] for event in recovered] == ["reply.ready", "turn.completed"]
