from __future__ import annotations

import re
import unicodedata

BLOCKLIST = {
    "hay subscribe cho kenh",
    "cam on cac ban da theo doi",
    "hen gap lai cac ban trong nhung video tiep theo",
    "ghien mi go",
    "subtitles by",
    "thank you for watching",
}


def normalize_transcript(text: str) -> str:
    value = re.sub(r"\s+", " ", unicodedata.normalize("NFC", text)).strip()[:4000]
    comparable = "".join(
        ch for ch in unicodedata.normalize("NFD", value.lower()) if unicodedata.category(ch) != "Mn"
    ).translate(str.maketrans({"đ": "d"}))
    comparable = re.sub(r"[^a-z0-9\s]", "", comparable).strip()
    if not comparable or comparable in BLOCKLIST:
        return ""
    return value
