from __future__ import annotations

import json
import re
import subprocess
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from fractions import Fraction
from pathlib import Path
from typing import Any, Callable, Sequence


PROBE_VERSION = 1
SAFE_CONTAINER_TAGS = frozenset({"major_brand", "minor_version", "compatible_brands", "encoder"})


class ProbeError(RuntimeError):
    def __init__(self, message: str, return_code: int | None = None, stderr: str = "") -> None:
        super().__init__(message)
        self.return_code = return_code
        self.stderr = stderr


def sanitize_stderr(stderr: str, source_root: Path | None = None, limit: int = 4000) -> str:
    value = stderr.replace("\x00", "")
    if source_root is not None:
        root = str(source_root.resolve(strict=False))
        value = re.sub(re.escape(root), "<assets_source>", value, flags=re.IGNORECASE)
        value = re.sub(re.escape(root.replace("\\", "/")), "<assets_source>", value, flags=re.IGNORECASE)
    value = re.sub(r"(?i)(https?://)([^\s/:@]+):([^\s/@]+)@", r"\1<redacted>@", value)
    value = re.sub(
        r"(?i)\b(password|passwd|secret|api[_-]?key|auth[_-]?token|access[_-]?token)\s*[:=]\s*\S+",
        r"\1=<redacted>",
        value,
    )
    return value[-limit:].strip()


