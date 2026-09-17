# HANA Phase 5.1 — Security / Engine / Manifest / Release Fix Report

Status: **PHASE 5.1 PASS; ready for independent re-audit.** `PHASE_5_AUDIT.md` is the defect source of truth. All one S1 and eight S2 findings are addressed. This report supersedes inaccurate implementation claims in the historical `PHASE_5_REPORT.md` without changing it. No Phase 6 backend, 9Router, LLM, STT or TTS was integrated.

## Findings, root causes, fixes, regression mapping

| Finding | Root cause | Code fix | Regression evidence |
|---|---|---|---|
| S1-01 | `/private`, Settings mock shortcut and private engine creation lacked a release gate/proof; Home and private had separate runtimes | Release route map/developer UI are compile-time debug-gated. `PrivateUnlockService` returns unavailable in release; debug authorization is expiring and required by `openPrivate`. Shared runtime destroys private engine on lock, clears `prv_rt`, pops route, resets normal engine to idle/daily and restores home screenshot policy. Monotonic-clock auto-lock at background ≥60 seconds, private inactivity ≥15 minutes and authorization expiry. | `phase5_1_regression_test.dart` S1/59–60s/14:59–15m; `app_widget_test.dart` direct route/release-like guard and debug lock |
| S2-01 | Turn matcher accepted null active turn; clip/timer callbacks lacked generation; job completion overrode higher-priority activity | Exact active turn ID, playback `playId`, tagged timer token and orthogonal job ID. Barge-in closes previous turn; stale reply/TTS/clip/error/timer events are ignored; `JobFinished` cannot interrupt listening/thinking/talking/reaction. | `phase5_1_regression_test.dart` event correlation/priority; `character_engine_test.dart` |
| S2-02 | Reducer emitted effects but runtime dropped them; timers/sleep were unreachable | Pure reducer plus `EngineEffectExecutor` for Play, Preload, ScheduleTick, CancelTick, Pause/Resume, StopTts, ReleaseTtsGate and LogEngine. Cancellable system/fake timers cover thinking dwell/variant rotation, pre-speech max, overlay min/max, working max, day/quiet idle-to-sleep, context hold, TTS wait and transient retry. | `phase5_1_regression_test.dart` runtime/timers/sleep/reaction; `character_engine_test.dart` |
| S2-03 | Every activity oneshot `ClipEnded` ended the activity | Active thinking/talking/working clip reselects in the same activity; only the current reaction overlay exits after its minimum dwell. | `character_engine_test.dart`; play/overlay regression cases |
| S2-04 | Manifest path regex did not bind asset/path/delivery; kind/audio/cross-field invariants missing | Reject the *entire* manifest on unknown fields, wrong kind, ID/path owner, prefix/class, sensitivity/modes, delivery, nonzero audio/subtitle/data/attachment streams, unsafe path, runtime bounds or excluded policy. Resolver independently excludes nonzero audio. | `manifest_loader_test.dart` malformed matrix; `phase5_1_regression_test.dart` audio defense |
| S2-05 | Provider used a hard-coded demo; parse failure was unconnected to UI | `BundledPhase4ManifestRepository` loads allowlisted 44,053-byte metadata generated from the real 43-asset Phase 4 master; no production videos. Failed load/validation yields empty manifest, safe silhouette and working chat shell. Canonical master and snapshot are compared in tests. | `manifest_loader_test.dart` canonical comparison; `app_widget_test.dart` malformed failure fallback |
| S2-06 | In-flight player initialization uncounted; stale completions raced stage; timeout permanently quarantined | Count/cancel initializing controllers, cap live controllers at three, dispose stale/orphan controllers and superseded crossfades. Init timeout is transient with fallback/5-second retry; hard file/decode error quarantines. | `video_stage_test.dart` 50 rapid Play stress/timeout; transient retry regression |
| S2-07 | Home did not apply FLAG_SECURE; private followed owner-off; lock always cleared secure flag | Android MethodChannel sets FLAG_SECURE; Home computes `auto|always|off` from owner/library policy, private forces on, inactive overlay obscures stage, lock restores Home policy. Bootstrap/lock remove private runtime cache. | `phase5_1_regression_test.dart` coordinator lifecycle; widget private lock; Android emulator `dumpsys window` on/off check |
| S2-08 | `keepDebugSymbols` retained native DWARF; release silently used debug signing | Removed symbol retention, enabled R8/resource shrinking, icon tree shaking, split Dart debug info and per-ABI output. `productionRelease` fails explicitly without external `android/key.properties`; separately named `.staging` flavor is intentionally debug-signed. Temporary mapped-drive build removes Flutter's generated workspace URI; Kotlin incremental cache disabled for Windows cross-root plugin builds. | Expected negative production build; three APK audits, ELF sections, signature and emulator cold launch |

