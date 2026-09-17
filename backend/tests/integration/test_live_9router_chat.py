"""Opt-in live GPT/Grok verification; never runs in normal CI."""

import os

import pytest

from app.core.config import Settings
from app.domain.ai.gateway import GatewayFailure, NineRouterClient
from app.domain.ai.protocol import ChatMessage, parse_envelope
from app.domain.conversation.orchestrator import CHAT_ENVELOPE_FORMAT

if os.getenv("RUN_HANA_LIVE_9ROUTER") != "1":
    pytest.skip(
        "set RUN_HANA_LIVE_9ROUTER=1 for paid live 9Router checks",
        allow_module_level=True,
    )


@pytest.mark.asyncio
@pytest.mark.live_9router
@pytest.mark.parametrize(
    ("mode", "purpose", "expected_model"),
    [
        ("normal", "chat_turn", "cx/gpt-5.6-terra"),
        ("relationship", "chat_turn", "xai/grok-4.6"),
        ("relationship", "chat_fallback", "xai/grok-4.5"),
    ],
)
async def test_live_chat_returns_safe_validated_envelope(
    mode: str, purpose: str, expected_model: str
):
    settings = Settings(
        ai_fake=False,
        model_alias_hana_chat="cx/gpt-5.6-terra",
        model_alias_hana_relationship="xai/grok-4.6",
    )
    assert settings.nine_router_api_key, "NINE_ROUTER_API_KEY is required"
    client = NineRouterClient(settings)
    try:
        try:
            result = await client.complete(
                purpose=purpose,
                mode=mode,
                messages=[
                    ChatMessage(
                        role="system",
                        content=CHAT_ENVELOPE_FORMAT,
                    ),
                    ChatMessage(role="user", content="Chào Hana, trả lời một câu ngắn nhé."),
                ],
                temperature=0,
                max_tokens=250,
                json_mode=True,
                timeout_s=45,
            )
        except GatewayFailure as exc:
            pytest.fail(
                f"{mode}/{purpose} live gateway failure code={exc.code} status={exc.status}",
                pytrace=False,
            )
    finally:
        await client.close()

    envelope = parse_envelope(result.content)
    assert envelope.reply
    assert result.model in {expected_model, expected_model.split("/", 1)[-1]}
    forbidden = ("asset_id", "content_sensitivity", "allowed_modes", "filename", "path")
    assert not any(token in result.content.lower() for token in forbidden)
