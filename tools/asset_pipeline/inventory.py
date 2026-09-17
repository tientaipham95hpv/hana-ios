from __future__ import annotations

import json
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any, Callable

from .io_utils import csv_text
from .models import PipelineError
from .paths import VIDEO_EXTENSIONS, assign_source_ids, safe_source_path
from .probe import PROBE_VERSION, ProbeError, parse_ffprobe, run_ffprobe, sanitize_stderr


INVENTORY_SCHEMA_VERSION = 1
CSV_FIELDS = [
    "source_id",
    "relative_source_path",
    "original_filename",
    "extension",
    "bytes",
    "sha256",
    "duration_ms",
    "video_stream_index",
    "codec_name",
    "profile",
    "level",
    "width",
    "height",
    "sample_aspect_ratio",
    "display_aspect_ratio",
    "pix_fmt",
    "avg_frame_rate",
    "fps",
    "r_frame_rate",
    "frame_count",
    "frame_count_source",
    "video_bit_rate",
    "rotation",
    "color",
    "audio_stream_count",
    "audio_streams",
    "attached_pic_streams",
    "subtitle_streams",
    "data_streams",
    "other_streams",
    "format_name",
    "container_start_time",
    "container_duration",
    "container_bit_rate",
    "container_tags",
]


def _previous_records(previous: dict[str, Any] | None) -> dict[tuple[str, str], dict[str, Any]]:
    if not previous or previous.get("schema_version") != INVENTORY_SCHEMA_VERSION:
        return {}
    return {
        (item.get("relative_source_path"), item.get("sha256")): item
        for item in previous.get("videos", [])
        if isinstance(item, dict)
    }


def _summary(video_files: list[dict[str, Any]], videos: list[dict[str, Any]], errors: list[dict[str, Any]]) -> dict[str, Any]:
    resolutions = Counter(f"{item['video']['width']}x{item['video']['height']}" for item in videos)
    codecs = Counter(str(item["video"].get("codec_name")) for item in videos)
    fps = Counter(str(item["video"].get("avg_frame_rate_fps")) for item in videos)
    audio_counts = Counter(str(item["audio"].get("stream_count")) for item in videos)
    return {
        "source_video_count": len(video_files),
        "inventory_success_count": len(videos),
        "inventory_failure_count": len(errors),
        "total_bytes": sum(item["bytes"] for item in video_files),
        "resolution_groups": dict(sorted(resolutions.items())),
        "codec_groups": dict(sorted(codecs.items())),
        "fps_groups": dict(sorted(fps.items())),
        "audio_stream_count_groups": dict(sorted(audio_counts.items())),
        "attached_picture_count": sum(len(item["other_streams"]["attached_pic"]) for item in videos),
    }


