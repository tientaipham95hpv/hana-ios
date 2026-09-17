"""Provider-neutral speech contracts and deterministic fake adapters."""

from __future__ import annotations

import io
import struct
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


@dataclass(frozen=True)
class SttResult:
    text: str
    duration_ms: int | None
    latency_ms: int
    model: str
    language: str | None = "vi"
    request_id: str | None = None


@dataclass(frozen=True)
class TtsResult:
    audio_bytes: bytes
    mime: str
    latency_ms: int
    model: str
    duration_ms: int | None = None
    request_id: str | None = None


class SpeechToTextProvider(Protocol):
    async def transcribe(
        self,
        *,
        audio_path: Path,
        mime: str,
        language: str,
        prompt: str | None,
        timeout_s: float,
    ) -> SttResult: ...


class TextToSpeechProvider(Protocol):
    async def synthesize(
        self,
        *,
        text: str,
        voice: str,
        speed: float,
        style: str | None,
        timeout_s: float,
    ) -> TtsResult: ...


class FakeSpeechToTextProvider:
    def __init__(self, transcript: str = "Xin chào Hana") -> None:
        self.transcript = transcript
        self.calls = 0

    async def transcribe(self, **kwargs) -> SttResult:
        self.calls += 1
        return SttResult(self.transcript, None, 1, "fake:hana_stt")


def _silent_wav(duration_ms: int) -> bytes:
    rate = 16000
    frames = max(1, rate * duration_ms // 1000)
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(struct.pack("<h", 0) * frames)
    return output.getvalue()


class FakeTextToSpeechProvider:
    def __init__(self) -> None:
        self.calls = 0

    async def synthesize(self, *, text: str, **kwargs) -> TtsResult:
        self.calls += 1
        duration = min(4000, max(250, len(text) * 35))
        return TtsResult(_silent_wav(duration), "audio/wav", 1, "fake:hana_tts", duration)


FakeSTTProvider = FakeSpeechToTextProvider
FakeTTSProvider = FakeTextToSpeechProvider
