from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from hashlib import sha256
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterable, Sequence

from .hashing import sha256_file
from .integrity import capture_snapshot, compare_snapshots
from .io_utils import atomic_write_text, canonical_json_text, read_json, write_json
from .paths import (
    UnsafePathError,
    ensure_output_outside_source,
    safe_source_path,
    validate_relative_portable,
)
from .phase4_policy import (
    CORE_STATES,
    CUE_REGISTRY,
    DELIVERIES,
    EXPECTED_REVIEW_IDS,
    LOOP_GRADES,
    MANIFEST_VERSION_PREFIX,
    POOR_IDS,
    QUALITY_VALUES,
    SCHEMA_VERSION,
    SEED_POLICY,
    SENSITIVITIES,
    STAGE_CONTEXTS,
    delivery_for,
)
from .probe import ProbeError, rate_to_float, run_ffprobe, sanitize_stderr


class Phase4Failure(RuntimeError):
    pass


Runner = Callable[[Sequence[str]], subprocess.CompletedProcess[str]]
SOURCE_NAME_RE = re.compile(r"[A-Z]{4}\d{4}(?:\.MP4)?")
ASSET_ID_RE = re.compile(r"^chr_\d{3}$")
RUNTIME_PATH_RE = re.compile(
    r"^(bundle|vault|private_vault)/chr_\d{3}(?:\.poster|\.blur)?\.(?:mp4|jpg)$"
)
TRANSCODE_PROFILE = "h264-high-l4-crf20-slow-gop12-yuv420p-24fps-v1"
RUNTIME_FIELDS = (
    "asset_id",
    "delivery",
    "content_sensitivity",
    "allowed_modes",
    "technical_quality",
    "review_flag",
    "excluded_by_default",
    "states",
    "cues",
    "kind",
    "loop_quality",
    "path",
    "poster",
    "poster_blur",
    "duration_ms",
    "width",
    "height",
    "render_mode",
    "focal_x",
    "focal_y",
    "intensity_tags",
    "weight",
    "audio_streams",
    "sha256",
    "bytes",
)


def _run_process(command: Sequence[str]) -> subprocess.CompletedProcess[str]:
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


def _load_json_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise Phase4Failure(f"cannot read JSON object {path.name}: {type(exc).__name__}") from exc
    if not isinstance(value, dict):
        raise Phase4Failure(f"JSON root must be an object: {path.name}")
    return value


