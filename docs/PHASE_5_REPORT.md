# HANA PHASE 5 — FLUTTER APP + CHARACTER ENGINE

Status: **PASS**

## 1. Flutter version

- Flutter **3.47.4** stable, framework revision `9584c6713b`.
- Dart **3.13.3**; DevTools **2.60.0**.
- Application root: `repo/app`.
- V1 target: Android only.

## 2. Package choices

- State management: `flutter_riverpod 3.4.3`.
- Local storage scaffolding: `drift 2.28.2`, `sqlite3 2.9.4`, `sqlite3_flutter_libs 0.5.40`.
- HTTP and secure storage scaffolding: `dio 5.11.1`, `flutter_secure_storage 11.1.1`.
- Video: `video_player 2.14.0` behind `VideoControllerPort`.
- TTS/audio: `HanaTts` and `HanaAudioOutput` interfaces with a no-op Phase 5 implementation. There is no real TTS or audio backend in this phase.
- The database and API clients are scaffolds only; no backend, AI, STT, or TTS integration was added.

## 3. Module structure

The app is divided into `app`, `core`, `character/{engine,manifest,resolver,stage,policy,lab}`, `chat`, `voice`, `tasks`, `reminders`, `work_journal`, `memory`, `companion`, `relationship`, `private_mode`, and `settings`. Feature modules outside the Character Engine contain boundaries/placeholders rather than Phase 6 business logic.

## 4. Character Engine implementation

- The reducer is pure Dart and has no direct I/O.
- It accepts semantic cues and app events only. Network/LLM payloads containing `asset_id`, path, or filename are ignored by cue parsing.
- All ten core states are supported: `idle`, `listening`, `talking`, `thinking`, `happy`, `shy`, `surprised`, `concerned`, `working`, and `sleep`.
- Implemented events include app start/activity/lifecycle, PTT press/release/cancel, turn submit/reply/fail/cancel, TTS start/finish/fail, jobs, semantic cues, and clip end/error.
- `Clock` and RNG are injected. Tests use `FakeClock` and seeded RNG; a 500-event randomized sequence verifies reducer stability and private context isolation.

## 5. Manifest loader

`CharacterManifestLoader` accepts the canonical v1.2 master schema and validates exactly 43 assets, sequential unique IDs, sensitivity, allowed modes, state pools, weights, exclusions, quality, playback/loop fields, audio count, SHA-256, delivery, render metadata, and safe relative paths. It accepts documented boundary aliases but normalizes them into one internal schema.

The test suite parses the real Phase 4 `character_manifest.json` and verifies:

- Assets: **43**.
- Enabled/excluded by default: **41 / 2**.
- Review assets: **19**.
- Poor assets: exactly `chr_011` and `chr_022` with their required policy.
- Default mode candidates derived from metadata: daily **15**, assistant **15**, relationship **41**, private **41**.

Malformed or invalid manifests fail closed to the stage fallback rather than crashing the application.

## 6. Resolver

The resolver receives mode/stage context, requested state, intensity, owner policy, recent usage, ready posters/media, broken assets, relationship gating, and private session status. It returns an internal `PlayRequest` or a poster/silhouette result.

It enforces allowed modes, excluded-by-default overrides, broken/missing assets, private-session requirements, lowest sensitivity for daily/assistant, primary-loop preference, review asset eligibility, poor asset variant behavior, intensity matching, recent-use avoidance, and injected weighted random selection. It never accepts a media identifier from the LLM/backend.

## 7. Mode policy

- Daily/assistant only select the lowest sensitivity tier present in the eligible state pool.
- Relationship requests fall closed to daily behavior until `relationship_stage_enabled=true`.
- Private context requires an active private session.
- No fallback step borrows an asset outside the effective mode.
- Review assets remain eligible; poor/excluded assets require owner enablement and cannot displace a healthy primary loop.

## 8. Fallback behavior

The implemented chain is:

1. requested-state pool in the effective mode;
2. idle pool in the effective mode;
3. daily-compatible requested/idle pool for assistant or relationship fallback;
4. eligible still poster;
5. silhouette.

The known daily/assistant gaps for `surprised`, `concerned`, `working`, and `sleep` therefore do not crash or fail the build. Discreet mode resolves directly to silhouette.

## 9. VideoStage

- Two crossfade slots are used, with an explicit maximum of three controllers including optional preload capacity.
- Incoming media initializes while the current front remains visible; initialization has a 1,500 ms timeout.
- A poster/silhouette remains below video to prevent black flashes.
- `cover` uses the manifest focal point; `contain_blur` uses the shipped blur poster as the cover layer and renders video/poster with `BoxFit.contain`. No realtime blur is performed.
- Loop/oneshot behavior follows manifest metadata. Oneshot completion emits `ClipEnded`; initialization/playback failure emits `ClipError`.
- Poster/silhouette transitions dispose active playback, and lifecycle pause/resume pauses or resumes controllers.
- `VideoPlayerOptions(mixWithOthers: true)` is set. The adapter rejects every nonzero volume, and `setVolume(0.0)` runs before `play()`.

