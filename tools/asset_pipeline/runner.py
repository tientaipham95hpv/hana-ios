from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any

from .duplicates import build_duplicates
from .integrity import capture_snapshot, compare_snapshots
from .inventory import build_inventory, inventory_csv
from .io_utils import atomic_write_text, read_json, write_json
from .keyframes import extract_visuals
from .paths import ensure_output_outside_source
from .report import write_report
from .verification import verify_outputs
from .visual_index import build_visual_index


class PipelineFailure(RuntimeError):
    pass


def _require_executable(name: str) -> None:
    if shutil.which(name) is None:
        raise PipelineFailure(f"required executable not found: {name}")


def _write_scan_outputs(
    source_root: Path,
    output_root: Path,
    before: dict[str, Any],
    *,
    ffprobe_bin: str,
    concurrency: int,
) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, Any]], int]:
    previous = read_json(output_root / "inventory.json", None)
    inventory, errors, reused = build_inventory(
        source_root,
        before,
        previous=previous,
        ffprobe_bin=ffprobe_bin,
        concurrency=concurrency,
    )
    duplicates = build_duplicates(inventory)
    write_json(output_root / "inventory.json", inventory)
    atomic_write_text(output_root / "inventory.csv", inventory_csv(inventory))
    write_json(output_root / "duplicates.json", duplicates)
    return inventory, duplicates, errors, reused


def _snapshot_video_map(snapshot: dict[str, Any]) -> dict[str, str]:
    return {item["relative_path"]: item["sha256"] for item in snapshot.get("files", [])}


