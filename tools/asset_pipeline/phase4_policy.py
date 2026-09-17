from __future__ import annotations

from typing import Final


SCHEMA_VERSION: Final = 2
MANIFEST_VERSION_PREFIX: Final = "phase4"
CORE_STATES: Final = (
    "idle",
    "listening",
    "talking",
    "thinking",
    "happy",
    "shy",
    "surprised",
    "concerned",
    "working",
    "sleep",
)
STAGE_CONTEXTS: Final = ("daily", "assistant", "relationship", "private")
SENSITIVITIES: Final = ("normal", "suggestive", "private")
DELIVERIES: Final = ("bundle", "vault", "private_vault")
QUALITY_VALUES: Final = ("good", "fair", "poor")
LOOP_GRADES: Final = ("A", "B", "C", "D")


# Canonical Phase 3.2 seed, section 7.  The keys are source filenames because this
# is development-only policy input.  Runtime manifests never include these keys.
SEED_POLICY: Final[dict[str, dict]] = {
    "ARRJ9858.MP4": {"states": {"idle": "shared"}},
    "AXXF9103.MP4": {"states": {"talking": "primary"}},
    "AYAB0517.MP4": {"states": {"idle": "shared"}},
    "BBDR6876.MP4": {"states": {"idle": "shared"}},
    "BHGW7313.MP4": {"states": {"idle": "shared"}, "cues": ["greeting"]},
    "BIOI9071.MP4": {"states": {"happy": "primary"}},
    "BQLH6157.MP4": {"states": {"idle": "shared"}, "cues": ["playful"]},
    "BSOO5255.MP4": {"states": {"sleep": "primary"}},
    "CECO9917.MP4": {"states": {"idle": "shared"}},
    "DAIM1610.MP4": {"states": {"idle": "shared"}},
    "DFRT1741.MP4": {"states": {"idle": "shared"}},
    "ECOT1008.MP4": {"states": {"surprised": "primary"}},
    "EZRB0829.MP4": {"states": {"shy": "primary", "idle": "shared"}},
    "GAOW0715.MP4": {"states": {"sleep": "primary"}},
    "GZRZ3107.MP4": {"states": {"idle": "shared", "happy": "shared"}},
    "HOIJ9018.MP4": {"states": {"idle": "shared", "happy": "shared"}},
    "IBFT8450.MP4": {"states": {"concerned": "primary"}},
    "JEPK9717.MP4": {
        "states": {"idle": "primary", "listening": "shared", "talking": "shared"}
    },
    "JEYK8192.MP4": {"states": {"idle": "shared"}},
    "JRQD8891.MP4": {"states": {"idle": "shared"}},
    "KCBG9830.MP4": {"states": {"idle": "shared"}},
    "KKWB4339.MP4": {"states": {"idle": "shared"}},
    "KNRQ5338.MP4": {"states": {"idle": "shared", "listening": "shared"}},
    "KPJR0660.MP4": {"states": {"idle": "shared"}},
    "LCHY0735.MP4": {"states": {"idle": "shared"}},
    "LXEZ3296.MP4": {
        "states": {"idle": "primary", "listening": "shared", "thinking": "shared"}
    },
    "MBYF9623.MP4": {"states": {"working": "primary"}},
    "MDBL5375.MP4": {"states": {"idle": "shared"}},
    "MMMD2325.MP4": {"states": {"idle": "shared", "talking": "shared"}},
    "MNZY6791.MP4": {"states": {"thinking": "primary"}},
    "OGNR9411.MP4": {"states": {"idle": "shared"}},
    "QOGV4635.MP4": {"states": {"happy": "primary"}},
    "RBQJ4191.MP4": {"states": {"shy": "shared", "happy": "shared"}},
    "RDOC5978.MP4": {"states": {"surprised": "primary"}},
    "RKUV3687.MP4": {"states": {"idle": "shared"}},
    "SANI5812.MP4": {"states": {"idle": "shared"}},
    "SBDE7512.MP4": {"states": {"shy": "primary"}},
    "VEZT1070.MP4": {"states": {"idle": "shared"}},
    "VXMN4535.MP4": {"states": {"working": "primary"}},
    "WRKX9090.MP4": {"states": {"shy": "primary"}},
    "WXYU8680.MP4": {
        "states": {"idle": "primary", "listening": "shared", "thinking": "shared"}
    },
    "XNPM3086.MP4": {"states": {"happy": "primary"}},
    "YITD3424.MP4": {"states": {"happy": "shared"}, "cues": ["greeting"]},
}


CUE_REGISTRY: Final[list[dict]] = [
    {
        "cue": "greeting",
        "allowed_modes": ["daily", "relationship", "private"],
        "cooldown_s": 600,
        "allowed_in_quiet_hours": False,
        "llm_selectable": False,
    },
    {
        "cue": "playful",
        "allowed_modes": ["relationship", "private"],
        "cooldown_s": 600,
        "allowed_in_quiet_hours": False,
        "llm_selectable": False,
    },
]


EXPECTED_REVIEW_IDS: Final = {
    "chr_001", "chr_004", "chr_005", "chr_009", "chr_010", "chr_012",
    "chr_016", "chr_019", "chr_020", "chr_021", "chr_023", "chr_024",
    "chr_025", "chr_028", "chr_029", "chr_031", "chr_033", "chr_034",
    "chr_036",
}
POOR_IDS: Final = {"chr_011", "chr_022"}


def delivery_for(content_sensitivity: str, allowed_modes: list[str]) -> str:
    if allowed_modes == ["private"]:
        return "private_vault"
    if content_sensitivity == "normal":
        return "bundle"
    return "vault"
