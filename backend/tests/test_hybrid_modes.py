import uuid

import pytest
from fastapi import HTTPException

from app.api.turns import (
    ResponseMode,
    SemanticMode,
    TurnCreate,
    _should_speak,
    _validate_semantic_mode,
)
from app.core.config import Settings


@pytest.mark.parametrize(
    ("kind", "mode", "auto_play", "expected"),
    [
        ("text", ResponseMode.AUTO, True, False),
        ("voice", ResponseMode.AUTO, True, True),
        ("text", ResponseMode.VOICE_REPLY, True, True),
        ("voice", ResponseMode.VOICE_REPLY, True, True),
        ("text", ResponseMode.TEXT_ONLY, True, False),
        ("voice", ResponseMode.TEXT_ONLY, True, False),
        ("voice", ResponseMode.AUTO, False, False),
        ("text", ResponseMode.VOICE_REPLY, False, False),
    ],
)
def test_response_modes(kind, mode, auto_play, expected):
    assert (
        _should_speak(
            input_kind=kind,
            response_mode=mode,
            auto_play_voice=auto_play,
            legacy_speak=None,
        )
        is expected
    )


def test_default_text_turn_is_text_only_and_private_is_rejected():
    turn = TurnCreate(client_id=uuid.uuid4(), text="Xin chào")
    assert turn.response_mode == ResponseMode.AUTO
    assert not _should_speak(
        input_kind="text",
        response_mode=turn.response_mode,
        auto_play_voice=turn.auto_play_voice,
        legacy_speak=turn.speak,
    )
    with pytest.raises(HTTPException) as failure:
        _validate_semantic_mode(SemanticMode.PRIVATE)
    assert failure.value.status_code == 403


def test_alias_mapping_is_server_side_and_provider_specific():
    settings = Settings(
        app_env="test",
        model_alias_hana_chat="cx/gpt-5.6-terra",
        model_alias_hana_chat_fallback="cx/gpt-5.6-sol",
        model_alias_hana_relationship="xai/grok-4.6",
        model_alias_hana_relationship_fallback="xai/grok-4.5",
        model_alias_hana_private="xai/grok-4.6",
        model_alias_hana_private_fallback="xai/grok-4.5",
    )
    assert settings.model_for("hana_chat") == "cx/gpt-5.6-terra"
    assert settings.model_for("hana_chat_fallback") == "cx/gpt-5.6-sol"
    assert settings.model_for("hana_relationship") == "xai/grok-4.6"
    assert settings.model_for("hana_relationship_fallback") == "xai/grok-4.5"
    assert settings.model_for("hana_private") == "xai/grok-4.6"
    assert settings.model_for("hana_private_fallback") == "xai/grok-4.5"
    with pytest.raises(ValueError):
        settings.model_for("hana_stt")
