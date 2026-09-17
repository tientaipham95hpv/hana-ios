from __future__ import annotations

import asyncio
import json
import random
from dataclasses import dataclass
from time import perf_counter
from typing import Protocol

import httpx

from app.core.config import Settings
from app.domain.ai.protocol import ChatMessage


@dataclass(frozen=True)
class GatewayResult:
    content: str
    finish_reason: str
    prompt_tokens: int | None
    completion_tokens: int | None
    latency_ms: int
    model: str


class GatewayFailure(RuntimeError):
    def __init__(self, code: str, *, retryable: bool, status: int | None = None) -> None:
        super().__init__(code)
        self.code = code
        self.retryable = retryable
        self.status = status


class ChatGateway(Protocol):
    async def complete(
        self,
        *,
        purpose: str,
        mode: str,
        messages: list[ChatMessage],
        temperature: float,
        max_tokens: int,
        json_mode: bool,
        timeout_s: float,
    ) -> GatewayResult: ...


class FakeChatGateway:
    def __init__(self, responses: list[str] | None = None) -> None:
        self.responses = list(responses or [])
        self.calls: list[list[ChatMessage]] = []

    async def complete(self, **kwargs) -> GatewayResult:
        messages = kwargs["messages"]
        self.calls.append(messages)
        if self.responses:
            content = self.responses.pop(0)
        else:
            user = next((m.content for m in reversed(messages) if m.role == "user"), "")
            if user.startswith("<user_data>") and user.endswith("</user_data>"):
                user = user[len("<user_data>") : -len("</user_data>")]
            content = json.dumps(
                {
                    "v": 1,
                    "reply": f"Em nghe anh nói: {user[:500]}",
                    "mode": "normal",
                    "emotion": "neutral",
                    "intensity": "low",
                    "special_cue": None,
                    "actions": [],
                },
                ensure_ascii=False,
            )
        return GatewayResult(content, "stop", None, None, 1, "fake:hana_chat")


class NineRouterClient:
    def __init__(self, settings: Settings, client: httpx.AsyncClient | None = None) -> None:
        self.settings = settings
        self._owns_client = client is None
        self.client = client or httpx.AsyncClient(
            base_url=settings.nine_router_base_url.rstrip("/"),
            timeout=httpx.Timeout(settings.request_timeout_s, connect=settings.connect_timeout_s),
            limits=httpx.Limits(max_connections=20, max_keepalive_connections=10),
        )
        self._json_mode_disabled: set[str] = set()

    def _headers(self) -> dict[str, str]:
        return (
            {"Authorization": f"Bearer {self.settings.nine_router_api_key}"}
            if self.settings.nine_router_api_key
            else {}
        )

    async def complete(
        self,
        *,
        purpose: str,
        mode: str,
        messages: list[ChatMessage],
        temperature: float,
        max_tokens: int,
        json_mode: bool,
        timeout_s: float,
    ) -> GatewayResult:
        family = {
            "relationship": "hana_relationship",
            "private": "hana_private",
        }.get(mode, "hana_chat")
        alias = f"{family}_fallback" if purpose in {"output_repair", "chat_fallback"} else family
        model = self.settings.model_for(alias)
        body = {
            "model": model,
            "messages": [message.model_dump() for message in messages],
            "temperature": temperature,
            "max_tokens": max_tokens,
            "stream": False,
        }
        if json_mode and model not in self._json_mode_disabled:
            body["response_format"] = {"type": "json_object"}
        attempts = 2 if purpose == "chat_turn" else 1
        for attempt in range(attempts):
            started = perf_counter()
            try:
                response = await self.client.post(
                    "/chat/completions", headers=self._headers(), json=body, timeout=timeout_s
                )
            except (httpx.TimeoutException, httpx.NetworkError) as exc:
                if attempt + 1 < attempts:
                    await asyncio.sleep(0.15 + random.random() * 0.2)
                    continue
                raise GatewayFailure("LLM_TIMEOUT", retryable=True) from exc
            if (
                response.status_code == 400
                and "response_format" in response.text
                and "response_format" in body
            ):
                self._json_mode_disabled.add(model)
                body.pop("response_format", None)
                try:
                    # Capability negotiation is not a transient retry. In
                    # particular, output_repair has only one retry budget.
                    response = await self.client.post(
                        "/chat/completions", headers=self._headers(), json=body, timeout=timeout_s
                    )
                except (httpx.TimeoutException, httpx.NetworkError) as exc:
                    raise GatewayFailure("LLM_TIMEOUT", retryable=True) from exc
            if response.status_code in {400, 401, 403, 404, 422}:
                raise GatewayFailure(
                    "NINE_ROUTER_AUTH" if response.status_code == 401 else "LLM_UNAVAILABLE",
                    retryable=False,
                    status=response.status_code,
                )
            if response.status_code == 429 or response.status_code in {500, 502, 503, 504}:
                try:
                    retry_after = float(response.headers.get("retry-after", "0") or 0)
                except ValueError:
                    retry_after = 0
                if attempt + 1 < attempts and retry_after <= 5:
                    await asyncio.sleep(max(retry_after, 0.15) + random.random() * 0.2)
                    continue
                raise GatewayFailure("LLM_UNAVAILABLE", retryable=True, status=response.status_code)
            try:
                response.raise_for_status()
                data = response.json()
                choice = data["choices"][0]
                usage = data.get("usage", {})
                return GatewayResult(
                    content=choice["message"]["content"],
                    finish_reason=choice.get("finish_reason", "stop"),
                    prompt_tokens=usage.get("prompt_tokens"),
                    completion_tokens=usage.get("completion_tokens"),
                    latency_ms=int((perf_counter() - started) * 1000),
                    model=data.get("model", model),
                )
            except (KeyError, ValueError, httpx.HTTPError) as exc:
                raise GatewayFailure(
                    "LLM_UNAVAILABLE", retryable=True, status=response.status_code
                ) from exc
        raise GatewayFailure("LLM_UNAVAILABLE", retryable=True)

    async def health(self) -> bool:
        try:
            response = await self.client.get("/models", headers=self._headers(), timeout=3)
            return response.status_code < 500
        except httpx.HTTPError:
            return False

    async def close(self) -> None:
        if self._owns_client:
            await self.client.aclose()
