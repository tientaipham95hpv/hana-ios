# Hana Phase 2 — Video Inventory & Visual Preparation Report

Status: **PASS**

## 1. Source inventory

- Source videos: **43**
- Inventory succeeded: **43**
- Inventory failed: **0**
- Total bytes: **170893137**

## 2. Technical metadata

- Resolution groups: 544x544: 17, 720x1280: 14, 768x1168: 12
- Video codecs: h264: 43
- Average frame rates: 24.0: 43
- Audio stream-count groups: 1: 43
- Attached pictures: **43**

Canonical per-file metadata is in `asset_analysis/inventory.json`; the review table is in `asset_analysis/inventory.csv`.

## 3. Duplicate detection

- Exact duplicate groups: **0** (0 files in groups)
- Near-duplicate candidates: **0**
- Near-duplicate method: **not_implemented**

Near-duplicate matching is intentionally not implemented in Phase 2 because no calibrated perceptual-hash threshold and review corpus are available. The pipeline does not guess or reject files.

## 4. Visual preparation

- Keyframe coverage: **258/258**
- Contact-sheet coverage: **43/43**
- Sampling positions: 0%, 20%, 40%, 60%, 80%, and EOF-safe 100%
- Main stream selection excludes streams with `disposition.attached_pic == 1`.

## 5. Source integrity

- Result: **PASS**
- Files before/after: **43/43**
- Missing: **0**
- Added: **0**
- Modified (bytes, SHA-256, or mtime): **0**

## 6. Automated tests

- Result: **PASS**
- Tests run: **16**
- Command: `python -m unittest discover -s tools/asset_pipeline/tests -v`

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
