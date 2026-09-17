from __future__ import annotations

import asyncio
import random
from pathlib import Path
from time import perf_counter

import httpx

from app.core.config import Settings
from app.domain.voice.providers import (
    FakeSpeechToTextProvider,
    FakeTextToSpeechProvider,
    SpeechToTextProvider,
    SttResult,
    TextToSpeechProvider,
    TtsResult,
)

RETRYABLE_STATUS = {429, 500, 502, 503, 504}


class _RetryingProvider:
    async def _post(
        self,
        client: httpx.AsyncClient,
        endpoint: str,
        *,
        headers: dict[str, str],
        timeout_s: float,
        **kwargs,
    ) -> httpx.Response:
        for attempt in range(2):
            try:
                response = await client.post(endpoint, headers=headers, timeout=timeout_s, **kwargs)
            except (httpx.TimeoutException, httpx.NetworkError):
                if attempt == 0:
                    await asyncio.sleep(0.15 + random.random() * 0.2)
                    continue
                raise
            if response.status_code not in RETRYABLE_STATUS or attempt == 1:
                response.raise_for_status()
                return response
            try:
                retry_after = float(response.headers.get("retry-after", "0") or 0)
            except ValueError:
                retry_after = 0
            if retry_after > 5:
                response.raise_for_status()
            await asyncio.sleep(max(0.15, retry_after) + random.random() * 0.2)
        raise RuntimeError("unreachable")


class DeepgramSpeechToTextProvider(_RetryingProvider):
    """Deepgram prerecorded transcription adapter; raw audio is never logged."""

    def __init__(self, settings: Settings, client: httpx.AsyncClient | None = None) -> None:
        self.settings = settings
        self._owns_client = client is None
        self.client = client or httpx.AsyncClient(
            base_url=settings.deepgram_base_url.rstrip("/"),
            timeout=httpx.Timeout(settings.request_timeout_s, connect=settings.connect_timeout_s),
        )

    async def transcribe(
        self,
        *,
        audio_path: Path,
        mime: str,
        language: str,
        prompt: str | None,
        timeout_s: float,
    ) -> SttResult:
        del prompt
        started = perf_counter()
        audio_bytes = await asyncio.to_thread(audio_path.read_bytes)
        response = await self._post(
            self.client,
            "/listen",
            headers={
                "Authorization": f"Token {self.settings.deepgram_api_key}",
                "Content-Type": mime,
            },
            timeout_s=timeout_s,
            params={
                "model": self.settings.deepgram_stt_model,
                "language": language or self.settings.deepgram_language,
                "smart_format": "true",
            },
            content=audio_bytes,
        )
        body = response.json()
        metadata = body.get("metadata") or {}
        channels = (body.get("results") or {}).get("channels") or []
        alternatives = (channels[0].get("alternatives") or []) if channels else []
        transcript = str(alternatives[0].get("transcript", "")) if alternatives else ""
        duration = metadata.get("duration")
        duration_ms = int(float(duration) * 1000) if duration is not None else None
        request_id = metadata.get("request_id") or response.headers.get("dg-request-id")
        return SttResult(
            text=transcript,
            duration_ms=duration_ms,
            latency_ms=int((perf_counter() - started) * 1000),
            model=self.settings.deepgram_stt_model,
            language=language or self.settings.deepgram_language,
            request_id=str(request_id) if request_id else None,
        )

    async def close(self) -> None:
        if self._owns_client:
            await self.client.aclose()


class ElevenLabsTextToSpeechProvider(_RetryingProvider):
    """ElevenLabs multilingual speech adapter returning MP3 by default."""

    def __init__(self, settings: Settings, client: httpx.AsyncClient | None = None) -> None:
        self.settings = settings
        self._owns_client = client is None
        self.client = client or httpx.AsyncClient(
            base_url=settings.elevenlabs_base_url.rstrip("/"),
            timeout=httpx.Timeout(settings.request_timeout_s, connect=settings.connect_timeout_s),
        )

    async def synthesize(
        self,
        *,
        text: str,
        voice: str,
        speed: float,
        style: str | None,
        timeout_s: float,
    ) -> TtsResult:
        del voice, style
        started = perf_counter()
        body: dict[str, object] = {
            "text": text,
            "model_id": self.settings.elevenlabs_model_id,
            "language_code": "vi",
        }
        if speed != 1.0:
            body["voice_settings"] = {"speed": max(0.7, min(1.2, speed))}
        response = await self._post(
            self.client,
            f"/text-to-speech/{self.settings.elevenlabs_voice_id}",
            headers={
                "xi-api-key": self.settings.elevenlabs_api_key,
                "Accept": "audio/mpeg",
                "Content-Type": "application/json",
            },
            timeout_s=timeout_s,
            params={"output_format": self.settings.elevenlabs_output_format},
            json=body,
        )
        request_id = response.headers.get("request-id") or response.headers.get("x-request-id")
        mime = response.headers.get("content-type", "audio/mpeg").split(";")[0]
        if not response.content or not mime.startswith("audio/"):
            raise ValueError("ElevenLabs returned non-audio content")
        return TtsResult(
            audio_bytes=response.content,
            mime=mime,
            latency_ms=int((perf_counter() - started) * 1000),
            model=self.settings.elevenlabs_model_id,
            request_id=request_id,
        )

    async def close(self) -> None:
        if self._owns_client:
            await self.client.aclose()


def create_stt_provider(settings: Settings) -> SpeechToTextProvider:
    if settings.stt_provider == "deepgram":
        return DeepgramSpeechToTextProvider(settings)
    return FakeSpeechToTextProvider(settings.fake_stt_transcript)


def create_tts_provider(settings: Settings) -> TextToSpeechProvider:
    if settings.tts_provider == "elevenlabs":
        return ElevenLabsTextToSpeechProvider(settings)
    return FakeTextToSpeechProvider()
