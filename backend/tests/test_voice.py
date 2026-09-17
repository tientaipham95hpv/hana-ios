import httpx
import pytest

from app.core.config import Settings
from app.domain.voice.providers import FakeSTTProvider, FakeTTSProvider
from app.domain.voice.speech import normalize_speech, number_to_vietnamese, segment_speech
from app.domain.voice.stt import normalize_transcript
from app.integrations.voice_providers import (
    DeepgramSpeechToTextProvider,
    ElevenLabsTextToSpeechProvider,
)


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ("Họp lúc 15:00 nha", "Họp lúc ba giờ chiều nha."),
        ("08:30", "tám giờ rưỡi sáng."),
        ("00:00", "mười hai giờ đêm."),
        ("12:05", "mười hai giờ năm trưa."),
        ("50k", "năm mươi nghìn."),
        ("30%", "ba mươi phần trăm."),
        ("**Xong** rồi 😊", "Xong rồi."),
        ("ko dc", "không được."),
        ("https://example.com", "đường link."),
        ("a@example.com", "địa chỉ email."),
    ],
)
def test_speech_normalizer(source, expected):
    assert normalize_speech(source) == expected


@pytest.mark.parametrize(
    ("number", "spoken"),
    [(15, "mười lăm"), (21, "hai mươi mốt"), (24, "hai mươi tư"), (105, "một trăm linh năm")],
)
def test_numbers(number, spoken):
    assert number_to_vietnamese(number) == spoken


def test_segmenter_limits_and_preserves_text_content():
    value = " ".join(["từ"] * 500) + "."
    segments = segment_speech(value)
    assert segments
    assert all(len(item.text) <= 220 for item in segments)
    assert " ".join(item.text for item in segments) == value
    assert [item.index for item in segments] == list(range(len(segments)))


@pytest.mark.parametrize(
    "value", ["", "...", "Cảm ơn các bạn đã theo dõi", "thank you for watching"]
)
def test_empty_and_hallucination_transcript(value):
    assert normalize_transcript(value) == ""


def test_valid_transcript_is_nfc_trimmed():
    assert normalize_transcript("  Xin   chào Hana  ") == "Xin chào Hana"


@pytest.mark.asyncio
async def test_fake_providers_are_deterministic(tmp_path):
    audio = tmp_path / "voice.m4a"
    audio.write_bytes(b"fixture")
    stt = FakeSTTProvider("xin chào")
    result = await stt.transcribe(
        audio_path=audio, mime="audio/mp4", language="vi", prompt=None, timeout_s=1
    )
    assert result.text == "xin chào"
    tts = FakeTTSProvider()
    speech = await tts.synthesize(text="xin chào", voice="hana", speed=1, style=None, timeout_s=1)
    assert speech.mime == "audio/wav"
    assert speech.audio_bytes[:4] == b"RIFF"


@pytest.mark.asyncio
async def test_deepgram_retries_transient_stt_with_complete_raw_audio(tmp_path, monkeypatch):
    path = tmp_path / "voice.m4a"
    path.write_bytes(b"audio-fixture")
    seen = []

    def handler(request):
        seen.append(request.content)
        return httpx.Response(
            503 if len(seen) == 1 else 200,
            json={
                "metadata": {},
                "results": {"channels": [{"alternatives": [{"transcript": "xin chao"}]}]},
            },
        )

    async def no_sleep(_):
        return None

    monkeypatch.setattr("app.integrations.voice_providers.asyncio.sleep", no_sleep)
    client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler), base_url="https://api.deepgram.com/v1"
    )
    provider = DeepgramSpeechToTextProvider(
        Settings(app_env="test", stt_provider="deepgram", deepgram_api_key="test-key"),
        client,
    )
    result = await provider.transcribe(
        audio_path=path, mime="audio/mp4", language="vi", prompt=None, timeout_s=1
    )
    assert result.text == "xin chao"
    assert len(seen) == 2
    assert all(b"audio-fixture" in body for body in seen)
    await client.aclose()


@pytest.mark.asyncio
@pytest.mark.parametrize("status", [400, 401, 403, 422])
async def test_elevenlabs_adapter_does_not_retry_invalid_request(status):
    calls = 0

    def handler(request):
        nonlocal calls
        calls += 1
        return httpx.Response(status)

    client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler), base_url="https://api.elevenlabs.io/v1"
    )
    provider = ElevenLabsTextToSpeechProvider(
        Settings(
            app_env="test",
            tts_provider="elevenlabs",
            elevenlabs_api_key="key",
            elevenlabs_voice_id="voice",
        ),
        client,
    )
    with pytest.raises(httpx.HTTPStatusError):
        await provider.synthesize(text="xin chao", voice="hana", speed=1, style=None, timeout_s=1)
    assert calls == 1
    await client.aclose()


@pytest.mark.asyncio
async def test_elevenlabs_adapter_retries_tts_429_once(monkeypatch):
    calls = 0

    def handler(request):
        nonlocal calls
        calls += 1
        return httpx.Response(
            429 if calls == 1 else 200, content=b"mp3", headers={"content-type": "audio/mpeg"}
        )

    async def no_sleep(_):
        return None

    monkeypatch.setattr("app.integrations.voice_providers.asyncio.sleep", no_sleep)
    client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler), base_url="https://api.elevenlabs.io/v1"
    )
    provider = ElevenLabsTextToSpeechProvider(
        Settings(
            app_env="test",
            tts_provider="elevenlabs",
            elevenlabs_api_key="key",
            elevenlabs_voice_id="voice",
        ),
        client,
    )
    result = await provider.synthesize(
        text="xin chao", voice="hana", speed=1, style=None, timeout_s=1
    )
    assert result.audio_bytes == b"mp3"
    assert calls == 2
    await client.aclose()