def _inventory_matches_snapshot(inventory: dict[str, Any], snapshot: dict[str, Any]) -> bool:
    snapshot_map = _snapshot_video_map(snapshot)
    inventory_map = {item["relative_source_path"]: item["sha256"] for item in inventory.get("videos", [])}
    expected = {path: digest for path, digest in snapshot_map.items() if Path(path).suffix.casefold() in {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm"}}
    return inventory_map == expected and not inventory.get("errors")


def _finalize_integrity(output_root: Path, before: dict[str, Any], source_root: Path) -> dict[str, Any]:
    after = capture_snapshot(source_root)
    result = compare_snapshots(before, after)
    write_json(output_root / "source_snapshot_after.json", after)
    write_json(output_root / "integrity_result.json", result)
    return result


def dry_run_plan(command: str, source_root: Path, output_root: Path) -> dict[str, Any]:
    snapshot = capture_snapshot(source_root)
    videos = [
        item for item in snapshot["files"] if Path(item["relative_path"]).suffix.casefold() in {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm"}
    ]
    existing_inventory = read_json(output_root / "inventory.json", {})
    existing_state = read_json(output_root / "pipeline_state.json", {})
    return {
        "status": "PASS",
        "dry_run": True,
        "command": command,
        "source_files_read": len(snapshot["files"]),
        "source_videos": len(videos),
        "existing_inventory_records": len(existing_inventory.get("videos", [])),
        "existing_visual_assets": len(existing_state.get("assets", {})),
        "would_write": [
            "source_snapshot_before.json",
            "inventory.json",
            "inventory.csv",
            "duplicates.json",
            "keyframes/<source_id>/*.jpg",
            "contact_sheets/<source_id>.jpg",
            "visual_index.json",
            "source_snapshot_after.json",
            "integrity_result.json",
            "verification.json",
            "errors.json",
            "repo/docs/PHASE_2_REPORT.md",
        ] if command == "all" else [],
    }


def run_scan(source_root: Path, output_root: Path, *, ffprobe_bin: str, concurrency: int) -> dict[str, Any]:
    _require_executable(ffprobe_bin)
    before = capture_snapshot(source_root)
    write_json(output_root / "source_snapshot_before.json", before)
    inventory, duplicates, errors, reused = _write_scan_outputs(
        source_root, output_root, before, ffprobe_bin=ffprobe_bin, concurrency=concurrency
    )
    write_json(output_root / "visual_index.json", build_visual_index(inventory, duplicates))
    integrity = _finalize_integrity(output_root, before, source_root)
    write_json(output_root / "errors.json", {"schema_version": 1, "errors": errors})
    status = "PASS" if not errors and integrity["status"] == "PASS" else "FAIL"
    return {"status": status, "inventory": inventory, "integrity": integrity, "reused_probes": reused}


def _run_extract_from_inventory(
    source_root: Path,
    output_root: Path,
    inventory: dict[str, Any],
    *,
    ffmpeg_bin: str,
    concurrency: int,
) -> tuple[dict[str, Any], list[dict[str, Any]], int]:
    _require_executable(ffmpeg_bin)
    previous_state = read_json(output_root / "pipeline_state.json", None)
    state, errors, skipped = extract_visuals(
        source_root,
        output_root,
        inventory,
        previous_state=previous_state,
        ffmpeg_bin=ffmpeg_bin,
        concurrency=concurrency,
    )
    write_json(output_root / "pipeline_state.json", state)
    return state, errors, skipped


def run_extract(source_root: Path, output_root: Path, repo_root: Path, *, ffmpeg_bin: str, concurrency: int) -> dict[str, Any]:
    before = capture_snapshot(source_root)
    write_json(output_root / "source_snapshot_before.json", before)
    inventory = read_json(output_root / "inventory.json", {})
    if not _inventory_matches_snapshot(inventory, before):
        raise PipelineFailure("inventory.json does not match current source; run scan or all")
    duplicates = read_json(output_root / "duplicates.json", build_duplicates(inventory))
    state, errors, skipped = _run_extract_from_inventory(
        source_root, output_root, inventory, ffmpeg_bin=ffmpeg_bin, concurrency=concurrency
    )
    visual = build_visual_index(inventory, duplicates)
    write_json(output_root / "visual_index.json", visual)
    integrity = _finalize_integrity(output_root, before, source_root)
    write_json(output_root / "errors.json", {"schema_version": 1, "errors": errors})
    verification = verify_outputs(output_root, inventory, duplicates, visual, state, integrity)
    write_json(output_root / "verification.json", verification)
    write_report(repo_root, output_root)
    status = "PASS" if not errors and verification["status"] == "PASS" else "FAIL"
    return {"status": status, "integrity": integrity, "verification": verification, "skipped_visuals": skipped}


def run_all(
    source_root: Path,
    output_root: Path,
    repo_root: Path,
    *,
    ffprobe_bin: str,
    ffmpeg_bin: str,
    concurrency: int,
) -> dict[str, Any]:
    _require_executable(ffprobe_bin)
    _require_executable(ffmpeg_bin)
    before = capture_snapshot(source_root)
    write_json(output_root / "source_snapshot_before.json", before)
    inventory, duplicates, inventory_errors, reused = _write_scan_outputs(
        source_root, output_root, before, ffprobe_bin=ffprobe_bin, concurrency=concurrency
    )
    state, extract_errors, skipped = _run_extract_from_inventory(
        source_root, output_root, inventory, ffmpeg_bin=ffmpeg_bin, concurrency=concurrency
    )
    visual = build_visual_index(inventory, duplicates)
    write_json(output_root / "visual_index.json", visual)
    integrity = _finalize_integrity(output_root, before, source_root)
    errors = inventory_errors + extract_errors
    errors.sort(key=lambda item: ((item.get("relative_source_path") or "").casefold(), item.get("category") or ""))
    write_json(output_root / "errors.json", {"schema_version": 1, "errors": errors})
    verification = verify_outputs(output_root, inventory, duplicates, visual, state, integrity)
    write_json(output_root / "verification.json", verification)
    write_report(repo_root, output_root)
    status = "PASS" if not errors and verification["status"] == "PASS" else "FAIL"
    return {
        "status": status,
        "inventory": inventory["summary"],
        "integrity": integrity,
        "verification": verification,
        "errors": len(errors),
        "reused_probes": reused,
        "skipped_visuals": skipped,
    }


def run_verify(source_root: Path, output_root: Path, repo_root: Path) -> dict[str, Any]:
    before = read_json(output_root / "source_snapshot_before.json", {})
    if not before:
        raise PipelineFailure("source_snapshot_before.json is missing")
    integrity = _finalize_integrity(output_root, before, source_root)
    inventory = read_json(output_root / "inventory.json", {})
    duplicates = read_json(output_root / "duplicates.json", {})
    visual = read_json(output_root / "visual_index.json", {})
    state = read_json(output_root / "pipeline_state.json", {})
    verification = verify_outputs(output_root, inventory, duplicates, visual, state, integrity)
    write_json(output_root / "verification.json", verification)
    write_report(repo_root, output_root)
    return {"status": verification["status"], "integrity": integrity, "verification": verification}


def validate_roots(source_root: Path, output_root: Path) -> None:
    if not source_root.is_dir():
        raise PipelineFailure(f"source directory not found: {source_root}")
    if source_root.is_symlink():
        raise PipelineFailure("assets_source root must not be a symlink")
    ensure_output_outside_source(source_root, output_root)