## 10. Vault abstraction

`CharacterAssetRepository` has `MockVaultAssetRepository` and traversal-safe `LocalDevVaultAssetRepository` implementations. Video, poster, and blur-poster lookups use manifest-relative paths. The production app starts with an empty mock vault and displays silhouette/poster fallback until media is available.

The local development repository can be selected with `HANA_DEV_VAULT_ROOT`. No processed production video is listed in `pubspec.yaml`.

## 11. Private isolation

`CharacterEngineSessionManager` owns a persistent normal session and creates a separate private engine instance only when the mock private route opens. Private context and history are held by that instance. Lock destroys the private session; private events are not replayed into normal state. The normal resolver treats an injected private context as daily unless a private session is active.

Android screenshot blocking is scaffolded through `FLAG_SECURE` and a MethodChannel. Real server-side PIN verification remains outside Phase 5.

## 12. Owner policy

The local policy contains relationship/discreet/screenshot flags and per-clip enabled, allowed-mode, and weight overrides. A Settings mock demonstrates per-clip sensitive expansion: adding a higher-sensitivity sample to daily/assistant first raises `SensitiveModeConfirmationRequired` and only applies after the explicit `confirm_sensitive` dialog. The LLM has no owner-policy mutation path.

## 13. Character Lab

The debug route exposes mode, stage context, all ten core states, emotion, intensity, cues/reactions, internal asset ID, sensitivity, modes, effective weight, loop grade, playback kind, review/excluded flags, pool size, and the complete fallback trace.

Mock flows cover idle → listening → thinking → talking → happy → idle, idle → working → idle, and normal → private engine → lock → normal idle. On the Android emulator, Character Lab opened successfully and an `idle` → `talking` selection produced a two-candidate pool and a valid play request.

## 14. Tests

- Command: `flutter test --no-pub --reporter compact`.
- Result: **53/53 PASS**.
- Coverage includes manifest parsing and failure cases; duplicate IDs and traversal; real 43-asset counts; mode/sensitivity rules; relationship gating; private isolation/lock; owner overrides and `confirm_sensitive`; review/poor/excluded assets; weighted deterministic selection; repetition avoidance; state and cross-mode fallback; missing/corrupt media; engine transition table; PTT/barge-in and TTS flow; lifecycle; FakeClock; seeded RNG; randomized event sequences; forced video mute; completion/error relay; render modes/focal point; fallback disposal; vault repository; APK bundle policy; and core UI routes.

## 15. Static analysis

- Command: `flutter analyze --no-pub`.
- Result: **PASS — No issues found**.

## 16. Android build and run

- Build command: `flutter build apk --debug --target-platform android-x64 --no-pub`.
- Build result: **PASS**.
- Emulator: `sdk_google_atv64_x86_64`, Android **16**, API **36**, ABI `x86_64`.
- Install: **PASS** via streamed ADB install.
- Cold launch: **PASS**, `com.hana.hana_app/.MainActivity` foreground; final measured launch time **8,573 ms** on the TV emulator.
- Runtime log: **0** `FATAL EXCEPTION`, AndroidRuntime fatal, or `E/flutter` lines after launch.
- Accessibility tree showed `Hana`, `Character Lab`, `Cài đặt`, `Đang chờ thư viện vault`, and `Mic placeholder`.
- Final debug APK: **454,845,355 bytes**, SHA-256 `c075de37b7b58d9ea0ea421976a2010524ad6af17eb67fa199223fecbb73248c`.
- APK scan: **0** video entries and **0** `assets_source`, `assets_processed`, or production-manifest path leaks.

## 17. Known limitations

- Production vault download, encryption/decryption, cache eviction, and manifest sync are Phase 6 work. The emulator run intentionally exercised the no-vault fallback; it did not copy Phase 4 media into the APK.
- Backend, AI, real STT/TTS, real PIN verification, and server policy sync are absent by scope.
- The debug x64 APK is large because Flutter engine native symbols are retained in this local debug build. Release signing, symbol splitting, and size optimization are still required before distribution.
- Seventeen suggestive sensitivity labels and Phase 3.2 state mappings remain provisional; Phase 5 preserves those labels and does not visually reclassify assets.

## 18. Readiness for Phase 6

Phase 5 is ready for Phase 6. The Flutter Android shell, pure Character Engine, canonical manifest boundary, deterministic policy resolver, safe fallback chain, muted/render-aware VideoStage, vault interfaces, private session isolation, owner policy confirmation flow, Character Lab, test suite, static analysis, and Android runtime checks all pass. Phase 6 can connect authenticated APIs, vault delivery, and real audio services without exposing media identifiers to the LLM or changing the reducer contract.