@pytest.mark.asyncio
async def test_deepgram_vietnamese_transcription_and_metadata(tmp_path):
    path = tmp_path / "voice.m4a"
    path.write_bytes(b"not-sensitive-fixture")

    def handler(request):
        assert request.headers["authorization"] == "Token deepgram-test-key"
        assert request.headers["content-type"] == "audio/mp4"
        assert request.url.params["language"] == "vi"
        assert request.url.params["model"] == "nova-3"
        assert request.content == b"not-sensitive-fixture"
        return httpx.Response(
            200,
            json={
                "metadata": {"request_id": "dg-1", "duration": 1.25},
                "results": {"channels": [{"alternatives": [{"transcript": "Xin chào Hana"}]}]},
            },
        )

    settings = Settings(
        app_env="test",
        stt_provider="deepgram",
        deepgram_api_key="deepgram-test-key",
    )
    client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler), base_url="https://api.deepgram.com/v1"
    )
    provider = DeepgramSpeechToTextProvider(settings, client)
    result = await provider.transcribe(
        audio_path=path, mime="audio/mp4", language="vi", prompt=None, timeout_s=1
    )
    assert result.text == "Xin chào Hana"
    assert result.duration_ms == 1250
    assert result.request_id == "dg-1"
    await client.aclose()


@pytest.mark.asyncio
async def test_elevenlabs_tts_uses_server_voice_and_returns_request_metadata():
    def handler(request):
        assert request.headers["xi-api-key"] == "eleven-test-key"
        assert request.url.path.endswith("/text-to-speech/voice-server-side")
        assert request.url.params["output_format"] == "mp3_44100_128"
        assert b"eleven_flash_v2_5" in request.content
        return httpx.Response(
            200,
            content=b"valid-mp3-fixture",
            headers={"content-type": "audio/mpeg", "request-id": "el-1"},
        )

    settings = Settings(
        app_env="test",
        tts_provider="elevenlabs",
        elevenlabs_api_key="eleven-test-key",
        elevenlabs_voice_id="voice-server-side",
    )
    client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler), base_url="https://api.elevenlabs.io/v1"
    )
    provider = ElevenLabsTextToSpeechProvider(settings, client)
    result = await provider.synthesize(
        text="Xin chào", voice="ignored-client-voice", speed=1, style=None, timeout_s=1
    )
    assert result.audio_bytes == b"valid-mp3-fixture"
    assert result.request_id == "el-1"
    assert result.mime == "audio/mpeg"
    await client.aclose()


@pytest.mark.asyncio
@pytest.mark.parametrize("status", [400, 401, 403, 422])
async def test_elevenlabs_does_not_retry_auth_or_invalid_request(status):
    calls = 0

    def handler(_request):
        nonlocal calls
        calls += 1
        return httpx.Response(status)

    settings = Settings(
        app_env="test",
        tts_provider="elevenlabs",
        elevenlabs_api_key="test-key",
        elevenlabs_voice_id="test-voice",
    )
    client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler), base_url="https://api.elevenlabs.io/v1"
    )
    provider = ElevenLabsTextToSpeechProvider(settings, client)
    with pytest.raises(httpx.HTTPStatusError):
        await provider.synthesize(
            text="Xin chào", voice="ignored", speed=1, style=None, timeout_s=1
        )
    assert calls == 1
    await client.aclose()


@pytest.mark.asyncio
async def test_deepgram_retries_one_server_error_then_returns_empty_transcript(
    tmp_path, monkeypatch
):
    audio = tmp_path / "voice.m4a"
    audio.write_bytes(b"fixture")
    calls = 0

    def handler(_request):
        nonlocal calls
        calls += 1
        if calls == 1:
            return httpx.Response(503)
        return httpx.Response(200, json={"metadata": {}, "results": {"channels": []}})

    async def no_sleep(_):
        return None

    monkeypatch.setattr("app.integrations.voice_providers.asyncio.sleep", no_sleep)
    settings = Settings(app_env="test", stt_provider="deepgram", deepgram_api_key="test-key")
    client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler), base_url="https://api.deepgram.com/v1"
    )
    provider = DeepgramSpeechToTextProvider(settings, client)
    result = await provider.transcribe(
        audio_path=audio, mime="audio/mp4", language="vi", prompt=None, timeout_s=1
    )
    assert calls == 2
    assert result.text == ""
    await client.aclose()


@pytest.mark.asyncio
async def test_elevenlabs_rejects_non_audio_success_body():
    settings = Settings(
        app_env="test",
        tts_provider="elevenlabs",
        elevenlabs_api_key="test-key",
        elevenlabs_voice_id="test-voice",
    )
    client = httpx.AsyncClient(
        transport=httpx.MockTransport(
            lambda _request: httpx.Response(
                200, content=b"not audio", headers={"content-type": "application/json"}
            )
        ),
        base_url="https://api.elevenlabs.io/v1",
    )
    provider = ElevenLabsTextToSpeechProvider(settings, client)
    with pytest.raises(ValueError, match="non-audio"):
        await provider.synthesize(
            text="Xin chào", voice="ignored", speed=1, style=None, timeout_s=1
        )
    await client.aclose()


@pytest.mark.parametrize(
    "kwargs",
    [
        {"stt_provider": "deepgram"},
        {"tts_provider": "elevenlabs", "elevenlabs_voice_id": "voice"},
        {"tts_provider": "elevenlabs", "elevenlabs_api_key": "key"},
    ],
)
def test_live_voice_provider_config_fails_closed_without_credentials(kwargs):
    with pytest.raises(ValueError):
        Settings(app_env="test", **kwargs)
