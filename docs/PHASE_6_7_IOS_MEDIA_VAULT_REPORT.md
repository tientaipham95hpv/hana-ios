# Phase 6.7 — Real Character Media Vault on iOS

## Status

**Implementation and local validation: PASS.** GitHub macOS CI and physical-iPhone playback are recorded separately below. Phase 7 was not started.

The app now discovers a configurable remote manifest, retains a validated last-known-good copy, downloads a small semantic startup pack, verifies and atomically caches media in application-owned storage, exposes download/storage controls, and gives only verified local files to the existing muted full-screen character stage. No character video is declared as a Flutter asset.

## Preserved Phase 4 and Character Engine invariants

The bundled metadata snapshot and regression suite still assert the current canonical baseline:

- `chr_001` through `chr_043`, exactly 43 current assets;
- 41 enabled by default;
- only `chr_011` and `chr_022` are excluded by default;
- 19 review assets retained;
- zero audio, subtitle, data, and attached-picture streams in the runtime manifest;
- unchanged sensitivity, `allowed_modes`, state pools, cue policy, and focal/render metadata;
- semantic selection remains in the client Character Engine; network and storage paths stay behind `CharacterAssetRepository` and never enter the LLM protocol.

The manifest parser accepts a future sequential manifest above 43 assets when the current 43 canonical policy records remain present and valid. The live normal engine adopts the validated manifest after bootstrap. Current-baseline tests continue to require all 43 existing records.

## Vault architecture

| Component | Responsibility |
| --- | --- |
| `CharacterVault` | Orchestrates bootstrap, staged downloads, cache policy, status, offline resolution, and the `CharacterAssetRepository` abstraction consumed by the engine/stage. |
| `CharacterManifestRepository` | Loads the last-known-good local manifest, fetches remote metadata, validates schema and canonical policy, compares version/hash, and commits with a temporary file plus atomic rename. |
| `CharacterDownloadManager` | Runs two bounded workers, supports Range resume, pause/resume/cancel, retries retryable network/HTTP errors with exponential backoff, and finalizes through a temporary file. |
| `CharacterCacheIndex` | Persists relative local paths, manifest/hash/size/timestamps/status/failure/pin fields in application support storage. |
| `CharacterPreloader` | Selects at most three likely semantic successors for idle/thinking/talking flows and respects mode/download policy. |
| `CharacterIntegrityVerifier` | Checks asset ID, deterministic filename, manifest size, MP4 `ftyp` signature, and SHA-256 before `READY`. |

`VideoStage` and the full-screen `CharacterStageBackground` protect an asset from eviction before controller initialization and release it only after controller disposal. The existing hard cap remains three controllers, including an in-flight/preload controller. Both paths still initialize through `MutedVideoSession`, which forces volume to `0.0` and uses `mixWithOthers`.

## Configuration and remote layout

No production host is embedded. Compile-time configuration is:

- `HANA_MEDIA_BASE_URL`
- `HANA_MEDIA_MANIFEST_URL` (optional manifest override)

The default deterministic mapping is:

```text
<base>/manifest/character_manifest.json
<base>/assets/chr_001.mp4
...
<base>/assets/chr_043.mp4
```

When only a manifest URL is supplied, the default asset directory is resolved from its parent server root. Deployments with a different layout set both values. Only HTTP(S) URLs are accepted.

## Bootstrap and manifest policy

1. The app starts with the safe bundled metadata snapshot and a silhouette; chat is available.
2. The vault opens the iOS Application Support subdirectory `character_media_vault` through `path_provider`. It never persists a workstation path.
3. A valid local manifest is loaded first.
4. Remote metadata is fetched when configured.
5. Schema, manifest kind, sequential IDs, safe paths, stream counts, current canonical policies, and baseline presence are validated.
6. Only a completely valid response replaces the local file. Invalid/offline responses retain the local or bundled last-known-good manifest and publish a non-blocking status.
7. Cached files remain available when the remote manifest cannot be reached.

The index stores paths such as `assets/chr_001.mp4`; it contains no credentials and no absolute Windows/macOS path.

## Download stages and policy boundaries

- **Stage A:** one eligible candidate for each useful startup semantic state (idle, talking, thinking, happy, listening, shy where available). This small pack downloads automatically when media is configured and remains pinned.
- **Stage B:** all remaining daily/assistant-eligible assets download after the owner chooses **Download / update**.
- **Stage C:** relationship assets download only after relationship policy is enabled and the owner chooses **Download relationship media**.
- `chr_011` and `chr_022` are never selected by automatic or normal owner-initiated pack downloads. The lower-level scope requires an explicit owner override flag to admit an excluded asset.
- Daily/assistant requests cannot download an asset that does not allow that mode. Relationship requests require an owner action. Private requests require both an owner action and an active authorized private session.

No production private-vault route or claim was added. Phase 5 private authorization remains fail closed; production private mode remains a Phase 10 concern.

## Download, integrity, and atomic completion

Downloads stream to `chr_NNN.mp4.partial`. Existing partial length is sent through an HTTP Range request. A server that ignores Range causes the temporary file to restart from zero. A complete valid partial is finalized without another request; an overlong/corrupt partial is quarantined.

Retryable conditions are connection/transport failures plus HTTP 408, 429, and 5xx. Other HTTP errors fail without retry. Backoff is 250 ms, 500 ms, then the final attempt. Pause interrupts active streams while retaining resumable partials; resume continues the batch. Cancellation removes a partial by default. At no point is a partial indexed as ready.