def build_inventory(
    source_root: Path,
    snapshot: dict[str, Any],
    *,
    previous: dict[str, Any] | None = None,
    ffprobe_bin: str = "ffprobe",
    concurrency: int = 4,
    probe_func: Callable[[Path], dict[str, Any]] | None = None,
) -> tuple[dict[str, Any], list[dict[str, Any]], int]:
    source_root = source_root.resolve(strict=True)
    all_snapshot_files = snapshot.get("files", [])
    video_files = [
        item for item in all_snapshot_files if Path(item["relative_path"]).suffix.casefold() in VIDEO_EXTENSIONS
    ]
    video_files.sort(key=lambda item: (item["relative_path"].casefold(), item["relative_path"]))
    source_ids = assign_source_ids((item["relative_path"], item["sha256"]) for item in video_files)
    previous_map = _previous_records(previous)
    results: dict[str, dict[str, Any]] = {}
    errors: list[dict[str, Any]] = []
    reused = 0

    pending: list[tuple[dict[str, Any], str]] = []
    for item in video_files:
        relative = item["relative_path"]
        source_id = source_ids[relative]
        cached = previous_map.get((relative, item["sha256"]))
        if cached and cached.get("probe_version") == PROBE_VERSION and cached.get("source_id") == source_id:
            results[relative] = cached
            reused += 1
        else:
            pending.append((item, source_id))

    def probe_one(item: dict[str, Any], source_id: str) -> dict[str, Any]:
        relative = item["relative_path"]
        path = safe_source_path(source_root, relative)
        payload = probe_func(path) if probe_func else run_ffprobe(path, ffprobe_bin=ffprobe_bin)
        parsed = parse_ffprobe(payload)
        return {
            "source_id": source_id,
            "relative_source_path": relative,
            "original_filename": Path(relative).name,
            "extension": Path(relative).suffix.lower(),
            "bytes": item["bytes"],
            "sha256": item["sha256"],
            "probe_version": PROBE_VERSION,
            **parsed,
        }

    with ThreadPoolExecutor(max_workers=max(1, min(int(concurrency), 8))) as executor:
        future_map = {
            executor.submit(probe_one, item, source_id): (item, source_id) for item, source_id in pending
        }
        for future in as_completed(future_map):
            item, source_id = future_map[future]
            relative = item["relative_path"]
            try:
                results[relative] = future.result()
            except ProbeError as exc:
                errors.append(
                    PipelineError(
                        category="ffprobe",
                        relative_source_path=relative,
                        source_id=source_id,
                        return_code=exc.return_code,
                        message=sanitize_stderr(exc.stderr, source_root) or str(exc),
                    ).to_dict()
                )
            except Exception as exc:  # isolate malformed/unreadable files
                errors.append(
                    PipelineError(
                        category="inventory",
                        relative_source_path=relative,
                        source_id=source_id,
                        return_code=None,
                        message=f"{type(exc).__name__}: {str(exc)[:1000]}",
                    ).to_dict()
                )

    videos = [results[key] for key in sorted(results, key=lambda value: (value.casefold(), value))]
    errors.sort(key=lambda item: ((item.get("relative_source_path") or "").casefold(), item.get("category") or ""))
    inventory = {
        "schema_version": INVENTORY_SCHEMA_VERSION,
        "probe_version": PROBE_VERSION,
        "source_root": "assets_source",
        "summary": _summary(video_files, videos, errors),
        "videos": videos,
        "errors": errors,
    }
    return inventory, errors, reused


def inventory_csv(inventory: dict[str, Any]) -> str:
    rows: list[dict[str, Any]] = []
    for item in inventory.get("videos", []):
        video = item["video"]
        audio = item["audio"]
        other = item["other_streams"]
        container = item["container"]
        rows.append(
            {
                "source_id": item["source_id"],
                "relative_source_path": item["relative_source_path"],
                "original_filename": item["original_filename"],
                "extension": item["extension"],
                "bytes": item["bytes"],
                "sha256": item["sha256"],
                "duration_ms": item["duration_ms"],
                "video_stream_index": video.get("stream_index"),
                "codec_name": video.get("codec_name"),
                "profile": video.get("profile"),
                "level": video.get("level"),
                "width": video.get("width"),
                "height": video.get("height"),
                "sample_aspect_ratio": video.get("sample_aspect_ratio"),
                "display_aspect_ratio": video.get("display_aspect_ratio"),
                "pix_fmt": video.get("pix_fmt"),
                "avg_frame_rate": video.get("avg_frame_rate"),
                "fps": video.get("avg_frame_rate_fps"),
                "r_frame_rate": video.get("r_frame_rate"),
                "frame_count": video.get("frame_count"),
                "frame_count_source": video.get("frame_count_source"),
                "video_bit_rate": video.get("bit_rate"),
                "rotation": video.get("rotation"),
                "color": json.dumps(video.get("color", {}), ensure_ascii=False, sort_keys=True),
                "audio_stream_count": audio.get("stream_count"),
                "audio_streams": json.dumps(audio.get("streams", []), ensure_ascii=False, sort_keys=True),
                "attached_pic_streams": json.dumps(other.get("attached_pic", []), sort_keys=True),
                "subtitle_streams": json.dumps(other.get("subtitle", [])),
                "data_streams": json.dumps(other.get("data", [])),
                "other_streams": json.dumps(other.get("other", [])),
                "format_name": container.get("format_name"),
                "container_start_time": container.get("start_time"),
                "container_duration": container.get("duration"),
                "container_bit_rate": container.get("bit_rate"),
                "container_tags": json.dumps(container.get("tags", {}), ensure_ascii=False, sort_keys=True),
            }
        )
    return csv_text(CSV_FIELDS, rows)
