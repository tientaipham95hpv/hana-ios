from __future__ import annotations

from pathlib import Path
from typing import Any

from .io_utils import atomic_write_text, read_json


def _groups(values: dict[str, Any]) -> str:
    return ", ".join(f"{key}: {value}" for key, value in values.items()) or "none"


def render_report(
    inventory: dict[str, Any],
    duplicates: dict[str, Any],
    verification: dict[str, Any],
    integrity: dict[str, Any],
    test_results: dict[str, Any] | None,
) -> str:
    summary = inventory.get("summary", {})
    video_count = summary.get("source_video_count", 0)
    exact_groups = duplicates.get("exact_duplicates", [])
    duplicate_files = sum(len(group.get("source_ids", [])) for group in exact_groups)
    tests = test_results or {"status": "PENDING", "tests_run": 0, "command": "python -m unittest discover -s tools/asset_pipeline/tests -v"}
    verification_status = verification.get("status", "FAIL")
    tests_status = tests.get("status", "PENDING")
    phase_status = "PASS" if verification_status == "PASS" and tests_status == "PASS" else "CONDITIONAL FAIL"
    checks = {item["name"]: item for item in verification.get("checks", [])}
    keyframes = checks.get("keyframe_coverage", {}).get("detail", "0/0")
    sheets = checks.get("contact_sheet_coverage", {}).get("detail", "0/0")
    return f"""# Hana Phase 2 — Video Inventory & Visual Preparation Report

Status: **{phase_status}**

## 1. Source inventory

- Source videos: **{video_count}**
- Inventory succeeded: **{summary.get('inventory_success_count', 0)}**
- Inventory failed: **{summary.get('inventory_failure_count', 0)}**
- Total bytes: **{summary.get('total_bytes', 0)}**

## 2. Technical metadata

- Resolution groups: {_groups(summary.get('resolution_groups', {}))}
- Video codecs: {_groups(summary.get('codec_groups', {}))}
- Average frame rates: {_groups(summary.get('fps_groups', {}))}
- Audio stream-count groups: {_groups(summary.get('audio_stream_count_groups', {}))}
- Attached pictures: **{summary.get('attached_picture_count', 0)}**

Canonical per-file metadata is in `asset_analysis/inventory.json`; the review table is in `asset_analysis/inventory.csv`.

## 3. Duplicate detection

- Exact duplicate groups: **{len(exact_groups)}** ({duplicate_files} files in groups)
- Near-duplicate candidates: **{len(duplicates.get('near_duplicate_candidates', []))}**
- Near-duplicate method: **{duplicates.get('near_duplicate_detection', {}).get('status', 'unknown')}**

Near-duplicate matching is intentionally not implemented in Phase 2 because no calibrated perceptual-hash threshold and review corpus are available. The pipeline does not guess or reject files.

## 4. Visual preparation

- Keyframe coverage: **{keyframes}**
- Contact-sheet coverage: **{sheets}**
- Sampling positions: 0%, 20%, 40%, 60%, 80%, and EOF-safe 100%
- Main stream selection excludes streams with `disposition.attached_pic == 1`.

## 5. Source integrity

- Result: **{integrity.get('status', 'FAIL')}**
- Files before/after: **{integrity.get('files_before', 0)}/{integrity.get('files_after', 0)}**
- Missing: **{len(integrity.get('missing', []))}**
- Added: **{len(integrity.get('added', []))}**
- Modified (bytes, SHA-256, or mtime): **{len(integrity.get('modified', []))}**

## 6. Automated tests

- Result: **{tests_status}**
- Tests run: **{tests.get('tests_run', 0)}**
- Command: `{tests.get('command', '')}`

## 7. Reproduction

Run from `repo/` with Python 3.11, FFmpeg, ffprobe, and Pillow available:

```powershell
python -m tools.asset_pipeline.cli all
python -m tools.asset_pipeline.cli all --dry-run
python -m tools.asset_pipeline.cli verify
python -m unittest discover -s tools/asset_pipeline/tests -v
```

Defaults resolve to sibling directories `assets_source/` and `asset_analysis/`; paths in generated JSON are relative and portable.

## 8. Error handling and resume behavior

- Probe and extraction errors are recorded per file in `asset_analysis/errors.json`; safe work for other files continues.
- JSON/CSV/state files are replaced atomically.
- Existing keyframes and contact sheets are reused only when the input fingerprint and every output checksum match.
- A changed source invalidates its own source ID and generated outputs; stale generated outputs are removed from analysis directories.
- FFmpeg concurrency is bounded (default 4, maximum 8).

## 9. Known limitations

- Near-duplicate detection is deferred until a labelled review corpus can calibrate false-positive and false-negative thresholds.
- JPEG bytes may differ across FFmpeg/Pillow versions; the resume state remains deterministic within the installed toolchain.
- Phase 2 does not classify state, mode, sensitivity, CoreState, or special cues and does not create production assets.

## 10. Phase 3 readiness

`asset_analysis/visual_index.json` gives Phase 3 one record per source video with stable source ID, technical dimensions, duration, FPS, exact-duplicate membership, six keyframes, and one contact sheet. Phase 3 can consume every path relative to `asset_analysis/` without inferring directory structure.
"""


def write_report(repo_root: Path, output_root: Path) -> Path:
    report_path = repo_root / "docs" / "PHASE_2_REPORT.md"
    report = render_report(
        read_json(output_root / "inventory.json", {}),
        read_json(output_root / "duplicates.json", {}),
        read_json(output_root / "verification.json", {}),
        read_json(output_root / "integrity_result.json", {}),
        read_json(output_root / "test_results.json", None),
    )
    atomic_write_text(report_path, report)
    return report_path