Before completion the verifier checks the canonical asset ID, expected final/temporary filename, exact byte size, MP4 container marker, and SHA-256. A mismatch is quarantined and retried within policy. The verified temporary file replaces the destination with a recoverable rename sequence; a failed replacement restores the prior valid file.

## Cache and offline behavior

The default budget is 1 GiB and can be changed through `CharacterCachePolicy`. Stage A files are pinned. Other files are evicted by `last_used_at`, oldest first. Pinned, currently initializing/playing, and preloading assets are excluded from eviction. **Clear non-essential cache** applies the same protection rules. Settings show status, cached count, total bytes, manifest version, download/update, pause/resume, relationship download when allowed, and cache cleanup.

After relaunch without network, the index and files are re-opened and integrity checked against the last-known-good manifest. Verified local video resolves directly to `VideoStage`; a missing or invalid file yields the existing poster/silhouette fallback without blocking chat.

## Publishing and local fixture server

`tools/media_vault/publish_media.py` validates the runtime manifest and every processed video, then creates this Git-external layout:

```text
manifest/character_manifest.json
assets/chr_001.mp4 ... chr_043.mp4
posters/chr_NNN.poster.jpg
posters/chr_NNN.blur.jpg
integrity.json
```

The generated local package is at `C:\Users\Administrator\Downloads\Hana\builds\phase6_7_media_publish` (outside the repository and covered by the existing ignored `builds/` area): 43 videos, 86 posters, 141,744,179 total bytes, and an integrity record for every asset. The source `assets_source` and `assets_processed` trees were read only.

`tools/media_vault/serve_media.py` serves the manifest and assets with HTTP byte ranges. `--fail-first`, `--corrupt-asset`, and `--offline` provide deterministic retry, integrity, and offline simulations. Local smoke validation returned 43 manifest assets and HTTP 206 with the expected `Content-Range` for a resumed video request.

## UI and developer diagnostics

The home stage remains edge-to-edge portrait with `BoxFit.cover` or the existing focal-point-aware `contain_blur` behavior. The chat and composer remain overlays. The bootstrap notice now includes the media state while keeping the original no-media message and silhouette.

The release settings screen exposes only owner-safe media actions and no local path. The dev-only Character Lab adds states, allowed modes, sensitivity, download/integrity/cache state, and a play/test stage. Its route remains controlled by `BuildCapabilities.developerSurfaces`; no private development control is added to release routing.

## Tests and local evidence

Local validation on 2026-09-19:

| Check | Result |
| --- | --- |
| `flutter analyze` | PASS — no issues |
| `flutter test` | PASS — 167/167 (153 baseline + 14 Phase 6.7) |
| Focused Phase 6.7 suite | PASS — 14/14 |
| Existing widget/full-screen/keyboard suite | PASS — 13/13 |
| Publish package verification | PASS — 43/43 SHA-256 and size checks |
| Fixture manifest request | PASS — 43 assets |
| Fixture resumed asset request | PASS — HTTP 206 and valid content range |

Phase 6.7 coverage includes empty-vault launch, valid/invalid/LKG manifests, future count above 43, interrupted partial resume, retry/backoff, pause/resume/cancel, hash quarantine, atomic completion, index persistence, LRU, pinned/currently-playing protection, offline cached resolution, missing fallback, mode/excluded enforcement, and mute enforcement. Existing suites retain canonical 43/count/policy/private-gate and controller-cap coverage.

## CI and IPA audit

The macOS workflow now accepts the non-secret media URL defines and explicitly fails if an IPA entry ends in `.mp4` or contains `assets_processed`/`assets_source`. Its evidence artifact includes `ipa-media-audit.txt`.

GitHub macOS CI result: **PENDING final pushed commit**.

The publish package remains external and is not copied into `app/assets`, the Xcode project, Git history, Runner.app, or the IPA.

## Physical iPhone checklist

Status: **REAL_DEVICE_VALIDATION_PENDING** — no physical iPhone was available in this environment. Do not treat this as a device pass.

1. Fresh-install the unsigned/signed test build.
2. Confirm there is no local media and the full-screen silhouette is visible.
3. Confirm chat stays usable while media status is visible.
4. Configure a reachable HTTPS media host and bootstrap Stage A.
5. Confirm an idle video starts muted and fills the portrait viewport.
6. Exercise thinking, talking, and reaction transitions and confirm expected cached clips.
7. Kill and relaunch the app.
8. Confirm cached video starts again.
9. Disable network access.
10. Confirm cached character playback remains available and media status reports offline separately.
11. Restore network access.
12. Choose **Download / update** and download remaining daily/assistant media.
13. Enable relationship policy, explicitly download relationship media, and verify no private gate was bypassed.
14. Verify cached count, bytes, manifest version, and pause/resume controls in Character Media settings.
15. Clear non-essential cache; confirm pinned/current playback remains and normal playback recovers.
16. Confirm source video is inaudible throughout and Hana speech still comes only from TTS.

## Remaining validation

- Final GitHub macOS simulator build, XCTest, unsigned device build, credential scan, IPA media audit, and unsigned IPA artifact must complete after push.
- Physical iPhone network/download/playback remains `REAL_DEVICE_VALIDATION_PENDING`.
- Production private mode remains intentionally incomplete until Phase 10.
