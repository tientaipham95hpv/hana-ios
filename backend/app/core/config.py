from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore", case_sensitive=False)

    app_env: str = "local"
    log_level: str = "INFO"
    database_url_app: str = "postgresql+asyncpg://hana_app:hana_local@localhost:5432/hana"
    redis_url: str = "redis://localhost:6379/0"
    nine_router_base_url: str = "http://host.docker.internal:20128/v1"
    nine_router_api_key: str = ""
    ai_fake: bool = True
    stt_provider: str = "fake"
    tts_provider: str = "fake"
    fake_stt_transcript: str = "Xin chao Hana"
    dev_auth_bypass: bool = True
    llm_prompt_logging: bool = False
    media_root: Path = Path("./.data/media")
    audio_probe_enabled: bool = False
    model_alias_hana_chat: str = "cx/gpt-5.6-terra"
    model_alias_hana_chat_fallback: str = "cx/gpt-5.6-sol"
    model_alias_hana_relationship: str = "xai/grok-4.6"
    model_alias_hana_relationship_fallback: str = "xai/grok-4.5"
    model_alias_hana_private: str = "xai/grok-4.6"
    model_alias_hana_private_fallback: str = "xai/grok-4.5"
    deepgram_base_url: str = "https://api.deepgram.com/v1"
    deepgram_api_key: str = ""
    deepgram_stt_model: str = "nova-3"
    deepgram_language: str = "vi"
    elevenlabs_base_url: str = "https://api.elevenlabs.io/v1"
    elevenlabs_api_key: str = ""
    elevenlabs_voice_id: str = ""
    elevenlabs_model_id: str = "eleven_flash_v2_5"
    elevenlabs_output_format: str = "mp3_44100_128"
    tts_voice: str = "hana"
    connect_timeout_s: float = 5.0
    request_timeout_s: float = 30.0
    turn_stream_ttl_s: int = 900
    voice_upload_ttl_s: int = 900
    tts_ttl_s: int = 86400
    tts_cache_max_bytes: int = 104857600
    worker_queue_name: str = "hana:normal"
    rate_limit_turns_per_minute: int = 20
    allowed_origins: list[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def secure_environment(self) -> Settings:
        if self.app_env not in {"local", "staging", "production", "test"}:
            raise ValueError("APP_ENV must be local, test, staging, or production")
        if self.app_env not in {"local", "test"} and self.dev_auth_bypass:
            raise ValueError("DEV_AUTH_BYPASS is forbidden outside local/test")
        if self.app_env != "local" and self.llm_prompt_logging:
            raise ValueError("LLM_PROMPT_LOGGING is local-only")
        if self.app_env not in {"local", "test"} and self.ai_fake:
            raise ValueError("AI_FAKE is forbidden outside local/test")
        if not self.ai_fake and not self.nine_router_base_url:
            raise ValueError("NINE_ROUTER_BASE_URL is required")
        if self.stt_provider not in {"fake", "deepgram"}:
            raise ValueError("STT_PROVIDER must be fake or deepgram")
        if self.tts_provider not in {"fake", "elevenlabs"}:
            raise ValueError("TTS_PROVIDER must be fake or elevenlabs")
        if self.stt_provider == "deepgram" and not self.deepgram_api_key:
            raise ValueError("DEEPGRAM_API_KEY is required for Deepgram STT")
        if self.tts_provider == "elevenlabs" and not (
            self.elevenlabs_api_key and self.elevenlabs_voice_id
        ):
            raise ValueError(
                "ELEVENLABS_API_KEY and ELEVENLABS_VOICE_ID are required for ElevenLabs TTS"
            )
        return self

    def model_for(self, alias: str) -> str:
        values = {
            "hana_chat": self.model_alias_hana_chat,
            "hana_chat_fallback": self.model_alias_hana_chat_fallback,
            "hana_relationship": self.model_alias_hana_relationship,
            "hana_relationship_fallback": self.model_alias_hana_relationship_fallback,
            "hana_private": self.model_alias_hana_private,
            "hana_private_fallback": self.model_alias_hana_private_fallback,
        }
        if alias not in values:
            raise ValueError(f"unknown model alias: {alias}")
        return values[alias]


@lru_cache
def get_settings() -> Settings:
    return Settings()
