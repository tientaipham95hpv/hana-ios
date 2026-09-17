from __future__ import annotations

import csv
from pathlib import Path
from typing import Any

from .hashing import sha256_file
from .paths import UnsafePathError, validate_relative_portable


def verify_outputs(
    output_root: Path,
    inventory: dict[str, Any],
    duplicates: dict[str, Any],
    visual_index: dict[str, Any],
    state: dict[str, Any],
    integrity: dict[str, Any],
) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []

    def check(name: str, passed: bool, detail: str) -> None:
        checks.append({"name": name, "status": "PASS" if passed else "FAIL", "detail": detail})

    summary = inventory.get("summary", {})
    videos = inventory.get("videos", [])
    check(
        "inventory_complete",
        summary.get("source_video_count") == len(videos) and not inventory.get("errors"),
        f"{len(videos)}/{summary.get('source_video_count', 0)} videos",
    )
    check(
        "sha256_complete",
        all(len(item.get("sha256", "")) == 64 for item in videos),
        f"{sum(len(item.get('sha256', '')) == 64 for item in videos)}/{len(videos)} hashes",
    )
    check("source_integrity", integrity.get("status") == "PASS", integrity.get("status", "missing"))

    csv_path = output_root / "inventory.csv"
    csv_ids: list[str] = []
    try:
        with csv_path.open("r", encoding="utf-8", newline="") as handle:
            csv_ids = [row["source_id"] for row in csv.DictReader(handle)]
    except (OSError, KeyError, csv.Error):
        pass
    expected_ids = [item["source_id"] for item in videos]
    check("inventory_csv", csv_ids == expected_ids, f"{len(csv_ids)}/{len(expected_ids)} rows")
    check(
        "duplicates_schema",
        duplicates.get("schema_version") == 1
        and isinstance(duplicates.get("exact_duplicates"), list)
        and isinstance(duplicates.get("near_duplicate_candidates"), list),
        f"{len(duplicates.get('exact_duplicates', []))} exact groups",
    )

    index_records = visual_index.get("records", [])
    check("visual_index_coverage", len(index_records) == len(videos), f"{len(index_records)}/{len(videos)} records")
    portable = True
    present_keyframes = 0
    present_sheets = 0
    state_assets = state.get("assets", {})
    state_hashes_valid = True
    for record in index_records:
        paths = [record.get("contact_sheet", "")] + [item.get("path", "") for item in record.get("keyframes", [])]
        for relative in paths:
            try:
                validate_relative_portable(relative)
            except UnsafePathError:
                portable = False
                continue
            path = output_root / Path(*relative.split("/"))
            if relative.startswith("keyframes/") and path.is_file():
                present_keyframes += 1
            elif relative.startswith("contact_sheets/") and path.is_file():
                present_sheets += 1
        state_item = state_assets.get(record["source_id"], {})
        for relative, digest in state_item.get("outputs", {}).items():
            path = output_root / Path(*relative.split("/"))
            if not path.is_file() or sha256_file(path) != digest:
                state_hashes_valid = False
    expected_keyframes = len(videos) * 6
    check("portable_paths", portable, "all visual paths are portable" if portable else "invalid path found")
    check("keyframe_coverage", present_keyframes == expected_keyframes, f"{present_keyframes}/{expected_keyframes}")
    check("contact_sheet_coverage", present_sheets == len(videos), f"{present_sheets}/{len(videos)}")
    check(
        "resume_state",
        len(state_assets) == len(videos) and state_hashes_valid,
        f"{len(state_assets)}/{len(videos)} assets with validated output hashes",
    )
    status = "PASS" if all(item["status"] == "PASS" for item in checks) else "FAIL"
    return {"schema_version": 1, "status": status, "checks": checks}
