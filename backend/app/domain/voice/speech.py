from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

ONES = ["không", "một", "hai", "ba", "bốn", "năm", "sáu", "bảy", "tám", "chín"]


def number_to_vietnamese(number: int) -> str:
    if number < 0:
        return "âm " + number_to_vietnamese(-number)
    if number < 10:
        return ONES[number]
    if number < 20:
        return "mười" + (
            "" if number == 10 else " " + ("lăm" if number == 15 else ONES[number - 10])
        )
    if number < 100:
        tens, unit = divmod(number, 10)
        suffix = "" if unit == 0 else " " + ({1: "mốt", 4: "tư", 5: "lăm"}.get(unit, ONES[unit]))
        return f"{ONES[tens]} mươi{suffix}"
    if number < 1000:
        hundreds, rest = divmod(number, 100)
        if rest == 0:
            return f"{ONES[hundreds]} trăm"
        if rest < 10:
            return f"{ONES[hundreds]} trăm linh {ONES[rest]}"
        return f"{ONES[hundreds]} trăm {number_to_vietnamese(rest)}"
    for scale, label in ((1_000_000_000, "tỷ"), (1_000_000, "triệu"), (1_000, "nghìn")):
        if number >= scale:
            head, rest = divmod(number, scale)
            if rest == 0:
                return f"{number_to_vietnamese(head)} {label}"
            if rest < scale // 10:
                width = 3 if scale >= 1000 else 0
                prefix = "không trăm " if width and rest < 100 else ""
                return f"{number_to_vietnamese(head)} {label} {prefix}{number_to_vietnamese(rest)}"
            return f"{number_to_vietnamese(head)} {label} {number_to_vietnamese(rest)}"
    return str(number)


def _speak_time(match: re.Match[str]) -> str:
    hour = int(match.group(1))
    minute = int(match.group(2) or 0)
    if hour == 0:
        spoken_hour, period = 12, "đêm"
    elif hour <= 10:
        spoken_hour, period = hour, "sáng"
    elif hour <= 12:
        spoken_hour, period = hour, "trưa"
    elif hour <= 17:
        spoken_hour, period = hour - 12, "chiều"
    elif hour <= 21:
        spoken_hour, period = hour - 12, "tối"
    else:
        spoken_hour, period = hour - 12, "đêm"
    minute_text = (
        "" if minute == 0 else " rưỡi" if minute == 30 else " " + number_to_vietnamese(minute)
    )
    return f"{number_to_vietnamese(spoken_hour)} giờ{minute_text} {period}"


def normalize_speech(text: str) -> str:
    value = unicodedata.normalize("NFC", text)
    value = re.sub(r"\[([^]]+)]\(https?://[^)]+\)", r"\1", value)
    value = re.sub(r"https?://\S+", "đường link", value)
    value = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "địa chỉ email", value)
    value = re.sub(r"(?m)^\s*(?:[-*]|\d+[.)])\s+", "", value)
    value = re.sub(r"[*_`#>]", "", value)
    value = re.sub(
        r"(?<!\d)([01]?\d|2[0-3])(?::|h)([0-5]\d)?(?!\d)", _speak_time, value, flags=re.IGNORECASE
    )
    value = re.sub(
        r"\b(\d+)\s*%", lambda m: number_to_vietnamese(int(m.group(1))) + " phần trăm", value
    )
    value = re.sub(
        r"\b(\d+)\s*k\b",
        lambda m: number_to_vietnamese(int(m.group(1))) + " nghìn",
        value,
        flags=re.IGNORECASE,
    )
    replacements = {
        "ko": "không",
        "k": "không",
        "dc": "được",
        "đc": "được",
        "ok": "ô kê",
        "vs": "với",
    }
    for old, new in replacements.items():
        value = re.sub(rf"\b{re.escape(old)}\b", new, value, flags=re.IGNORECASE)
    value = "".join(ch for ch in value if unicodedata.category(ch) not in {"So", "Cs"})
    value = re.sub(r"\s+", " ", value).strip()
    if value and value[-1] not in ".!?…":
        value += "."
    return value


@dataclass(frozen=True)
class Segment:
    index: int
    text: str
    char_start: int
    char_end: int


def segment_speech(text: str, maximum: int = 220) -> list[Segment]:
    if not text:
        return []
    pieces = [piece for piece in re.split(r"(?<=[.!?…])\s+|\n+", text) if piece]
    chunks: list[str] = []
    for piece in pieces:
        while len(piece) > maximum:
            cut = max(piece.rfind(mark, 0, maximum + 1) for mark in (",", ";", ":", " "))
            if cut < 1:
                cut = maximum
            chunks.append(piece[: cut + (piece[cut : cut + 1] != " ")].strip())
            piece = piece[cut + 1 :].strip()
        if chunks and len(chunks[-1]) < 40 and len(chunks[-1]) + 1 + len(piece) <= maximum:
            chunks[-1] += " " + piece
        elif piece:
            chunks.append(piece)
    result: list[Segment] = []
    cursor = 0
    for index, chunk in enumerate(chunks):
        start = text.find(chunk, cursor)
        if start < 0:
            start = cursor
        end = start + len(chunk)
        result.append(Segment(index, chunk, start, end))
        cursor = end
    return result
