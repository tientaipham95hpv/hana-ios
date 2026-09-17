from __future__ import annotations

import math
import os
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any, Callable, Sequence

from .contact_sheet import create_contact_sheet
from .hashing import sha256_file
from .models import PipelineError
from .paths import safe_source_path
from .probe import sanitize_stderr


FRAME_PERCENTAGES = (0, 20, 40, 60, 80, 100)
EXTRACTOR_VERSION = 1


class ExtractionError(RuntimeError):
    def __init__(self, message: str, return_code: int | None = None) -> None:
        super().__init__(message)
        self.return_code = return_code


def calculate_timestamps(duration_ms: int, fps: float | None = None) -> list[dict[str, int]]:
    if duration_ms <= 0:
        raise ValueError("duration_ms must be positive")
    frame_epsilon = max(1, math.ceil(1000 / fps)) if fps and fps > 0 else 50
    eof_safe = max(0, duration_ms - frame_epsilon)
    result = []
    for percentage in FRAME_PERCENTAGES:
        requested = int(round(duration_ms * percentage / 100))
        timestamp = min(requested, eof_safe) if percentage == 100 else min(requested, eof_safe)
        result.append({"percentage": percentage, "timestamp_ms": max(0, timestamp)})
    return result


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


def _fingerprint(video: dict[str, Any]) -> str:
    return ":".join(
        [
            str(EXTRACTOR_VERSION),
            video["sha256"],
            str(video["duration_ms"]),
            str(video["video"]["stream_index"]),
            str(video["video"].get("avg_frame_rate_fps")),
        ]
    )


def _state_is_current(output_root: Path, video: dict[str, Any], state_item: dict[str, Any] | None) -> bool:
    if not state_item or state_item.get("input_fingerprint") != _fingerprint(video):
        return False
    expected = state_item.get("outputs", {})
    if len(expected) != 7:
        return False
    for relative, digest in expected.items():
        path = output_root / Path(*relative.split("/"))
        if not path.is_file() or sha256_file(path) != digest:
            return False
    return True


def _extract_one(
    source_root: Path,
    output_root: Path,
    video: dict[str, Any],
    *,
    ffmpeg_bin: str,
    runner: Callable[[Sequence[str]], subprocess.CompletedProcess[str]],
) -> tuple[dict[str, Any], dict[str, str]]:
    source_id = video["source_id"]
    source_path = safe_source_path(source_root, video["relative_source_path"])
    timestamps = calculate_timestamps(video["duration_ms"], video["video"].get("avg_frame_rate_fps"))
    temporary_parent = output_root / ".tmp"
    temporary_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f"{source_id}.", dir=temporary_parent) as temporary_name:
        temporary = Path(temporary_name)
        temp_frames: list[Path] = []
        for frame in timestamps:
            name = f"{frame['percentage']:03d}.jpg"
            destination = temporary / name
            command = [
                ffmpeg_bin,
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-ss",
                f"{frame['timestamp_ms'] / 1000:.6f}",
                "-i",
                str(source_path),
                "-map",
                f"0:{video['video']['stream_index']}",
                "-frames:v",
                "1",
                "-an",
                "-sn",
                "-dn",
                "-map_metadata",
                "-1",
                "-q:v",
                "2",
                str(destination),
            ]
            completed = runner(command)
            if completed.returncode != 0 or not destination.is_file() or destination.stat().st_size == 0:
                raise ExtractionError(
                    sanitize_stderr(completed.stderr, source_root) or "frame output missing",
                    completed.returncode,
                )
            temp_frames.append(destination)

        temp_sheet = temporary / "contact_sheet.jpg"
        create_contact_sheet(
            temp_frames,
            timestamps,
            temp_sheet,
            source_id=source_id,
            original_filename=video["original_filename"],
            duration_ms=video["duration_ms"],
            width=video["video"]["width"],
            height=video["video"]["height"],
        )

        final_dir = output_root / "keyframes" / source_id
        final_sheet = output_root / "contact_sheets" / f"{source_id}.jpg"
        final_dir.parent.mkdir(parents=True, exist_ok=True)
        final_sheet.parent.mkdir(parents=True, exist_ok=True)
        replacement = temporary / "ready"
        replacement.mkdir()
        for frame_path in temp_frames:
            shutil.copy2(frame_path, replacement / frame_path.name)
        if final_dir.exists():
            resolved = final_dir.resolve(strict=False)
            if resolved.parent != (output_root / "keyframes").resolve(strict=False):
                raise RuntimeError("refusing unsafe keyframe replacement")
            shutil.rmtree(final_dir)
        os.replace(replacement, final_dir)
        sheet_temp = final_sheet.with_name(f".{final_sheet.name}.{os.getpid()}.tmp")
        shutil.copy2(temp_sheet, sheet_temp)
        os.replace(sheet_temp, final_sheet)

    outputs: dict[str, str] = {}
    for frame in timestamps:
        relative = f"keyframes/{source_id}/{frame['percentage']:03d}.jpg"
        outputs[relative] = sha256_file(output_root / Path(*relative.split("/")))
    sheet_relative = f"contact_sheets/{source_id}.jpg"
    outputs[sheet_relative] = sha256_file(output_root / Path(*sheet_relative.split("/")))
    return {"input_fingerprint": _fingerprint(video), "outputs": outputs}, {
        str(item["percentage"]): str(item["timestamp_ms"]) for item in timestamps
    }


