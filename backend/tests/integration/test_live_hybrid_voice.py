"""Opt-in, paid-provider smoke tests; never executed by normal CI.

Run with RUN_HANA_LIVE_VOICE=1 and server-side provider environment set.
HANA_LIVE_VI_AUDIO_PATH must point to a non-sensitive Vietnamese speech clip.
"""

import os
from pathlib import Path

import pytest

from app.core.config import Settings
from app.integrations.voice_providers import (
    DeepgramSpeechToTextProvider,
    ElevenLabsTextToSpeechProvider,
)

pytestmark = pytest.mark.live_voice

if os.getenv("RUN_HANA_LIVE_VOICE") != "1":
    pytest.skip("set RUN_HANA_LIVE_VOICE=1 for paid providers", allow_module_level=True)


def _settings() -> Settings:
    required = ("DEEPGRAM_API_KEY", "ELEVENLABS_API_KEY", "ELEVENLABS_VOICE_ID")
    if not all(os.getenv(name) for name in required):
        pytest.skip("live provider credentials not configured")
    return Settings(
        _env_file=None,
        app_env="test",
        stt_provider="deepgram",
        tts_provider="elevenlabs",
    )


@pytest.mark.asyncio
async def test_live_deepgram_vietnamese_clip():
    settings = _settings()
    value = os.getenv("HANA_LIVE_VI_AUDIO_PATH", "")
    path = Path(value) if value else None
    if path is None or not path.is_file():
        pytest.skip("set HANA_LIVE_VI_AUDIO_PATH to a non-sensitive Vietnamese clip")
    mime = {
        ".wav": "audio/wav",
        ".m4a": "audio/mp4",
        ".mp3": "audio/mpeg",
        ".ogg": "audio/ogg",
    }.get(path.suffix.lower())
    if mime is None:
        pytest.skip("unsupported live audio fixture MIME")
    provider = DeepgramSpeechToTextProvider(settings)
    try:
        result = await provider.transcribe(
            audio_path=path,
            mime=mime,
            language="vi",
            prompt=None,
            timeout_s=20,
        )
        assert result.text.strip()
        assert result.latency_ms >= 0
    finally:
        await provider.close()


@pytest.mark.asyncio
async def test_live_elevenlabs_vietnamese_mp3():
    settings = _settings()
    provider = ElevenLabsTextToSpeechProvider(settings)
    try:
        result = await provider.synthesize(
            text="Xin chào, em là Hana.",
            voice="server-selected",
            speed=1.0,
            style=None,
            timeout_s=20,
        )
        assert result.mime == "audio/mpeg"
        assert result.audio_bytes.startswith(b"ID3") or result.audio_bytes[:2] in {
            b"\xff\xfb",
            b"\xff\xf3",
            b"\xff\xf2",
        }
        assert result.latency_ms >= 0
    finally:
        await provider.close()
