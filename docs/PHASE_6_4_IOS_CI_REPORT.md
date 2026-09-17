# Phase 6.4.1 - iOS CI manifest regression

Date: 2026-09-17. Scope: Phase 6.4.1 only. Phase 7 was not started.

## Verdict

**PHASE 6.4.1 - PASS.** The canonical manifest regression is fixed, all 146 Flutter tests pass in GitHub Actions, and the simulator, native XCTest, unsigned device build, IPA integrity, credential audit, and artifact upload gates all pass.

Successful run: [iOS unsigned validation #4](https://github.com/tientaipham95hpv/hana-ios/actions/runs/35196881477)

- Run ID: `35196881477`
- Tested commit: `ee05e96f9934562dcfcb5177c1b1c34dbec61aec`
- Status: `completed / success`
- Started: `2026-09-17T07:54:30Z`
- Completed: `2026-09-17T08:05:34Z`

## Manifest root cause

There was no canonical/runtime schema difference. The original CI failure never reached sanitization or comparison. The test opened this workstation-only path:

`../../assets_processed/hana/character_manifest.json`

That path resolves outside the Git repository. It exists in the local Hana workspace, so the isolated test passed locally, but it does not exist in a clean GitHub Actions checkout. Run `35193206031` therefore failed with:

`PathNotFoundException: Cannot open file, path = '../../assets_processed/hana/character_manifest.json'`

The regression was a non-hermetic test fixture/path dependency, closest to category F (platform/checkout path difference), not a canonical data change, stale runtime snapshot, sanitizer regression, ordering issue, normalization mismatch, or accidental canonical mutation.

The repair commits an exact repository-owned Phase 4 master fixture at `app/test/fixtures/phase4_master_manifest.json` and points the test at it. The fixture is text-identical to the original processed master after normalizing line endings. The test now compares the complete sanitized JSON object with the checked-in runtime JSON before loading it, so unknown omissions or additions cannot hide behind the previous selected-field checks. Dart map/list equality remains semantic and does not depend on JSON object key order.

Neither `app/tool/sanitize_phase4_manifest.dart` nor `app/assets/character/character_manifest.json` was changed. Original processed source assets and the external canonical master were not modified.

## Preserved manifest invariants

Local inspection and the manifest/security suite confirm:

- exactly 43 assets and 43 unique sequential IDs;
- 41 enabled by default and 2 excluded by default;
- `chr_011` and `chr_022` remain `poor`, excluded by default, one-shot, and weight `0.2`;
- 19 review-flagged assets remain present;
- audio, subtitle, data, and attached-picture stream totals are all zero;
- path traversal and Windows absolute paths are rejected;
- forbidden shipping metadata and unknown metadata are rejected;
- invalid sensitivity/modes, delivery association, and private-vault policy fail closed;
- `allowed_modes`, `content_sensitivity`, vault delivery, and sanitized runtime schema remain enforced.

## Additional CI findings closed

After the manifest test passed in Actions, two existing downstream CI issues became visible:

1. Xcode 16.4 reported that `registrar(forPlugin:)` returns an optional `FlutterPluginRegistrar`. `AppDelegate.swift` now safely unwraps it before registering `HanaNativeBridge`.
2. The compiled-bundle audit used `sk[-_]...`, which can match ordinary compiled symbol substrings such as `sk_queue_identifier` inside `task_queue_identifier`. The workflow change is evidence-based: it requires a boundary-delimited `sk-...` token, preserves provider-name, bearer-token, PEM, service-account, generic API-key, and credential-file checks, and consumes the complete `strings` stream to avoid a `grep -q` broken-pipe diagnostic.

No other workflow behavior or validation gate was changed.

## Files changed

- `app/test/fixtures/phase4_master_manifest.json` - repository-owned canonical Phase 4 test fixture.
- `app/test/manifest_loader_test.dart` - hermetic fixture path plus complete sanitized-runtime semantic equality.
- `app/ios/Runner/AppDelegate.swift` - unwrap optional Flutter plugin registrar required by Xcode 16.4.
- `.github/workflows/ios-unsigned.yml` - remove the demonstrated compiled-symbol credential-scan false positive without removing security checks.
- `docs/PHASE_6_4_IOS_CI_REPORT.md` - this final evidence report.

## Local verification

Run from `app/` on Windows with Flutter `3.47.4` / Dart `3.13.3`:

| Check | Result |
|---|---|
| Isolated canonical/runtime regression test | PASS, 1/1 |
| `flutter test test/manifest_loader_test.dart` | PASS, 20/20 |
| `flutter test` | PASS, 146/146 |
| `flutter analyze` | PASS, no issues |
| Secret-pattern scan of changed manifest/test files | PASS, no finding |
| `git diff --check` before commits | PASS |

## GitHub Actions evidence

The successful run used:

- runner: `macos-15`, image `macos15-20260907.0337.1`;
- macOS `15.7.9`;
- Xcode `16.4`, build `16F6`;
- iOS device and simulator SDK `18.5`;
- Flutter `3.47.4`;
- Dart `3.13.3` on `macos_arm64`.

All final-run gates passed:

| Gate | Evidence |
|---|---|
| Flutter analyze | PASS, no issues found |
| Flutter tests | PASS, 146 passing lines, 0 failures; both manifest snapshot tests pass |
| Simulator build | PASS; `build/ios/iphonesimulator/Runner.app` produced |
| Native XCTest | PASS; 3/3 RunnerTests pass and Xcode reports `TEST SUCCEEDED` |
| Device release | PASS; `flutter build ios --release --no-codesign` produced `build/ios/iphoneos/Runner.app` (18.6 MB) |
| Built-client credential audit | PASS |
| IPA packaging/integrity | PASS; all entries are under `Payload/Runner.app/`, and `unzip -t` reports no errors |
| Artifact upload | PASS |

Native XCTest passed:

- `testMicrophoneUsageDescriptionIsPresent`
- `testSpeechSynthesizerInitializesIdle`
- `testVietnameseVoiceEnumerationMetadataIsCanonical`

As designed, subjective voice/audio validation remains `VOICE_RUNTIME_VALIDATION_PENDING`; it is not an unsigned CI gate.

## Artifact and unsigned IPA

- Artifact name: `hana-ios-unsigned`
- Artifact ID: `10486237372`
- Artifact size: `15,722,017` bytes
- Artifact digest: `sha256:7739d2754c8080f55f768dabbe182d840fdf92769a188f137a18b6a5ef8e38d1`
- Expires: `2026-10-01T08:05:30Z`
- Direct run artifact: [hana-ios-unsigned](https://github.com/tientaipham95hpv/hana-ios/actions/runs/35196881477/artifacts/10486237372)

Downloaded artifact contents were independently inspected:

- `Hana-unsigned.ipa` - `7,851,388` bytes; valid ZIP with `Payload/Runner.app/`.
- `Runner.app.zip` - `7,829,462` bytes.
- `build-info.txt` - records `unsigned=true` and the tested commit/toolchain.
- `ci-evidence/` - analysis, tests, simulator/device builds, XCTest, plist, credential scan, IPA entries/integrity, and toolchain evidence.

The IPA is intentionally unsigned; no signing identity, certificate, provisioning profile, or fake signature was used.

## Commit trail

- `d762428` - `fix: align canonical manifest runtime schema`
- `1c89a74` - `fix: unwrap iOS plugin registrar`
- `ee05e96` - `ci: avoid credential scan false positive`

Phase 7 was not started.