def cleanup_orphans(output_root: Path, source_ids: set[str]) -> None:
    keyframes_root = output_root / "keyframes"
    if keyframes_root.is_dir():
        for item in keyframes_root.iterdir():
            if item.is_dir() and item.name.startswith("src_") and item.name not in source_ids:
                if item.resolve(strict=False).parent != keyframes_root.resolve(strict=False):
                    raise RuntimeError("refusing unsafe orphan removal")
                shutil.rmtree(item)
    sheets_root = output_root / "contact_sheets"
    if sheets_root.is_dir():
        for item in sheets_root.glob("src_*.jpg"):
            if item.stem not in source_ids:
                item.unlink()


def extract_visuals(
    source_root: Path,
    output_root: Path,
    inventory: dict[str, Any],
    *,
    previous_state: dict[str, Any] | None = None,
    ffmpeg_bin: str = "ffmpeg",
    concurrency: int = 4,
    runner: Callable[[Sequence[str]], subprocess.CompletedProcess[str]] = _run,
) -> tuple[dict[str, Any], list[dict[str, Any]], int]:
    previous_assets = (previous_state or {}).get("assets", {})
    new_assets: dict[str, Any] = {}
    errors: list[dict[str, Any]] = []
    skipped = 0
    pending: list[dict[str, Any]] = []
    for video in inventory.get("videos", []):
        source_id = video["source_id"]
        state_item = previous_assets.get(source_id)
        if _state_is_current(output_root, video, state_item):
            new_assets[source_id] = state_item
            skipped += 1
        else:
            pending.append(video)

    def run_one(video: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        state_item, timestamps = _extract_one(
            source_root,
            output_root,
            video,
            ffmpeg_bin=ffmpeg_bin,
            runner=runner,
        )
        state_item["timestamps_ms"] = timestamps
        return video["source_id"], state_item

    with ThreadPoolExecutor(max_workers=max(1, min(int(concurrency), 8))) as executor:
        future_map = {executor.submit(run_one, video): video for video in pending}
        for future in as_completed(future_map):
            video = future_map[future]
            try:
                source_id, state_item = future.result()
                new_assets[source_id] = state_item
            except Exception as exc:
                category = "ffmpeg_extract" if isinstance(exc, ExtractionError) else "visual_extraction"
                errors.append(
                    PipelineError(
                        category=category,
                        relative_source_path=video["relative_source_path"],
                        source_id=video["source_id"],
                        return_code=exc.return_code if isinstance(exc, ExtractionError) else None,
                        message=f"{type(exc).__name__}: {str(exc)[:4000]}",
                    ).to_dict()
                )
                old = previous_assets.get(video["source_id"])
                if _state_is_current(output_root, video, old):
                    new_assets[video["source_id"]] = old

    current_ids = {video["source_id"] for video in inventory.get("videos", [])}
    cleanup_orphans(output_root, current_ids)
    errors.sort(key=lambda item: ((item.get("relative_source_path") or "").casefold(), item.get("category") or ""))
    state = {
        "schema_version": 1,
        "extractor_version": EXTRACTOR_VERSION,
        "assets": dict(sorted(new_assets.items())),
    }
    return state, errors, skipped
