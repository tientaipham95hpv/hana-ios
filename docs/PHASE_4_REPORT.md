# HANA PHASE 4 — APP-READY VIDEO LIBRARY

Status: **PASS**

## 1. Processing result

- Source processed: **43/43**
- Successful: **43**; failed: **0**
- Master manifest: **43** assets
- Enabled by default: **41**; excluded by default: **2**

## 2. Transcode profile

MP4/H.264 High Level 4.0, yuv420p, 24 fps, CRF 20, preset slow, GOP 12, faststart. The pipeline maps only the Phase 2 main video stream, preserves aspect ratio, caps each axis at 1280 without upscaling, strips source metadata and chapters, and removes audio/subtitle/data/attached-picture streams.

## 3. Audio and attached-picture removal

- Audio removed: **43/43**; verified output audio streams: **0**.
- Attached pictures removed: **43/43**; verified output attached pictures: **0**.
- Every production MP4 has exactly one H.264 video stream.

## 4. Output size and resolution

- Video bytes: **138930960**
- All production media bytes (video + poster + blur): **141683150**
- Resolution groups: `{"544x544": 17, "720x1280": 14, "768x1168": 12}`

## 5. Sensitivity and allowed modes

- Sensitivity: `{"private": 26, "suggestive": 17}`
- Default candidates: `{"assistant": 15, "daily": 15, "private": 41, "relationship": 41}`
- The 17 `suggestive` labels remain provisional (`needs_visual_confirmation=true`); no sensitivity was reclassified in Phase 4.

## 6. State pool coverage

| CoreState | daily | assistant | relationship | private |
|---|---:|---:|---:|---:|
| `idle` | 8 | 8 | 25 | 25 |
| `listening` | 1 | 1 | 4 | 4 |
| `talking` | 3 | 3 | 3 | 3 |
| `thinking` | 1 | 1 | 3 | 3 |
| `happy` | 4 | 4 | 7 | 7 |
| `shy` | 2 | 2 | 4 | 4 |
| `surprised` | 0 | 0 | 2 | 2 |
| `concerned` | 0 | 0 | 1 | 1 |
| `working` | 0 | 0 | 2 | 2 |
| `sleep` | 0 | 0 | 2 | 2 |

The Phase 3.2 state/cue mapping remains `provisional`. Coverage gaps are warnings and do not fail this media build.

## 7. Fallback gaps

Daily/assistant still has no direct candidate for `surprised`, `concerned`, `working`, or `sleep`. Phase 5 must apply: requested state → idle pool → daily pool where allowed → poster → silhouette. It must never borrow an asset outside the effective mode.

## 8. Review and poor assets

- Review assets retained: **19/19**. Their lower weights are preserved and they are variants rather than main loops when a main loop exists.
- `chr_011` and `chr_022` were retained with `technical_quality=poor`, `kind=oneshot`, `weight=0.2`, and `excluded_by_default=true`.

## 9. Delivery classes

`{"vault": 43}`. All 43 videos are in `vault`; `bundle` and `private_vault` contain zero videos. The APK remains video-free.

## 10. Manifest and security validation

- Media/manifest validation: **PASS**; media verified: **43/43**.
- Source filename/path leakage in runtime manifests: **0 / 0**.
- LLM-facing cue configuration asset-ID leakage: **0**.
- Sensitive assets in bundle/APK: **0 / 0**.

## 11. Source integrity

Before/after result: **PASS**; files before/after: **43/43**; modified: **0**; added: **0**; missing: **0**.

## 12. Tests

- Status: **PASS**
- Tests run: **28**
- Command: `python -m unittest discover -s tools/asset_pipeline/tests -v`

The test suite uses generated temporary video fixtures and does not copy the 43 production source videos into the repository.

## 13. Dry-run, idempotency, and resume

`--dry-run` captures and validates a read-only plan and writes no production media or manifests. Build state fingerprints include the source SHA-256, transcode profile, selected stream, and FFmpeg identity. A verified matching asset is skipped; a missing, partial, corrupt, or fingerprint-mismatched asset is regenerated atomically. Stable input yields stable media and manifest hashes with the pinned FFmpeg build/profile.

## 14. Known limitations

- Sensitivity for the 17 square clips and all state/cue mappings still require owner visual confirmation; Phase 4 preserved the Phase 3.2 provisional flags.
- The library lacks daily/assistant candidates for four states listed above; fallback is required in Phase 5.
- Byte determinism is guaranteed for unchanged input, policy, transcode profile, and FFmpeg identity. A toolchain change intentionally invalidates the resume fingerprint and requires a new reproducibility check.

## 15. Readiness for Phase 5

The library is ready for Phase 5 when this report status is PASS: Character Engine can consume canonical delivery manifests, deterministic context views, coverage warnings, posters, and the documented fallback chain without exposing source metadata or video identifiers to the LLM.