The original 53 tests remain conceptually represented. Expectations that encoded audited bugs were corrected: private now requires unlock proof; reaction completion requires its current play token/minimum dwell; TTS start follows reply/dwell; cancellation is only valid in listening; transient timeout differs from hard corruption; and demo-based “real asset” assertions were replaced by canonical Phase 4 data. New tests include adversarial malformed manifests and release-like route guards. The complete suite has 89 tests, not a claim that the unavailable Claude scratchpad file was copied.

## Verification

- `flutter analyze --no-pub`: **PASS**, no issues.
- `flutter test --no-pub --reporter expanded`: **89/89 PASS**.
- `flutter build apk --release --flavor production --no-pub`: **expected fail-closed** with `Production release signing is not configured. Create android/key.properties from key.properties.example; never use the debug key.` There is intentionally no distributable production APK until the owner supplies a keystore.
- `tool/build_staging_release.ps1`: **PASS**, release AOT obfuscated, Dart debug information split to `build/symbols/staging-shortpath`, icons tree-shaken. No universal APK built; per-ABI delivery is the Android V1 strategy. Debug APK size is not a release metric.
- Final x86_64 artifact installed on `emulator-5554` (Android TV x86_64), force-stopped and cold-launched in 3.1 seconds. UI hierarchy showed Hana and `Đang chờ thư viện vault` fallback; Settings showed private disabled/unavailable with no Character Lab. `AndroidRuntime:E`/`flutter:E` logcat was empty. Chat shell fallback is also asserted by widget tests.
- Android FLAG_SECURE: selecting `always` in Settings showed `SECURE` in the Activity's `dumpsys window` flags; selecting `off` removed it. Restored `auto`. Private route is deliberately unreachable in this release-like artifact; private lifecycle is covered with coordinator/widget tests.
- `tool/audit_apk.ps1`: **PASS on all three ABIs**, 0 production videos, 0/43 source filename stems, no `source_asset_map`, media source/workspace paths, developer/mock private strings, signing passwords or private-key markers, and no unexpected media. It scans entry names, Flutter assets, native libraries, DEX, resources and Android manifest. The sanitized 44,053-byte manifest is metadata, not media.
- NDK `llvm-readelf -S` confirms APK `libflutter.so` and `libapp.so` have no `.debug*`, `.symtab` or `.strtab` sections. `apksigner verify --print-certs` passes and identifies the explicitly debug-signed staging certificate (`CN=Android Debug`).

| ABI staging APK | Bytes | Approx. MiB | Largest entries |
|---|---:|---:|---|
| armeabi-v7a | 15,199,350 | 14.5 | `libflutter.so`, `libapp.so`, `classes.dex`, `libsqlite3.so` |
| arm64-v8a | 18,095,640 | 17.3 | same native/runtime components |
| x86_64 | 19,574,935 | 18.7 | `libflutter.so` 13,051,424 B; `libapp.so` 3,736,456 B; `classes.dex` 1,784,056 B; `libsqlite3.so` 1,553,624 B |

The initially installed NDK was metadata-only and lacked `llvm-strip`; two incomplete directories were removed and a clean NDK 28.2 installation was used for these successful builds. A first staging artifact still contained `Downloads/Hana` in Flutter's generated plugin registrant URI. Rebuilding via a temporary neutral drive eliminated it; the final artifacts above all passed the stricter string audit.

## Signing and reproducible build

Create `android/key.properties` from `android/key.properties.example`, point `storeFile` to an owner-controlled keystore and provide secrets only locally/through CI. Key and password files are gitignored. `stagingRelease` has application ID suffix `.staging`, version suffix `-staging` and intentionally uses the Android debug certificate; do **not** distribute it as production.

From `repo/app`:

```powershell
powershell -File tool/build_staging_release.ps1
powershell -File tool/audit_apk.ps1 -Apk build/app/outputs/flutter-apk/app-x86_64-staging-release.apk
```

The build script temporarily maps the app to `H:` (only if unused), compiles, then unmaps it in `finally`. Use `-Drive` for another unused letter. This avoids embedding the developer workspace URI in AOT. The APK auditor requires the Phase 4 source map and fails if the 43-stem reference is missing or any checked invariant fails.

## Remaining S3 and readiness

S3-01 deterministic reducer RNG is fixed by storing seed/counter in engine state. S3-07 developer UI and workspace path leakage are fixed for release-like builds; S3-09 historical report inaccuracies are superseded here. Remaining: S3-02 resolver variant/loop nuances; S3-03 persisted/fully validated owner policy/versioning (the `PolicyUpdated` reset aspect is fixed); S3-04 encrypted vault lease/cache architecture; S3-05 cue registry/network boundary; S3-06 10,000-step property testing; S3-08 late mock futures/asset refresh lifecycle. These do not authorize Phase 6 work.

**Ready for Phase 5.1 re-audit: PASS against the S1/S2 and release-like criteria.** Production distribution remains deliberately blocked pending the owner's real signing keystore; there is no production secret in the repo.