def _load_json_array(path: Path) -> list[dict[str, Any]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise Phase4Failure(f"cannot read JSON array {path.name}: {type(exc).__name__}") from exc
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise Phase4Failure(f"JSON root must be an array of objects: {path.name}")
    return value


def _stable_timestamp(snapshot: dict[str, Any]) -> str:
    values = [int(item["mtime_ns"]) for item in snapshot.get("files", [])]
    if not values:
        raise Phase4Failure("source snapshot is empty")
    return datetime.fromtimestamp(max(values) / 1_000_000_000, tz=timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )


def _hash_json(value: Any) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return sha256(payload.encode("utf-8")).hexdigest()


def _ffmpeg_identity(ffmpeg_bin: str, runner: Runner = _run_process) -> str:
    try:
        completed = runner([ffmpeg_bin, "-version"])
    except OSError as exc:
        raise Phase4Failure(f"ffmpeg could not start: {type(exc).__name__}") from exc
    if completed.returncode != 0:
        raise Phase4Failure("ffmpeg -version failed")
    return (completed.stdout.splitlines() or ["unknown"])[0].strip()


def validate_roots(source_root: Path, analysis_root: Path, output_root: Path) -> None:
    if not source_root.is_dir() or source_root.is_symlink():
        raise Phase4Failure("assets_source must be an existing non-symlink directory")
    if not analysis_root.is_dir() or analysis_root.is_symlink():
        raise Phase4Failure("asset_analysis must be an existing non-symlink directory")
    ensure_output_outside_source(source_root, output_root)
    source = source_root.resolve(strict=True)
    analysis = analysis_root.resolve(strict=True)
    output = output_root.resolve(strict=False)
    if output == analysis or analysis in output.parents:
        raise Phase4Failure("production output must be outside asset_analysis")
    if output == source or source in output.parents:
        raise Phase4Failure("production output must be outside assets_source")


def _quality(classification: dict[str, Any]) -> str:
    if classification.get("decision") == "reject":
        return "poor"
    motion = classification.get("motion_intensity")
    if classification.get("face_consistency") == "minor_issue" or (
        isinstance(motion, (int, float)) and motion >= 0.70
    ):
        return "fair"
    return "good"


def _weight(decision: str, quality: str) -> float:
    if decision == "reject":
        return 0.2
    if decision == "review":
        return 0.4 if quality == "fair" else 0.5
    return 0.8 if quality == "fair" else 1.0


def build_policy_records(
    source_root: Path,
    analysis_root: Path,
    snapshot: dict[str, Any],
    *,
    strict_count: bool = True,
) -> list[dict[str, Any]]:
    inventory = _load_json_object(analysis_root / "inventory.json")
    visual_index = _load_json_object(analysis_root / "visual_index.json")
    classifications = _load_json_array(analysis_root / "classification.json")
    _load_json_object(analysis_root / "duplicates.json")

    inventory_items = inventory.get("videos")
    visual_items = visual_index.get("records")
    if not isinstance(inventory_items, list) or not isinstance(visual_items, list):
        raise Phase4Failure("inventory or visual index records are invalid")
    by_filename = {item.get("original_filename"): item for item in inventory_items}
    by_class_name = {item.get("source_filename"): item for item in classifications}
    visual_names = {item.get("source_filename") for item in visual_items}
    snapshot_map = {item["relative_path"]: item for item in snapshot.get("files", [])}
    expected_names = set(SEED_POLICY)
    if set(by_filename) != expected_names or set(by_class_name) != expected_names or visual_names != expected_names:
        raise Phase4Failure("Phase 2/3 inputs do not match the canonical 43-file Phase 3.2 seed")
    if strict_count and len(expected_names) != 43:
        raise Phase4Failure("canonical Phase 3.2 seed must contain exactly 43 assets")

    records: list[dict[str, Any]] = []
    for number, filename in enumerate(sorted(expected_names, key=lambda value: (value.casefold(), value)), 1):
        asset_id = f"chr_{number:03d}"
        inv = by_filename[filename]
        cls = by_class_name[filename]
        if cls.get("source_id") != inv.get("source_id"):
            raise Phase4Failure(f"source_id mismatch for {asset_id}")
        relative = inv.get("relative_source_path")
        if not isinstance(relative, str) or relative not in snapshot_map:
            raise Phase4Failure(f"source snapshot entry missing for {asset_id}")
        source_path = safe_source_path(source_root, relative)
        snapshot_item = snapshot_map[relative]
        if inv.get("sha256") != snapshot_item.get("sha256") or inv.get("bytes") != snapshot_item.get("bytes"):
            raise Phase4Failure(f"inventory fingerprint mismatch for {asset_id}")
        video = inv.get("video") or {}
        width, height = video.get("width"), video.get("height")
        group_a = (width, height) == (544, 544)
        sensitivity = "suggestive" if group_a else "private"
        allowed_modes = list(STAGE_CONTEXTS) if group_a else ["relationship", "private"]
        quality = _quality(cls)
        decision = cls.get("decision")
        policy = SEED_POLICY[filename]
        states = dict(policy.get("states", {}))
        cues = list(policy.get("cues", []))
        kind = "oneshot" if decision == "reject" else cls.get("playback_kind")
        record = {
            "asset_id": asset_id,
            "source_file": filename,
            "relative_source_path": relative,
            "source_id": inv.get("source_id"),
            "source_sha256": inv.get("sha256"),
            "source_bytes": inv.get("bytes"),
            "source_path": source_path,
            "main_stream_index": video.get("stream_index"),
            "source_duration_ms": inv.get("duration_ms"),
            "source_width": width,
            "source_height": height,
            "content_sensitivity": sensitivity,
            "sensitivity_source": "phase3_group_provisional" if group_a else "phase3",
            "needs_visual_confirmation": group_a,
            "allowed_modes": allowed_modes,
            "delivery": delivery_for(sensitivity, allowed_modes),
            "technical_quality": quality,
            "review_flag": decision == "review",
            "excluded_by_default": decision == "reject",
            "hard_block": False,
            "states": states,
            "state_mapping_status": "provisional",
            "cues": cues,
            "intensity_tags": [],
            "kind": kind,
            "loop_quality": "seamless" if cls.get("loop_grade") == "A" else "crossfade",
            "loop_grade": cls.get("loop_grade"),
            "start_end_match": cls.get("start_end_match"),
            "motion_intensity": cls.get("motion_intensity"),
            "render_mode": "contain_blur" if group_a else "cover",
            "focal_x": 0.5,
            "focal_y": 0.5,
            "weight": _weight(str(decision), quality),
            "trim_start_ms": 0,
            "trim_end_ms": 0,
            "interruptible": True,
            "cooldown_seconds": 0,
        }
        records.append(record)

    ids = {item["asset_id"] for item in records}
    if ids != {f"chr_{number:03d}" for number in range(1, 44)}:
        raise Phase4Failure("asset IDs are not the canonical chr_001..chr_043 set")
    if {item["asset_id"] for item in records if item["review_flag"]} != EXPECTED_REVIEW_IDS:
        raise Phase4Failure("review flags differ from Phase 3.2")
    if {item["asset_id"] for item in records if item["technical_quality"] == "poor"} != POOR_IDS:
        raise Phase4Failure("poor-quality assets differ from Phase 3.2")
    if Counter(item["content_sensitivity"] for item in records) != Counter(
        {"suggestive": 17, "private": 26}
    ):
        raise Phase4Failure("sensitivity distribution differs from Phase 3.2")
    return records


def labels_document(records: list[dict[str, Any]]) -> dict[str, Any]:
    assets = []
    for item in records:
        assets.append(
            {
                "asset_id": item["asset_id"],
                "source_file": item["source_file"],
                "source_sha256": item["source_sha256"],
                "content_sensitivity": item["content_sensitivity"],
                "sensitivity_source": item["sensitivity_source"],
                "allowed_modes": item["allowed_modes"],
                "hard_block": item["hard_block"],
                "technical_quality": item["technical_quality"],
                "review_flag": item["review_flag"],
                "excluded_by_default": item["excluded_by_default"],
                "states": item["states"],
                "state_mapping_status": item["state_mapping_status"],
                "cues": item["cues"],
                "intensity_tags": item["intensity_tags"],
                "kind": item["kind"],
                "loop_quality": item["loop_quality"],
                "trim_start_ms": item["trim_start_ms"],
                "trim_end_ms": item["trim_end_ms"],
                "render_mode": item["render_mode"],
                "focal_x": item["focal_x"],
                "focal_y": item["focal_y"],
                "weight": item["weight"],
                "notes": "Phase 3.2 canonical seed; state/cue mapping remains provisional.",
            }
        )
    return {"version": 2, "assets": assets, "cues": CUE_REGISTRY}


def source_asset_map_document(records: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "development_only": True,
        "ship_to_client": False,
        "assets": [
            {
                "source_id": item["source_id"],
                "source_filename": item["source_file"],
                "source_sha256": item["source_sha256"],
                "asset_id": item["asset_id"],
            }
            for item in records
        ],
    }


def asset_registry_document(records: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "assets": [
            {"asset_id": item["asset_id"], "source_sha256": item["source_sha256"]}
            for item in records
        ],
        "retired_ids": [],
    }


def _safe_output_path(output_root: Path, relative: str) -> Path:
    validate_relative_portable(relative)
    root = output_root.resolve(strict=False)
    candidate = root.joinpath(*PurePosixPath(relative).parts)
    # validate_relative_portable already rejects absolute paths and '..'.  Keep
    # the containment check lexical here: Path.resolve() can transiently report
    # an incomplete path on Windows while sibling workers create the same parent.
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise UnsafePathError(f"output path escapes root: {relative}") from exc
    current = root
    for part in PurePosixPath(relative).parts:
        current = current / part
        if current.exists() and current.is_symlink():
            raise UnsafePathError(f"output symlink is not allowed: {relative}")
    return candidate


def _media_relatives(item: dict[str, Any]) -> tuple[str, str, str]:
    prefix = item["delivery"]
    asset_id = item["asset_id"]
    return (
        f"{prefix}/{asset_id}.mp4",
        f"{prefix}/{asset_id}.poster.jpg",
        f"{prefix}/{asset_id}.blur.jpg",
    )


def _transcode_commands(
    item: dict[str, Any], ffmpeg_bin: str, video_temp: Path, poster_temp: Path, blur_temp: Path
) -> list[list[str]]:
    source = str(item["source_path"])
    stream = str(item["main_stream_index"])
    common = [ffmpeg_bin, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", source]
    video = common + [
        "-map", f"0:{stream}", "-an", "-sn", "-dn", "-map_metadata", "-1", "-map_chapters", "-1",
        "-vf", "scale='min(iw,1280)':'min(ih,1280)':force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p",
        "-c:v", "libx264", "-profile:v", "high", "-level:v", "4.0", "-preset", "slow", "-crf", "20",
        "-r", "24", "-g", "12", "-keyint_min", "12", "-sc_threshold", "0", "-threads", "1",
        "-movflags", "+faststart", str(video_temp),
    ]
    poster = common + [
        "-map", f"0:{stream}", "-an", "-sn", "-dn", "-map_metadata", "-1", "-map_chapters", "-1",
        "-frames:v", "1", "-q:v", "3", str(poster_temp),
    ]
    blur = common + [
        "-map", f"0:{stream}", "-an", "-sn", "-dn", "-map_metadata", "-1", "-map_chapters", "-1",
        "-vf", "scale=trunc(iw/4/2)*2:trunc(ih/4/2)*2,gblur=sigma=20", "-frames:v", "1", "-q:v", "3",
        str(blur_temp),
    ]
    return [video, poster, blur]


def _probe_media(path: Path, ffprobe_bin: str = "ffprobe") -> dict[str, Any]:
    payload = run_ffprobe(path, ffprobe_bin=ffprobe_bin)
    streams = payload.get("streams")
    if not isinstance(streams, list) or not all(isinstance(stream, dict) for stream in streams):
        raise Phase4Failure(f"malformed ffprobe streams for {path.name}")
    video_streams = [stream for stream in streams if stream.get("codec_type") == "video"]
    audio = [stream for stream in streams if stream.get("codec_type") == "audio"]
    subtitle = [stream for stream in streams if stream.get("codec_type") == "subtitle"]
    data = [stream for stream in streams if stream.get("codec_type") == "data"]
    attached = [
        stream
        for stream in video_streams
        if int((stream.get("disposition") or {}).get("attached_pic") or 0) == 1
    ]
    main = [stream for stream in video_streams if stream not in attached]
    if len(streams) != 1 or len(main) != 1 or audio or subtitle or data or attached:
        raise Phase4Failure(f"media stream invariant failed for {path.name}")
    stream = main[0]
    format_data = payload.get("format") or {}
    try:
        duration_ms = round(float(stream.get("duration") or format_data.get("duration")) * 1000)
    except (TypeError, ValueError, OverflowError) as exc:
        raise Phase4Failure(f"invalid duration for {path.name}") from exc
    return {
        "codec_name": stream.get("codec_name"),
        "pix_fmt": stream.get("pix_fmt"),
        "width": int(stream.get("width")),
        "height": int(stream.get("height")),
        "fps": rate_to_float(stream.get("avg_frame_rate")),
        "duration_ms": duration_ms,
        "stream_count": len(streams),
        "audio_streams": len(audio),
        "attached_picture_streams": len(attached),
        "subtitle_streams": len(subtitle),
        "data_streams": len(data),
    }


def _has_faststart(path: Path) -> bool:
    """Return true when the MP4 moov atom precedes the first mdat atom."""
    moov_offset: int | None = None
    mdat_offset: int | None = None
    file_size = path.stat().st_size
    offset = 0
    with path.open("rb") as handle:
        while offset + 8 <= file_size:
            handle.seek(offset)
            header = handle.read(16)
            if len(header) < 8:
                break
            atom_size = int.from_bytes(header[0:4], "big")
            atom_type = header[4:8]
            header_size = 8
            if atom_size == 1:
                if len(header) < 16:
                    return False
                atom_size = int.from_bytes(header[8:16], "big")
                header_size = 16
            elif atom_size == 0:
                atom_size = file_size - offset
            if atom_size < header_size or offset + atom_size > file_size:
                return False
            if atom_type == b"moov" and moov_offset is None:
                moov_offset = offset
            elif atom_type == b"mdat" and mdat_offset is None:
                mdat_offset = offset
            if moov_offset is not None and mdat_offset is not None:
                return moov_offset < mdat_offset
            offset += atom_size
    return False


def verify_media_file(
    path: Path,
    *,
    expected_duration_ms: int | None = None,
    expected_sha256: str | None = None,
    ffprobe_bin: str = "ffprobe",
) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise Phase4Failure(f"media file missing or unsafe: {path.name}")
    probe = _probe_media(path, ffprobe_bin)
    if probe["codec_name"] != "h264" or probe["pix_fmt"] != "yuv420p":
        raise Phase4Failure(f"codec/pixel format invariant failed for {path.name}")
    if probe["fps"] is None or abs(probe["fps"] - 24.0) > 0.01:
        raise Phase4Failure(f"fps invariant failed for {path.name}")
    if expected_duration_ms is not None and abs(probe["duration_ms"] - expected_duration_ms) > 50:
        raise Phase4Failure(f"duration invariant failed for {path.name}")
    if not _has_faststart(path):
        raise Phase4Failure(f"faststart invariant failed for {path.name}")
    digest = sha256_file(path)
    if expected_sha256 is not None and digest != expected_sha256:
        raise Phase4Failure(f"sha256 mismatch for {path.name}")
    probe.update({"sha256": digest, "bytes": path.stat().st_size, "faststart": True})
    return probe


def _state_entry_valid(
    state_entry: dict[str, Any], input_fingerprint: str, output_root: Path, ffprobe_bin: str
) -> dict[str, Any] | None:
    if state_entry.get("input_fingerprint") != input_fingerprint:
        return None
    outputs = state_entry.get("outputs")
    if not isinstance(outputs, dict):
        return None
    try:
        video = outputs["video"]
        poster = outputs["poster"]
        blur = outputs["poster_blur"]
        video_path = _safe_output_path(output_root, video["path"])
        verified = verify_media_file(
            video_path,
            expected_duration_ms=int(state_entry["expected_duration_ms"]),
            expected_sha256=video["sha256"],
            ffprobe_bin=ffprobe_bin,
        )
        for image_item in (poster, blur):
            image_path = _safe_output_path(output_root, image_item["path"])
            if not image_path.is_file() or image_path.is_symlink():
                return None
            if sha256_file(image_path) != image_item["sha256"]:
                return None
    except (KeyError, TypeError, ValueError, OSError, Phase4Failure, ProbeError, UnsafePathError):
        return None
    return verified


def transcode_asset(
    item: dict[str, Any],
    output_root: Path,
    *,
    input_fingerprint: str,
    previous_state: dict[str, Any] | None,
    ffmpeg_bin: str = "ffmpeg",
    ffprobe_bin: str = "ffprobe",
    runner: Runner = _run_process,
) -> tuple[dict[str, Any], bool]:
    if previous_state:
        reused = _state_entry_valid(previous_state, input_fingerprint, output_root, ffprobe_bin)
        if reused is not None:
            return previous_state, True

    video_relative, poster_relative, blur_relative = _media_relatives(item)
    destinations = [
        _safe_output_path(output_root, video_relative),
        _safe_output_path(output_root, poster_relative),
        _safe_output_path(output_root, blur_relative),
    ]
    for destination in destinations:
        destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = [
        destination.with_name(f".{destination.stem}.{os.getpid()}.phase4.tmp{destination.suffix}")
        for destination in destinations
    ]
    commands = _transcode_commands(item, ffmpeg_bin, *temporary)
    try:
        for command in commands:
            try:
                completed = runner(command)
            except OSError as exc:
                raise Phase4Failure(f"ffmpeg could not start for {item['asset_id']}: {type(exc).__name__}") from exc
            if completed.returncode != 0:
                detail = sanitize_stderr(completed.stderr, item["source_path"].parent)
                raise Phase4Failure(
                    f"ffmpeg failed for {item['asset_id']} (exit {completed.returncode}): {detail}"
                )
        verified = verify_media_file(
            temporary[0], expected_duration_ms=item["source_duration_ms"], ffprobe_bin=ffprobe_bin
        )
        for source_temp, destination in zip(temporary, destinations):
            os.replace(source_temp, destination)
    finally:
        for path in temporary:
            path.unlink(missing_ok=True)

    state = {
        "input_fingerprint": input_fingerprint,
        "expected_duration_ms": item["source_duration_ms"],
        "outputs": {
            "video": {
                "path": video_relative,
                "sha256": verified["sha256"],
                "bytes": verified["bytes"],
            },
            "poster": {
                "path": poster_relative,
                "sha256": sha256_file(destinations[1]),
                "bytes": destinations[1].stat().st_size,
            },
            "poster_blur": {
                "path": blur_relative,
                "sha256": sha256_file(destinations[2]),
                "bytes": destinations[2].stat().st_size,
            },
        },
        "media": verified,
    }
    return state, False


def _master_asset(item: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    video = state["outputs"]["video"]
    media = state["media"]
    width, height = media["width"], media["height"]
    return {
        "asset_id": item["asset_id"],
        "delivery": item["delivery"],
        "content_sensitivity": item["content_sensitivity"],
        "allowed_modes": item["allowed_modes"],
        "technical_quality": item["technical_quality"],
        "review_flag": item["review_flag"],
        "needs_visual_confirmation": item["needs_visual_confirmation"],
        "excluded_by_default": item["excluded_by_default"],
        "states": item["states"],
        "state_mapping_status": item["state_mapping_status"],
        "cues": item["cues"],
        "semantic_tags": [],
        "kind": item["kind"],
        "loop_quality": item["loop_quality"],
        "loop_grade": item["loop_grade"],
        "start_end_match": item["start_end_match"],
        "motion_intensity": item["motion_intensity"],
        "intensity_tags": item["intensity_tags"],
        "weight": item["weight"],
        "interruptible": item["interruptible"],
        "cooldown_seconds": item["cooldown_seconds"],
        "render_mode": item["render_mode"],
        "focal_x": item["focal_x"],
        "focal_y": item["focal_y"],
        "duration_ms": media["duration_ms"],
        "width": width,
        "height": height,
        "aspect_ratio": round(width / height, 6),
        "fps": media["fps"],
        "path": video["path"],
        "poster": state["outputs"]["poster"]["path"],
        "poster_blur": state["outputs"]["poster_blur"]["path"],
        "audio_streams": media["audio_streams"],
        "attached_picture_streams": media["attached_picture_streams"],
        "subtitle_streams": media["subtitle_streams"],
        "data_streams": media["data_streams"],
        "sha256": video["sha256"],
        "bytes": video["bytes"],
    }


def _runtime_asset(master_asset: dict[str, Any]) -> dict[str, Any]:
    return {field: master_asset[field] for field in RUNTIME_FIELDS}


def _manifest_header(kind: str, version: str, generated_at: str) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "manifest_kind": kind,
        "manifest_version": version,
        "generated_at": generated_at,
        "cue_registry": CUE_REGISTRY,
    }


def build_manifests(
    records: list[dict[str, Any]],
    states: dict[str, dict[str, Any]],
    snapshot: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    version_input = [
        {
            "asset_id": item["asset_id"],
            "source_sha256": item["source_sha256"],
            "policy": {
                key: item[key]
                for key in (
                    "content_sensitivity", "allowed_modes", "technical_quality", "review_flag",
                    "excluded_by_default", "states", "cues", "kind", "loop_quality", "weight",
                    "render_mode", "focal_x", "focal_y",
                )
            },
            "output_sha256": states[item["asset_id"]]["outputs"]["video"]["sha256"],
        }
        for item in records
    ]
    version = f"{MANIFEST_VERSION_PREFIX}-{_hash_json(version_input)[:16]}"
    generated_at = _stable_timestamp(snapshot)
    assets = [_master_asset(item, states[item["asset_id"]]) for item in records]
    master = _manifest_header("master", version, generated_at)
    master["assets"] = assets
    manifests: dict[str, dict[str, Any]] = {"character_manifest.json": master}
    for delivery in DELIVERIES:
        document = _manifest_header(delivery, version, generated_at)
        document["assets"] = [
            _runtime_asset(asset) for asset in assets if asset["delivery"] == delivery
        ]
        manifests[f"{delivery}_manifest.json"] = document

    view_specs = {
        "daily_assistant_manifest.json": ({"daily", "assistant"}, None),
        "relationship_manifest.json": ({"relationship"}, "relationship_stage_enabled"),
        "private_manifest.json": ({"private"}, "private_session"),
    }
    for name, (contexts, requirement) in view_specs.items():
        document = _manifest_header("derived_view", version, generated_at)
        document["view_contexts"] = sorted(contexts)
        if requirement:
            document["required_runtime_condition"] = requirement
        document["assets"] = [
            _runtime_asset(asset)
            for asset in assets
            if not asset["excluded_by_default"] and contexts.intersection(asset["allowed_modes"])
        ]
        manifests[name] = document
    return manifests


def _counter(values: Iterable[Any]) -> dict[str, int]:
    return dict(sorted(Counter(values).items(), key=lambda item: str(item[0])))


def _mode_counts(assets: list[dict[str, Any]], *, enabled_only: bool) -> dict[str, int]:
    return {
        mode: sum(
            mode in asset["allowed_modes"]
            and (not enabled_only or not asset["excluded_by_default"])
            for asset in assets
        )
        for mode in STAGE_CONTEXTS
    }


def coverage_report(assets: list[dict[str, Any]]) -> dict[str, Any]:
    contexts: dict[str, Any] = {}
    for context in STAGE_CONTEXTS:
        states: dict[str, Any] = {}
        for state in CORE_STATES:
            pool = [
                asset
                for asset in assets
                if not asset["excluded_by_default"]
                and context in asset["allowed_modes"]
                and state in asset["states"]
            ]
            primary = sum(asset["states"][state] == "primary" for asset in pool)
            shared = sum(asset["states"][state] == "shared" for asset in pool)
            main_loop = sum(
                asset["kind"] == "loop"
                and not asset["review_flag"]
                and asset["technical_quality"] != "poor"
                for asset in pool
            )
            states[state] = {
                "candidates": len(pool),
                "primary": primary,
                "shared": shared,
                "main_loop": main_loop,
                "gap": len(pool) == 0,
            }
        contexts[context] = states
    return {
        "schema_version": 1,
        "coverage_is_build_blocking": False,
        "contexts": contexts,
        "known_daily_fallback_gaps": ["surprised", "concerned", "working", "sleep"],
        "fallback_chain": ["requested_state", "idle_pool", "daily_pool", "poster", "silhouette"],
        "never_borrow_disallowed_mode": True,
    }


def validate_manifest_document(document: dict[str, Any], *, master: bool = False) -> None:
    assets = document.get("assets")
    if not isinstance(assets, list):
        raise Phase4Failure("manifest assets must be an array")
    seen: set[str] = set()
    for asset in assets:
        if not isinstance(asset, dict):
            raise Phase4Failure("manifest asset must be an object")
        asset_id = asset.get("asset_id")
        if not isinstance(asset_id, str) or not ASSET_ID_RE.fullmatch(asset_id) or asset_id in seen:
            raise Phase4Failure("manifest contains an invalid or duplicate asset_id")
        seen.add(asset_id)
        if asset.get("content_sensitivity") not in SENSITIVITIES:
            raise Phase4Failure(f"invalid sensitivity for {asset_id}")
        modes = asset.get("allowed_modes")
        if not isinstance(modes, list) or not modes or any(mode not in STAGE_CONTEXTS for mode in modes):
            raise Phase4Failure(f"invalid allowed_modes for {asset_id}")
        if asset.get("delivery") not in DELIVERIES:
            raise Phase4Failure(f"invalid delivery for {asset_id}")
        if asset.get("delivery") != delivery_for(asset["content_sensitivity"], modes):
            raise Phase4Failure(f"delivery derivation failed for {asset_id}")
        if asset.get("technical_quality") not in QUALITY_VALUES:
            raise Phase4Failure(f"invalid technical_quality for {asset_id}")
        if not isinstance(asset.get("weight"), (int, float)) or not 0.05 <= asset["weight"] <= 10:
            raise Phase4Failure(f"invalid weight for {asset_id}")
        states = asset.get("states")
        if not isinstance(states, dict) or not states or any(
            state not in CORE_STATES or role not in {"primary", "shared"}
            for state, role in states.items()
        ):
            raise Phase4Failure(f"invalid states for {asset_id}")
        if asset.get("kind") not in {"loop", "oneshot"}:
            raise Phase4Failure(f"invalid kind for {asset_id}")
        if master and asset.get("loop_grade") not in LOOP_GRADES:
            raise Phase4Failure(f"invalid loop grade for {asset_id}")
        for field in ("path", "poster", "poster_blur"):
            path_value = asset.get(field)
            if not isinstance(path_value, str):
                raise Phase4Failure(f"missing {field} for {asset_id}")
            validate_relative_portable(path_value)
            if not RUNTIME_PATH_RE.fullmatch(path_value):
                raise Phase4Failure(f"invalid runtime path for {asset_id}")
            if not path_value.startswith(asset["delivery"] + "/"):
                raise Phase4Failure(f"runtime path delivery mismatch for {asset_id}")
        if asset.get("audio_streams") != 0:
            raise Phase4Failure(f"audio_streams must be zero for {asset_id}")
    kind = document.get("manifest_kind")
    if kind in DELIVERIES:
        for asset in assets:
            if asset["delivery"] != kind:
                raise Phase4Failure(f"{kind} manifest contains wrong delivery")
            if kind == "bundle" and asset["content_sensitivity"] != "normal":
                raise Phase4Failure("bundle manifest contains sensitive asset")
            if kind == "vault" and (
                asset["content_sensitivity"] not in {"suggestive", "private"}
                or not set(asset["allowed_modes"]).intersection({"daily", "assistant", "relationship"})
            ):
                raise Phase4Failure("vault manifest constraint failed")
            if kind == "private_vault" and asset["allowed_modes"] != ["private"]:
                raise Phase4Failure("private_vault manifest constraint failed")


def _scan_runtime_leaks(documents: dict[str, dict[str, Any]], source_names: Iterable[str]) -> None:
    forbidden_fields = {"source_file", "source_filename", "source_id", "source_sha256", "notes", "hard_block", "sensitivity_source"}
    for name, document in documents.items():
        text = json.dumps(document, ensure_ascii=False, sort_keys=True)
        if "assets_source" in text or re.search(r"[A-Za-z]:[\\/]", text):
            raise Phase4Failure(f"source or absolute path leaked into {name}")
        if SOURCE_NAME_RE.search(text) or any(source_name in text for source_name in source_names):
            raise Phase4Failure(f"source filename leaked into {name}")
        for asset in document.get("assets", []):
            if forbidden_fields.intersection(asset):
                raise Phase4Failure(f"development-only field leaked into {name}")


def validate_library(
    output_root: Path,
    manifests: dict[str, dict[str, Any]] | None = None,
    *,
    source_names: Iterable[str] = (),
    ffprobe_bin: str = "ffprobe",
    repo_root: Path | None = None,
) -> dict[str, Any]:
    if manifests is None:
        names = (
            "character_manifest.json", "bundle_manifest.json", "vault_manifest.json",
            "private_vault_manifest.json", "daily_assistant_manifest.json",
            "relationship_manifest.json", "private_manifest.json",
        )
        manifests = {name: _load_json_object(output_root / name) for name in names}
    master = manifests["character_manifest.json"]
    validate_manifest_document(master, master=True)
    assets = master["assets"]
    expected_ids = [f"chr_{number:03d}" for number in range(1, 44)]
    if [asset["asset_id"] for asset in assets] != expected_ids:
        raise Phase4Failure("master manifest must contain ordered chr_001..chr_043")
    if len(assets) != 43:
        raise Phase4Failure("master manifest must contain exactly 43 assets")
    for name, document in manifests.items():
        validate_manifest_document(document, master=name == "character_manifest.json")
    if len(manifests["vault_manifest.json"]["assets"]) != 43:
        raise Phase4Failure("all 43 seed assets must be in the vault manifest")
    if manifests["bundle_manifest.json"]["assets"] or manifests["private_vault_manifest.json"]["assets"]:
        raise Phase4Failure("seed must contain zero bundle/private_vault videos")
    enabled = [asset for asset in assets if not asset["excluded_by_default"]]
    if len(enabled) != 41:
        raise Phase4Failure("enabled-by-default count must be 41")
    poor = {asset["asset_id"] for asset in assets if asset["technical_quality"] == "poor"}
    if poor != POOR_IDS:
        raise Phase4Failure("poor asset policy mismatch")
    for asset in assets:
        if asset["asset_id"] in POOR_IDS and not (
            asset["kind"] == "oneshot"
            and asset["weight"] == 0.2
            and asset["excluded_by_default"]
        ):
            raise Phase4Failure("poor asset exception policy mismatch")
    if {asset["asset_id"] for asset in assets if asset["review_flag"]} != EXPECTED_REVIEW_IDS:
        raise Phase4Failure("review flag preservation failed")
    expected_views = {
        "daily_assistant_manifest.json": 15,
        "relationship_manifest.json": 41,
        "private_manifest.json": 41,
    }
    for name, count in expected_views.items():
        if len(manifests[name]["assets"]) != count:
            raise Phase4Failure(f"derived view candidate discrepancy: {name}")
    _scan_runtime_leaks(manifests, source_names)

    verified = 0
    output = output_root.resolve(strict=True)
    for asset in assets:
        path = _safe_output_path(output, asset["path"])
        try:
            path.resolve(strict=True).relative_to(output)
        except (OSError, ValueError) as exc:
            raise Phase4Failure(f"asset path is outside output root: {asset['asset_id']}") from exc
        verify_media_file(
            path,
            expected_duration_ms=asset["duration_ms"],
            expected_sha256=asset["sha256"],
            ffprobe_bin=ffprobe_bin,
        )
        for field in ("poster", "poster_blur"):
            image_path = _safe_output_path(output, asset[field])
            if not image_path.is_file() or image_path.is_symlink():
                raise Phase4Failure(f"missing image for {asset['asset_id']}: {field}")
        verified += 1

    apk_video_count = 0
    if repo_root is not None:
        mobile_root = repo_root / "mobile" / "assets" / "character"
        if mobile_root.exists():
            apk_video_count = sum(
                path.suffix.casefold() in {".mp4", ".mov", ".m4v", ".webm"}
                for path in mobile_root.rglob("*")
                if path.is_file()
            )
        if apk_video_count:
            raise Phase4Failure("APK character assets contain video despite the zero-video seed invariant")
    return {
        "status": "PASS",
        "media_verified": verified,
        "master_assets": len(assets),
        "enabled_by_default": len(enabled),
        "excluded_by_default": len(assets) - len(enabled),
        "review_assets": sum(asset["review_flag"] for asset in assets),
        "apk_video_count": apk_video_count,
        "source_filename_leakage": 0,
        "absolute_path_leakage": 0,
    }


def processing_report(
    assets: list[dict[str, Any]],
    states: dict[str, dict[str, Any]],
    integrity: dict[str, Any],
    validation: dict[str, Any],
    *,
    skipped: int,
    failures: list[dict[str, Any]],
) -> dict[str, Any]:
    all_media_bytes = sum(
        output["bytes"]
        for state in states.values()
        for output in state["outputs"].values()
    )
    video_bytes = sum(asset["bytes"] for asset in assets)
    source_with_audio = 43
    source_with_attached = 43
    return {
        "schema_version": 1,
        "status": "PASS" if not failures and integrity["status"] == "PASS" else "FAIL",
        "total_source": 43,
        "total_processed": len(assets),
        "successful": len(assets),
        "failed": len(failures),
        "failures": failures,
        "resume_skipped_count": skipped,
        "regenerated_count": len(assets) - skipped,
        "audio_removed_count": source_with_audio,
        "attached_picture_removed_count": source_with_attached,
        "resolution_groups": _counter(f"{asset['width']}x{asset['height']}" for asset in assets),
        "output_video_bytes": video_bytes,
        "output_all_media_bytes": all_media_bytes,
        "enabled_default_count": sum(not asset["excluded_by_default"] for asset in assets),
        "excluded_default_count": sum(asset["excluded_by_default"] for asset in assets),
        "sensitivity_distribution": _counter(asset["content_sensitivity"] for asset in assets),
        "allowed_mode_distribution_all": _mode_counts(assets, enabled_only=False),
        "allowed_mode_distribution_enabled": _mode_counts(assets, enabled_only=True),
        "delivery_distribution": _counter(asset["delivery"] for asset in assets),
        "loop_distribution": _counter(asset["kind"] for asset in assets),
        "loop_grade_distribution": _counter(asset["loop_grade"] for asset in assets),
        "review_flag_count": sum(asset["review_flag"] for asset in assets),
        "provisional_visual_confirmation_count": sum(
            asset["needs_visual_confirmation"] for asset in assets
        ),
        "source_integrity": integrity,
        "validation": validation,
    }


def security_report(output_root: Path, manifests: dict[str, dict[str, Any]], repo_root: Path) -> dict[str, Any]:
    _scan_runtime_leaks(manifests, SEED_POLICY)
    llm_files = [output_root / "manifests" / "normal_cues.json", output_root / "manifests" / "private_cues.json"]
    llm_asset_id_leaks = 0
    secret_patterns = [
        re.compile(r"sk-[A-Za-z0-9_-]{20,}"),
        re.compile(r"(?i)(api[_-]?key|secret|password)\s*[:=]\s*['\"]?[A-Za-z0-9_/+=-]{12,}"),
    ]
    secret_matches = 0
    for path in llm_files:
        text = path.read_text(encoding="utf-8") if path.is_file() else ""
        llm_asset_id_leaks += len(re.findall(r"chr_\d{3}", text))
    for name, document in manifests.items():
        text = json.dumps(document, ensure_ascii=False)
        secret_matches += sum(bool(pattern.search(text)) for pattern in secret_patterns)
    if llm_asset_id_leaks or secret_matches:
        raise Phase4Failure("security scan found LLM asset IDs or secret-like values")
    return {
        "schema_version": 1,
        "status": "PASS",
        "runtime_source_filename_leaks": 0,
        "runtime_source_path_leaks": 0,
        "llm_configuration_asset_id_leaks": llm_asset_id_leaks,
        "secret_matches": secret_matches,
        "sensitive_assets_in_bundle": len(manifests["bundle_manifest.json"]["assets"]),
        "apk_video_count": 0,
        "source_asset_map_development_only": True,
    }


def dry_run_plan(source_root: Path, analysis_root: Path, output_root: Path) -> dict[str, Any]:
    validate_roots(source_root, analysis_root, output_root)
    snapshot = capture_snapshot(source_root)
    records = build_policy_records(source_root, analysis_root, snapshot)
    return {
        "status": "PASS",
        "dry_run": True,
        "source_files_read": len(snapshot["files"]),
        "source_videos": len(records),
        "planned_assets": len(records),
        "planned_delivery": _counter(item["delivery"] for item in records),
        "planned_enabled_by_default": sum(not item["excluded_by_default"] for item in records),
        "planned_excluded_by_default": sum(item["excluded_by_default"] for item in records),
        "would_transcode": [item["asset_id"] for item in records],
        "production_writes": 0,
    }


def run_build(
    source_root: Path,
    analysis_root: Path,
    output_root: Path,
    repo_root: Path,
    *,
    ffmpeg_bin: str = "ffmpeg",
    ffprobe_bin: str = "ffprobe",
    concurrency: int = 4,
) -> dict[str, Any]:
    validate_roots(source_root, analysis_root, output_root)
    if shutil.which(ffmpeg_bin) is None or shutil.which(ffprobe_bin) is None:
        raise Phase4Failure("ffmpeg and ffprobe are required")
    if not 1 <= concurrency <= 8:
        raise Phase4Failure("concurrency must be between 1 and 8")

    before = capture_snapshot(source_root)
    output_root.mkdir(parents=True, exist_ok=True)
    reports_root = output_root / "reports"
    manifests_root = output_root / "manifests"
    reports_root.mkdir(parents=True, exist_ok=True)
    manifests_root.mkdir(parents=True, exist_ok=True)
    write_json(reports_root / "source_snapshot_before.json", before)
    records = build_policy_records(source_root, analysis_root, before)
    write_json(analysis_root / "labels.yaml", labels_document(records))
    write_json(analysis_root / "asset_id_registry.json", asset_registry_document(records))
    write_json(output_root / "source_asset_map.json", source_asset_map_document(records))

    previous_build_state = read_json(manifests_root / "build_state.json", {}) or {}
    previous_assets = previous_build_state.get("assets", {}) if isinstance(previous_build_state, dict) else {}
    ffmpeg_identity = _ffmpeg_identity(ffmpeg_bin)
    states: dict[str, dict[str, Any]] = {}
    errors: list[dict[str, Any]] = []
    skipped = 0

    def checkpoint() -> None:
        write_json(
            manifests_root / "build_state.json",
            {
                "schema_version": 1,
                "status": "partial",
                "transcode_profile": TRANSCODE_PROFILE,
                "ffmpeg_identity": ffmpeg_identity,
                "assets": {asset_id: states[asset_id] for asset_id in sorted(states)},
            },
        )

    def work(item: dict[str, Any]) -> tuple[str, dict[str, Any], bool]:
        fingerprint = _hash_json(
            {
                "source_sha256": item["source_sha256"],
                "policy": {
                    key: item[key]
                    for key in (
                        "main_stream_index", "trim_start_ms", "trim_end_ms", "render_mode",
                        "focal_x", "focal_y",
                    )
                },
                "transcode_profile": TRANSCODE_PROFILE,
                "ffmpeg": ffmpeg_identity,
            }
        )
        state, reused = transcode_asset(
            item,
            output_root,
            input_fingerprint=fingerprint,
            previous_state=previous_assets.get(item["asset_id"]),
            ffmpeg_bin=ffmpeg_bin,
            ffprobe_bin=ffprobe_bin,
        )
        return item["asset_id"], state, reused

    try:
        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = {executor.submit(work, item): item for item in records}
            for future in as_completed(futures):
                item = futures[future]
                try:
                    asset_id, state, reused = future.result()
                    states[asset_id] = state
                    skipped += int(reused)
                    checkpoint()
                except Exception as exc:
                    errors.append(
                        {
                            "asset_id": item["asset_id"],
                            "category": "phase4_media",
                            "message": f"{type(exc).__name__}: {exc}",
                        }
                    )
    finally:
        after = capture_snapshot(source_root)
        integrity = compare_snapshots(before, after)
        write_json(reports_root / "source_snapshot_after.json", after)
        write_json(reports_root / "source_integrity.json", integrity)

    if errors or integrity["status"] != "PASS" or len(states) != 43:
        errors.sort(key=lambda item: item["asset_id"])
        write_json(reports_root / "processing_errors.json", {"schema_version": 1, "errors": errors})
        raise Phase4Failure(
            f"processing failed: {len(states)}/43 successful, {len(errors)} errors, integrity={integrity['status']}"
        )

    ordered_states = {asset_id: states[asset_id] for asset_id in sorted(states)}
    build_state = {
        "schema_version": 1,
        "status": "complete",
        "transcode_profile": TRANSCODE_PROFILE,
        "ffmpeg_identity": ffmpeg_identity,
        "assets": ordered_states,
    }
    manifests = build_manifests(records, ordered_states, before)
    source_names = [item["source_file"] for item in records]
    for name, document in manifests.items():
        validate_manifest_document(document, master=name == "character_manifest.json")
    _scan_runtime_leaks(manifests, source_names)

    for name, document in manifests.items():
        write_json(output_root / name, document)
    write_json(manifests_root / "build_state.json", build_state)
    write_json(output_root / "coverage_report.json", coverage_report(manifests["character_manifest.json"]["assets"]))
    normal_cues = [
        cue for cue in CUE_REGISTRY if set(cue["allowed_modes"]).intersection({"daily", "assistant", "relationship"})
    ]
    private_cues = [cue for cue in CUE_REGISTRY if "private" in cue["allowed_modes"]]
    write_json(manifests_root / "normal_cues.json", {"schema_version": 1, "cues": normal_cues})
    write_json(manifests_root / "private_cues.json", {"schema_version": 1, "cues": private_cues})

    validation = validate_library(
        output_root,
        manifests,
        source_names=source_names,
        ffprobe_bin=ffprobe_bin,
        repo_root=repo_root,
    )
    security = security_report(output_root, manifests, repo_root)
    write_json(reports_root / "security_validation.json", security)
    report = processing_report(
        manifests["character_manifest.json"]["assets"],
        ordered_states,
        integrity,
        validation,
        skipped=skipped,
        failures=[],
    )
    write_json(output_root / "processing_report.json", report)
    write_json(reports_root / "media_validation.json", validation)
    write_phase4_report(repo_root, output_root)
    return {
        "status": "PASS",
        "processed": len(states),
        "skipped_verified": skipped,
        "regenerated": len(states) - skipped,
        "manifest_assets": validation["master_assets"],
        "enabled_by_default": validation["enabled_by_default"],
        "excluded_by_default": validation["excluded_by_default"],
        "review_assets": validation["review_assets"],
        "integrity": integrity["status"],
        "media_verification": validation["status"],
    }


def run_validate(
    source_root: Path,
    analysis_root: Path,
    output_root: Path,
    repo_root: Path,
    *,
    ffprobe_bin: str = "ffprobe",
) -> dict[str, Any]:
    validate_roots(source_root, analysis_root, output_root)
    before = _load_json_object(output_root / "reports" / "source_snapshot_before.json")
    after = capture_snapshot(source_root)
    integrity = compare_snapshots(before, after)
    write_json(output_root / "reports" / "source_snapshot_after.json", after)
    write_json(output_root / "reports" / "source_integrity.json", integrity)
    if integrity["status"] != "PASS":
        raise Phase4Failure("source integrity validation failed")
    result = validate_library(
        output_root,
        source_names=SEED_POLICY,
        ffprobe_bin=ffprobe_bin,
        repo_root=repo_root,
    )
    write_json(output_root / "reports" / "media_validation.json", result)
    write_phase4_report(repo_root, output_root)
    return {"status": "PASS", "integrity": integrity["status"], **result}


def record_test_result(
    repo_root: Path,
    output_root: Path,
    *,
    status: str,
    tests_run: int,
    command: str,
) -> dict[str, Any]:
    document = {
        "schema_version": 1,
        "status": status,
        "tests_run": tests_run,
        "command": command,
    }
    write_json(output_root / "reports" / "test_results.json", document)
    write_phase4_report(repo_root, output_root)
    return document


def write_phase4_report(repo_root: Path, output_root: Path) -> Path:
    processing = read_json(output_root / "processing_report.json", {}) or {}
    coverage = read_json(output_root / "coverage_report.json", {}) or {}
    security = read_json(output_root / "reports" / "security_validation.json", {}) or {}
    tests = read_json(output_root / "reports" / "test_results.json", {}) or {}
    integrity = read_json(output_root / "reports" / "source_integrity.json", {}) or {}
    validation = read_json(output_root / "reports" / "media_validation.json", {}) or {}
    if not processing:
        return repo_root / "docs" / "PHASE_4_REPORT.md"
    contexts = coverage.get("contexts", {})
    coverage_lines = []
    for state in CORE_STATES:
        values = [str(contexts.get(mode, {}).get(state, {}).get("candidates", 0)) for mode in STAGE_CONTEXTS]
        coverage_lines.append(f"| `{state}` | " + " | ".join(values) + " |")
    test_status = tests.get("status", "NOT_RECORDED")
    text = f"""# HANA PHASE 4 — APP-READY VIDEO LIBRARY

Status: **{'PASS' if processing.get('status') == 'PASS' and test_status == 'PASS' else 'PENDING'}**

## 1. Processing result

- Source processed: **{processing.get('total_processed', 0)}/43**
- Successful: **{processing.get('successful', 0)}**; failed: **{processing.get('failed', 0)}**
- Master manifest: **{validation.get('master_assets', 0)}** assets
- Enabled by default: **{processing.get('enabled_default_count', 0)}**; excluded by default: **{processing.get('excluded_default_count', 0)}**

## 2. Transcode profile

MP4/H.264 High Level 4.0, yuv420p, 24 fps, CRF 20, preset slow, GOP 12, faststart. The pipeline maps only the Phase 2 main video stream, preserves aspect ratio, caps each axis at 1280 without upscaling, strips source metadata and chapters, and removes audio/subtitle/data/attached-picture streams.

## 3. Audio and attached-picture removal

- Audio removed: **{processing.get('audio_removed_count', 0)}/43**; verified output audio streams: **0**.
- Attached pictures removed: **{processing.get('attached_picture_removed_count', 0)}/43**; verified output attached pictures: **0**.
- Every production MP4 has exactly one H.264 video stream.

## 4. Output size and resolution

- Video bytes: **{processing.get('output_video_bytes', 0)}**
- All production media bytes (video + poster + blur): **{processing.get('output_all_media_bytes', 0)}**
- Resolution groups: `{json.dumps(processing.get('resolution_groups', {}), ensure_ascii=False, sort_keys=True)}`

## 5. Sensitivity and allowed modes

- Sensitivity: `{json.dumps(processing.get('sensitivity_distribution', {}), ensure_ascii=False, sort_keys=True)}`
- Default candidates: `{json.dumps(processing.get('allowed_mode_distribution_enabled', {}), ensure_ascii=False, sort_keys=True)}`
- The 17 `suggestive` labels remain provisional (`needs_visual_confirmation=true`); no sensitivity was reclassified in Phase 4.

## 6. State pool coverage

| CoreState | daily | assistant | relationship | private |
|---|---:|---:|---:|---:|
{chr(10).join(coverage_lines)}

The Phase 3.2 state/cue mapping remains `provisional`. Coverage gaps are warnings and do not fail this media build.

## 7. Fallback gaps

Daily/assistant still has no direct candidate for `surprised`, `concerned`, `working`, or `sleep`. Phase 5 must apply: requested state → idle pool → daily pool where allowed → poster → silhouette. It must never borrow an asset outside the effective mode.

## 8. Review and poor assets

- Review assets retained: **{processing.get('review_flag_count', 0)}/19**. Their lower weights are preserved and they are variants rather than main loops when a main loop exists.
- `chr_011` and `chr_022` were retained with `technical_quality=poor`, `kind=oneshot`, `weight=0.2`, and `excluded_by_default=true`.

## 9. Delivery classes

`{json.dumps(processing.get('delivery_distribution', {}), ensure_ascii=False, sort_keys=True)}`. All 43 videos are in `vault`; `bundle` and `private_vault` contain zero videos. The APK remains video-free.

## 10. Manifest and security validation

- Media/manifest validation: **{validation.get('status', 'UNKNOWN')}**; media verified: **{validation.get('media_verified', 0)}/43**.
- Source filename/path leakage in runtime manifests: **{security.get('runtime_source_filename_leaks', 'UNKNOWN')} / {security.get('runtime_source_path_leaks', 'UNKNOWN')}**.
- LLM-facing cue configuration asset-ID leakage: **{security.get('llm_configuration_asset_id_leaks', 'UNKNOWN')}**.
- Sensitive assets in bundle/APK: **{security.get('sensitive_assets_in_bundle', 'UNKNOWN')} / {validation.get('apk_video_count', 'UNKNOWN')}**.

## 11. Source integrity

Before/after result: **{integrity.get('status', 'UNKNOWN')}**; files before/after: **{integrity.get('files_before', 0)}/{integrity.get('files_after', 0)}**; modified: **{len(integrity.get('modified', []))}**; added: **{len(integrity.get('added', []))}**; missing: **{len(integrity.get('missing', []))}**.

## 12. Tests

- Status: **{test_status}**
- Tests run: **{tests.get('tests_run', 0)}**
- Command: `{tests.get('command', 'not recorded')}`

The test suite uses generated temporary video fixtures and does not copy the 43 production source videos into the repository.

## 13. Dry-run, idempotency, and resume

`--dry-run` captures and validates a read-only plan and writes no production media or manifests. Build state fingerprints include the source SHA-256, transcode profile, selected stream, and FFmpeg identity. A verified matching asset is skipped; a missing, partial, corrupt, or fingerprint-mismatched asset is regenerated atomically. Stable input yields stable media and manifest hashes with the pinned FFmpeg build/profile.

## 14. Known limitations

- Sensitivity for the 17 square clips and all state/cue mappings still require owner visual confirmation; Phase 4 preserved the Phase 3.2 provisional flags.
- The library lacks daily/assistant candidates for four states listed above; fallback is required in Phase 5.
- Byte determinism is guaranteed for unchanged input, policy, transcode profile, and FFmpeg identity. A toolchain change intentionally invalidates the resume fingerprint and requires a new reproducibility check.

## 15. Readiness for Phase 5

The library is ready for Phase 5 when this report status is PASS: Character Engine can consume canonical delivery manifests, deterministic context views, coverage warnings, posters, and the documented fallback chain without exposing source metadata or video identifiers to the LLM.
"""
    path = repo_root / "docs" / "PHASE_4_REPORT.md"
    atomic_write_text(path, text)
    return path
