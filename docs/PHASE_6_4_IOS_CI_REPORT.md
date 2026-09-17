# Phase 6.4 — iOS CI and unsigned IPA

Date: 2026-09-17. Scope: Phase 6.4 only. Phase 7 was not started.

## Verdict

**PHASE 6.4 — BLOCKED.** The macOS workflow, locked Flutter setup, native XCTest coverage, simulator/device build gates, unsigned IPA packaging, bundle credential audit, metadata, and artifact upload are implemented. A successful GitHub Actions run cannot yet be produced from this checkout because it has no Git remote and this host has no authenticated GitHub tooling. The PASS gate explicitly requires a completed macOS run, so local Windows results are not substituted for that evidence.

## Workflow

- File: `.github/workflows/ios-unsigned.yml`
- Trigger: manual `workflow_dispatch` only; no paid/live provider test runs automatically.
- Runner: `macos-15`, a supported non-preview GitHub-hosted macOS label.
- Permissions: read-only repository contents.
- Concurrency: one run per ref; a newer run cancels an obsolete in-progress run.
- Timeout: 60 minutes.
- Flutter: exact `3.47.4` tag, matching `.metadata` revision `9584c6713b324636289d067944a46fd6b49df14b`.
- Dependencies: `flutter pub get --enforce-lockfile` followed by a byte comparison of `pubspec.lock`; no dependency upgrade is performed.
- CocoaPods: `pod install --deployment` only when an iOS `Podfile` exists. This project currently uses Flutter Swift Package Manager, so CocoaPods is not required.

The workflow records `flutter doctor -v`, Flutter/Dart versions, Xcode version, available SDKs, and macOS image information without reading or injecting provider secrets.

## Static and project validation

The workflow fails on any of the following:

- `flutter analyze` failure;
- any Flutter test failure;
- invalid `Info.plist`;
- missing `NSMicrophoneUsageDescription`;
- missing or invalid iOS deployment target (minimum accepted by the gate is iOS 13; the project target is iOS 15);
- missing simulator `Runner.app`;
- native XCTest failure;
- missing unsigned device `Runner.app`;
- client credential marker/file finding;
- corrupt or incorrectly structured IPA;
- missing artifact file.

Local re-validation on this Windows host after the Phase 6.4 changes:

| Check | Result |
|---|---|
| `flutter analyze` | **PASS — no issues** |
| `flutter test` | **146 passed** |
| Workflow YAML load/static inspection | **PASS; all 13 shell blocks pass `bash -n`** |
| `git diff --check` for Phase 6.4 files | **PASS** |
| Flutter/iOS source credential and provider-model scan | **PASS** |

These local results validate shared Dart code only; they are not counted as the required macOS/iOS build evidence.

## iOS simulator and native tests

The workflow performs:

1. `flutter build ios --simulator --debug` and verifies `build/ios/iphonesimulator/Runner.app`.
2. Selection and boot of an available iPhone simulator.
3. `xcodebuild test` for the `Runner` scheme using the simulator's normal local/ad-hoc handling; no Apple certificate or provisioning profile is supplied.

`RunnerTests.swift` now verifies:

- `AVSpeechSynthesizer` initializes in an idle state;
- every installed Vietnamese voice exposes non-empty canonical name/identifier/locale metadata;
- the microphone usage description exists.

Flutter tests continue to cover platform-channel start/finish/cancel callbacks, stale utterance suppression, interruption/background lifecycle, and Character Engine convergence. CI always records `VOICE_RUNTIME_VALIDATION_PENDING`: headless compilation and metadata tests do not certify audible Vietnamese quality, and an absent `vi-VN` voice asset does not fail the build.

The simulator XCTest host validates launch/bridge compilation. A separate brittle UI/audio-hardware smoke test is intentionally not added; physical-device Voice Lab evaluation remains the appropriate runtime gate.

## Unsigned device build and IPA

The workflow runs `flutter build ios --release --no-codesign` and requires:

`build/ios/iphoneos/Runner.app`

It copies that app to `Payload/Runner.app`, creates `Hana-unsigned.ipa` with `zip`, runs an archive integrity test, and rejects entries outside the expected payload hierarchy. It also creates `Runner.app.zip` for direct inspection. No identity, certificate, provisioning profile, or fake signature is created.

## Client security audit

Before packaging, every file in the built `Runner.app` is checked for:

- provider secret environment variable markers for Deepgram, 9Router, and ElevenLabs;
- private-key and service-account markers;
- `.env`, service-account JSON, provider config plist/JSON, private key, certificate, and provisioning-profile filenames.

Only paths are printed on failure; matching content is never printed. The scan intentionally does not mistake the `flutter_secure_storage` framework name for a credential file. Deepgram and 9Router remain backend-only, and no provider secret is supplied to this workflow.

Built-bundle scan result: **PENDING the first macOS Actions run.** The Phase 6.3 source/client scan remains PASS, but it cannot replace inspection of the compiled app.

## Build metadata and artifacts

`build-info.txt` contains:

- Git commit SHA;
- Flutter and Dart versions;
- Xcode and iOS SDK versions;
- macOS and GitHub runner-image versions;
- app version and build number;
- UTC build timestamp;
- `unsigned=true`;
- voice runtime status.

Expected Actions artifact name: **`hana-ios-unsigned`** (14-day retention), containing:

- `Hana-unsigned.ipa`;
- `Runner.app.zip`;
- `build-info.txt`;
- analysis, test, build, Xcode, plist, IPA, and secret-scan evidence files under `ci-evidence/`.

Artifact status: **NOT CREATED — no GitHub Actions run exists yet.**

## Required run evidence

| Gate | Status |
|---|---|
| GitHub Actions macOS workflow | **BLOCKED — no repository remote/run** |
| Xcode version / iOS SDK | **PENDING — captured by workflow** |
| Flutter analyze | **PASS locally; CI PENDING** |
| Flutter tests | **146 passed locally; CI PENDING** |
| Simulator build | **PENDING** |
| Native TTS bridge compilation/XCTest | **PENDING** |
| Device release `--no-codesign` build | **PENDING** |
| `Runner.app` produced | **PENDING** |
| Unsigned IPA and payload verification | **PENDING** |
| Built-client secret scan | **PENDING** |
| `hana-ios-unsigned` artifact upload | **PENDING** |

Exact blocker evidence from this checkout:

- `git remote -v`: no entries;
- current branch: `main`;
- `gh --version`: command not installed;
- therefore there is no Actions run ID/URL, commit on GitHub, or downloadable artifact that can be truthfully reported.

To close the gate, attach this checkout to the intended GitHub repository, commit/push the Phase 6 code plus `.github/workflows/ios-unsigned.yml`, dispatch **iOS unsigned validation**, and retain the successful run URL/ID and artifact digest. No Apple signing or provider secret is needed.

## External items intentionally pending

- Deepgram live STT: still pending a backend-only credential; not a Phase 6.4 gate.
- Grok 4.6/4.5: latest live verification returned HTTP 503; not an iOS build blocker and routing was not changed.
- Vietnamese voice choice and subjective quality: pending Voice Lab validation on a physical iPhone.
- Physical-iPhone install: pending and not required for this unsigned CI phase.

Android acceptance, ElevenLabs, App Store signing, provisioning, production deployment, and Phase 7 remain out of scope.
