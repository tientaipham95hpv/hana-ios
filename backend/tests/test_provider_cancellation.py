import asyncio
import uuid

import pytest

from app.db.models import Turn
from app.domain.ai.gateway import GatewayFailure, GatewayResult
from app.domain.conversation.orchestrator import TurnOrchestrator


@pytest.mark.asyncio
async def test_inflight_provider_is_cancelled_when_turn_becomes_terminal():
    orchestrator = TurnOrchestrator.__new__(TurnOrchestrator)
    active = True
    started = asyncio.Event()
    cancelled = asyncio.Event()

    async def is_active(_turn_id):
        return active

    async def provider():
        started.set()
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            cancelled.set()
            raise

    orchestrator._is_active = is_active
    pending = asyncio.create_task(orchestrator._await_provider(uuid.uuid4(), provider()))
    await started.wait()
    active = False
    assert await asyncio.wait_for(pending, timeout=2) is None
    assert cancelled.is_set()


@pytest.mark.asyncio
async def test_active_provider_result_is_delivered():
    orchestrator = TurnOrchestrator.__new__(TurnOrchestrator)

    async def is_active(_turn_id):
        return True

    async def provider():
        return "ok"

    orchestrator._is_active = is_active
    assert await orchestrator._await_provider(uuid.uuid4(), provider()) == "ok"


@pytest.mark.asyncio
async def test_retryable_primary_chat_failure_uses_relationship_fallback():
    orchestrator = TurnOrchestrator.__new__(TurnOrchestrator)
    purposes = []

    class Gateway:
        async def complete(self, **kwargs):
            purposes.append((kwargs["purpose"], kwargs["mode"]))
            if kwargs["purpose"] == "chat_turn":
                raise GatewayFailure("LLM_UNAVAILABLE", retryable=True, status=503)
            return GatewayResult(
                content='{"v":1,"reply":"Xin chào","mode":"normal","emotion":"neutral","intensity":"low","special_cue":null,"actions":[]}',
                finish_reason="stop",
                prompt_tokens=None,
                completion_tokens=None,
                latency_ms=1,
                model="xai/grok-4.5",
            )

    async def record(*_args, **_kwargs):
        return None

    orchestrator.gateway = Gateway()
    orchestrator._record_llm = record
    turn = Turn(id=uuid.uuid4(), semantic_mode="relationship")
    envelope = await orchestrator._call_llm(turn, "Chào Hana")
    assert envelope.reply == "Xin chào"
    assert purposes == [
        ("chat_turn", "relationship"),
        ("chat_fallback", "relationship"),
    ]
