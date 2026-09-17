import json

import pytest

from app.domain.ai.protocol import EnvelopeError, fallback_envelope, parse_envelope, safe_plain_text
from app.domain.character.director import direct


def envelope(**updates):
    value = {
        "v": 1,
        "reply": "Dạ anh.",
        "mode": "normal",
        "emotion": "happy",
        "intensity": "medium",
        "special_cue": "celebrate",
        "actions": [],
    }
    value.update(updates)
    return json.dumps(value, ensure_ascii=False)


def test_valid_envelope():
    value = parse_envelope(envelope())
    assert value.reply == "Dạ anh."
    assert value.emotion == "happy"


def test_code_fence_is_accepted():
    assert parse_envelope(f"```json\n{envelope()}\n```").v == 1


@pytest.mark.parametrize(
    "raw", ["", "{}", "{bad", "[]", envelope(emotion="angry"), envelope(reply="")]
)
def test_malformed_or_invalid_envelope_is_rejected(raw):
    with pytest.raises(EnvelopeError):
        parse_envelope(raw)


def test_unknown_top_level_asset_fields_are_dropped():
    value = parse_envelope(
        envelope(asset_id="chr_001", filename="secret.mp4", path="/tmp/x", stage_context="private")
    )
    assert "asset_id" not in value.model_dump()
    assert "filename" not in value.model_dump()
    cue = direct(value)
    assert set(cue.model_dump()) == {
        "cue_id",
        "source",
        "emotion",
        "intensity",
        "special_cue",
        "stage_context",
        "reason",
    }


def test_unknown_action_is_data_not_execution():
    value = parse_envelope(envelope(actions=[{"type": "shell.exec", "args": {"command": "bad"}}]))
    assert value.actions[0].type == "shell.exec"


def test_six_actions_are_rejected():
    with pytest.raises(EnvelopeError):
        parse_envelope(envelope(actions=[{"type": "x", "args": {}}] * 6))


def test_invalid_special_cue_is_rejected():
    with pytest.raises(EnvelopeError):
        parse_envelope(envelope(special_cue="../../asset"))


def test_unknown_special_cue_is_sanitized_by_director():
    value = parse_envelope(envelope(special_cue="not_registered"))
    assert direct(value).special_cue is None


def test_plain_text_recovery_only_for_safe_plain_text():
    assert safe_plain_text("Xin chào").reply == "Xin chào"
    assert safe_plain_text('{"broken"') is None


@pytest.mark.parametrize(
    "code", ["LLM_TIMEOUT", "LLM_UNAVAILABLE", "LLM_INVALID_OUTPUT", "STT_EMPTY", "STT_FAILED"]
)
def test_fallback_is_semantic_concerned(code):
    value = fallback_envelope(code)
    assert value.reply
    assert value.emotion == "concerned"
    assert value.actions == []
