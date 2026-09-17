import json

import httpx
import pytest

from app.core.config import Settings
from app.domain.ai.gateway import FakeChatGateway, GatewayFailure, NineRouterClient
from app.domain.ai.protocol import ChatMessage


def settings():
    return Settings(
        app_env="test",
        dev_auth_bypass=True,
        ai_fake=False,
        nine_router_base_url="http://router/v1",
        model_alias_hana_chat="chat-model",
    )


async def call(client):
    return await client.complete(
        purpose="chat_turn",
        mode="normal",
        messages=[ChatMessage(role="system", content="s"), ChatMessage(role="user", content="u")],
        temperature=0,
        max_tokens=10,
        json_mode=True,
        timeout_s=1,
    )


@pytest.mark.asyncio
async def test_gateway_success_and_model_metadata():
    transport = httpx.MockTransport(
        lambda request: httpx.Response(
            200,
            json={
                "model": "actual",
                "choices": [{"message": {"content": "{}"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 2, "completion_tokens": 1},
            },
        )
    )
    client = NineRouterClient(
        settings(), httpx.AsyncClient(transport=transport, base_url="http://router/v1")
    )
    result = await call(client)
    assert result.model == "actual"
    assert result.prompt_tokens == 2


@pytest.mark.asyncio
async def test_relationship_mode_routes_only_by_server_alias():
    seen = {}

    def handler(request):
        seen.update(json.loads(request.content))
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": "{}"}, "finish_reason": "stop"}]},
        )

    configured = Settings(
        app_env="test",
        ai_fake=False,
        nine_router_base_url="http://router/v1",
        model_alias_hana_relationship="xai/grok-4.6",
    )
    client = NineRouterClient(
        configured,
        httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://router/v1"),
    )
    await client.complete(
        purpose="chat_turn",
        mode="relationship",
        messages=[ChatMessage(role="user", content="hello")],
        temperature=0,
        max_tokens=10,
        json_mode=False,
        timeout_s=1,
    )
    assert seen["model"] == "xai/grok-4.6"


@pytest.mark.asyncio
async def test_relationship_fallback_routes_to_server_selected_grok_alias():
    seen = {}

    def handler(request):
        seen.update(json.loads(request.content))
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": "{}"}, "finish_reason": "stop"}]},
        )

    configured = Settings(
        app_env="test",
        ai_fake=False,
        nine_router_base_url="http://router/v1",
        model_alias_hana_relationship_fallback="xai/grok-4.5",
    )
    client = NineRouterClient(
        configured,
        httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://router/v1"),
    )
    await client.complete(
        purpose="chat_fallback",
        mode="relationship",
        messages=[ChatMessage(role="user", content="hello")],
        temperature=0,
        max_tokens=10,
        json_mode=False,
        timeout_s=1,
    )
    assert seen["model"] == "xai/grok-4.5"


@pytest.mark.asyncio
@pytest.mark.parametrize("status", [401, 403, 404, 422])
async def test_gateway_does_not_retry_auth_or_invalid_request(status):
    calls = 0

    def handler(request):
        nonlocal calls
        calls += 1
        return httpx.Response(status, text="denied")

    client = NineRouterClient(
        settings(),
        httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://router/v1"),
    )
    with pytest.raises(GatewayFailure) as error:
        await call(client)
    assert calls == 1
    assert not error.value.retryable


@pytest.mark.asyncio
async def test_invalid_configured_model_alias_fails_without_retry():
    calls = 0

    def handler(request):
        nonlocal calls
        calls += 1
        assert json.loads(request.content)["model"] == "missing-model"
        return httpx.Response(404, text="model not found")

    config = Settings(
        app_env="test",
        ai_fake=False,
        nine_router_base_url="http://router/v1",
        model_alias_hana_chat="missing-model",
    )
    client = NineRouterClient(
        config,
        httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://router/v1"),
    )
    with pytest.raises(GatewayFailure) as error:
        await call(client)
    assert calls == 1
    assert error.value.status == 404
    assert not error.value.retryable


@pytest.mark.asyncio
async def test_gateway_retries_bounded_503_then_succeeds():
    calls = 0

    def handler(request):
        nonlocal calls
        calls += 1
        if calls == 1:
            return httpx.Response(503)
        return httpx.Response(200, json={"choices": [{"message": {"content": "{}"}}]})

    client = NineRouterClient(
        settings(),
        httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://router/v1"),
    )
    await call(client)
    assert calls == 2


@pytest.mark.asyncio
@pytest.mark.parametrize("status", [429, 500, 502, 503, 504])
async def test_gateway_retries_all_transient_statuses_but_is_bounded(status):
    calls = 0

    def handler(request):
        nonlocal calls
        calls += 1
        return httpx.Response(status)

    client = NineRouterClient(
        settings(),
        httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://router/v1"),
    )
    with pytest.raises(GatewayFailure) as error:
        await call(client)
    assert calls == 2
    assert error.value.retryable


@pytest.mark.asyncio
async def test_gateway_timeout_retries_then_returns_typed_failure(monkeypatch):
    calls = 0

    def handler(request):
        nonlocal calls
        calls += 1
        raise httpx.ReadTimeout("late", request=request)

    async def no_sleep(_):
        return None

    monkeypatch.setattr("app.domain.ai.gateway.asyncio.sleep", no_sleep)
    client = NineRouterClient(
        settings(),
        httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://router/v1"),
    )
    with pytest.raises(GatewayFailure) as error:
        await call(client)
    assert calls == 2
    assert error.value.code == "LLM_TIMEOUT"
    assert error.value.retryable


@pytest.mark.asyncio
async def test_json_mode_400_is_disabled_without_consuming_retry():
    bodies = []

    def handler(request):
        body = json.loads(request.content)
        bodies.append(body)
        if "response_format" in body:
            return httpx.Response(400, text="response_format unsupported")
        return httpx.Response(200, json={"choices": [{"message": {"content": "{}"}}]})

    client = NineRouterClient(
        settings(),
        httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://router/v1"),
    )
    await call(client)
    await call(client)
    assert "response_format" in bodies[0]
    assert "response_format" not in bodies[1]
    assert "response_format" not in bodies[2]


@pytest.mark.asyncio
async def test_json_mode_capability_negotiation_does_not_consume_repair_budget():
    calls = 0

    def handler(request):
        nonlocal calls
        calls += 1
        if calls == 1:
            return httpx.Response(400, text="response_format unsupported")
        return httpx.Response(200, json={"choices": [{"message": {"content": "{}"}}]})

    client = NineRouterClient(
        settings(),
        httpx.AsyncClient(transport=httpx.MockTransport(handler), base_url="http://router/v1"),
    )
    result = await client.complete(
        purpose="output_repair",
        mode="normal",
        messages=[ChatMessage(role="user", content="{}")],
        temperature=0,
        max_tokens=10,
        json_mode=True,
        timeout_s=1,
    )
    assert result.content == "{}"
    assert calls == 2


@pytest.mark.asyncio
async def test_fake_gateway_escapes_control_chars_and_does_not_echo_prompt_wrapper():
    client = FakeChatGateway()
    result = await client.complete(
        messages=[ChatMessage(role="user", content='<user_data>Chào "Hana"\nnhé</user_data>')]
    )
    assert json.loads(result.content)["reply"] == 'Em nghe anh nói: Chào "Hana"\nnhé'
    assert "<user_data>" not in result.content