def _run(command: Sequence[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(command),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        shell=False,
        check=False,
    )


def run_ffprobe(
    path: Path,
    *,
    ffprobe_bin: str = "ffprobe",
    runner: Callable[[Sequence[str]], subprocess.CompletedProcess[str]] = _run,
) -> dict[str, Any]:
    command = [
        ffprobe_bin,
        "-v",
        "error",
        "-count_frames",
        "-show_streams",
        "-show_format",
        "-of",
        "json",
        "--",
        str(path),
    ]
    try:
        completed = runner(command)
    except OSError as exc:
        raise ProbeError(f"ffprobe could not start: {type(exc).__name__}") from exc
    if completed.returncode != 0:
        raise ProbeError("ffprobe failed", completed.returncode, completed.stderr)
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise ProbeError("ffprobe returned invalid JSON", completed.returncode, completed.stderr) from exc
    if not isinstance(value, dict):
        raise ProbeError("ffprobe JSON root is not an object", completed.returncode, completed.stderr)
    return value


def _integer(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError, OverflowError):
        return None


def _number(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    return number if number == number and number not in {float("inf"), float("-inf")} else None


def rate_to_float(value: Any) -> float | None:
    if value in (None, "", "0/0", "N/A"):
        return None
    try:
        rate = Fraction(str(value))
    except (ValueError, ZeroDivisionError):
        return None
    if rate.denominator == 0:
        return None
    return round(float(rate), 6)


def duration_to_ms(value: Any) -> int | None:
    if value in (None, "", "N/A"):
        return None
    try:
        duration = Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None
    if duration < 0:
        return None
    return int((duration * 1000).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def _attached_pic(stream: dict[str, Any]) -> bool:
    return bool(_integer(stream.get("disposition", {}).get("attached_pic")) or 0)


def select_main_video_stream(streams: list[dict[str, Any]]) -> dict[str, Any]:
    candidates = [stream for stream in streams if stream.get("codec_type") == "video" and not _attached_pic(stream)]
    if not candidates:
        raise ProbeError("no non-attached video stream found")
    return sorted(
        candidates,
        key=lambda stream: (
            -(_integer(stream.get("disposition", {}).get("default")) or 0),
            -((_integer(stream.get("width")) or 0) * (_integer(stream.get("height")) or 0)),
            _integer(stream.get("index")) if _integer(stream.get("index")) is not None else 2**31,
        ),
    )[0]


def _rotation(stream: dict[str, Any]) -> int | float | None:
    tag_rotation = _number(stream.get("tags", {}).get("rotate"))
    if tag_rotation is not None:
        return int(tag_rotation) if tag_rotation.is_integer() else tag_rotation
    for side_data in stream.get("side_data_list", []) or []:
        rotation = _number(side_data.get("rotation"))
        if rotation is not None:
            return int(rotation) if rotation.is_integer() else rotation
    return None


def _stream_duration_ms(stream: dict[str, Any], format_data: dict[str, Any]) -> int | None:
    return duration_to_ms(stream.get("duration")) or duration_to_ms(format_data.get("duration"))


def parse_ffprobe(payload: dict[str, Any]) -> dict[str, Any]:
    streams = payload.get("streams")
    format_data = payload.get("format") or {}
    if not isinstance(streams, list) or not all(isinstance(item, dict) for item in streams):
        raise ProbeError("ffprobe streams are missing or invalid")
    main = select_main_video_stream(streams)
    duration_ms = _stream_duration_ms(main, format_data)
    if duration_ms is None or duration_ms <= 0:
        raise ProbeError("video duration is missing or invalid")

    frame_count = _integer(main.get("nb_read_frames"))
    frame_count_source = "counted" if frame_count is not None else None
    if frame_count is None:
        frame_count = _integer(main.get("nb_frames"))
        frame_count_source = "declared" if frame_count is not None else None

    audio_streams = [stream for stream in streams if stream.get("codec_type") == "audio"]
    attached = [stream for stream in streams if stream.get("codec_type") == "video" and _attached_pic(stream)]
    subtitles = [stream for stream in streams if stream.get("codec_type") == "subtitle"]
    data_streams = [stream for stream in streams if stream.get("codec_type") == "data"]
    main_index = _integer(main.get("index"))
    known_indexes = {main_index} | {_integer(item.get("index")) for item in audio_streams + attached + subtitles + data_streams}
    other = [stream for stream in streams if _integer(stream.get("index")) not in known_indexes]

    video = {
        "stream_index": main_index,
        "codec_name": main.get("codec_name"),
        "profile": main.get("profile"),
        "level": _integer(main.get("level")),
        "width": _integer(main.get("width")),
        "height": _integer(main.get("height")),
        "sample_aspect_ratio": main.get("sample_aspect_ratio"),
        "display_aspect_ratio": main.get("display_aspect_ratio"),
        "pix_fmt": main.get("pix_fmt"),
        "avg_frame_rate": main.get("avg_frame_rate"),
        "avg_frame_rate_fps": rate_to_float(main.get("avg_frame_rate")),
        "r_frame_rate": main.get("r_frame_rate"),
        "r_frame_rate_fps": rate_to_float(main.get("r_frame_rate")),
        "frame_count": frame_count,
        "frame_count_source": frame_count_source,
        "bit_rate": _integer(main.get("bit_rate")),
        "rotation": _rotation(main),
        "color": {
            key: main.get(key)
            for key in ("color_range", "color_space", "color_transfer", "color_primaries", "chroma_location")
            if main.get(key) is not None
        },
    }
    audio = {
        "stream_count": len(audio_streams),
        "streams": [
            {
                "stream_index": _integer(stream.get("index")),
                "codec_name": stream.get("codec_name"),
                "sample_rate": _integer(stream.get("sample_rate")),
                "channels": _integer(stream.get("channels")),
                "channel_layout": stream.get("channel_layout"),
            }
            for stream in audio_streams
        ],
    }
    other_streams = {
        "attached_pic": [
            {"stream_index": _integer(stream.get("index")), "codec_name": stream.get("codec_name")}
            for stream in attached
        ],
        "subtitle": [_integer(stream.get("index")) for stream in subtitles],
        "data": [_integer(stream.get("index")) for stream in data_streams],
        "other": [_integer(stream.get("index")) for stream in other],
    }
    raw_tags = format_data.get("tags") if isinstance(format_data.get("tags"), dict) else {}
    container = {
        "format_name": format_data.get("format_name"),
        "start_time": _number(format_data.get("start_time")),
        "duration": _number(format_data.get("duration")),
        "bit_rate": _integer(format_data.get("bit_rate")),
        "tags": {
            key: str(raw_tags[key])[:512]
            for key in sorted(SAFE_CONTAINER_TAGS & set(raw_tags))
            if "\x00" not in str(raw_tags[key])
        },
    }
    return {
        "duration_ms": duration_ms,
        "video": video,
        "audio": audio,
        "other_streams": other_streams,
        "container": container,
    }
