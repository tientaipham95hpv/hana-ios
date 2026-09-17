# Phase 6.3 — iOS-only migration and native TTS

Date: 2026-09-17. Scope: Phase 6.3 only. Phase 7 and IPA/GitHub Actions packaging were not started.

## Verdict

**PHASE 6.3 — BLOCKED.** The iOS migration, Flutter/native boundary, canonical documentation, regression tests, analyzer, backend tests, and security checks are complete. The mandatory unsigned iOS release build, Swift compilation, installed `vi-VN` voice enumeration, and device/simulator playback cannot be verified on the current Windows host because Flutter does not expose the `ios` build target without macOS/Xcode. Deepgram live STT is separately blocked by a missing server key and does not by itself fail this migration gate.

## 1. iOS-only product decision

- `PRD.md`, `ARCHITECTURE.md`, `VOICE_SPEC.md`, and `ACCEPTANCE_CRITERIA.md` now make Flutter iOS the sole V1 client target.
- Android source remains temporarily to avoid risky deletion of working shared code, but Android/APK/AAB/ADB/emulator evidence cannot block or satisfy future V1 acceptance.
- `PHASE_6_2_HYBRID_VOICE_REPORT.md` is explicitly marked historical for ElevenLabs/Android evidence.
- Active routing is backend → 9Router for LLM, backend → Deepgram for STT, and Flutter → iOS platform channel → `AVSpeechSynthesizer` for TTS.

## 2. Native iOS TTS implementation

The new iOS scaffold contains a Swift platform bridge in `ios/Runner/AppDelegate.swift` and a correlated Dart adapter in `lib/voice/ios_native_tts.dart`.

Implemented behavior:

- `AVSpeechSynthesizer`, default language `vi-VN`;
- enumeration of installed Vietnamese voices with name, identifier, locale, and quality;
- no hard-coded voice identifier;
- persisted optional voice identifier, rate, pitch, and volume;
- bounded native values: rate `0.10…0.65`, pitch `0.50…2.00`, volume `0…1`;
- start, finish, cancellation, setup-error, and stop handling;
- utterance token `turn_id:generation`; stale callback rejection happens before Character Engine dispatch;
- manual per-message speech uses existing reply text and does not call the backend `/speech` endpoint;
- iOS clients explicitly send `speak=false`, so backend TTS/ElevenLabs is inactive for this path;
- text remains visible and successful if native speech fails or is cancelled.

ElevenLabs code remains only as an inactive optional backend adapter. No ElevenLabs key or live call is required by Phase 6.3.

## 3. Voice Lab

Developer Settings exposes an internal iOS Voice Lab with:

- installed `vi-*` voice list;
- voice name, identifier, locale, and quality;
- persisted voice selection;
- rate, pitch, and volume controls;
- the required two-sentence Vietnamese preview;
- play and stop controls.

Actual available voices and selected test voice: **BLOCKED — no macOS/iOS simulator or iPhone is connected to this Windows host.** The app intentionally falls back to the system `vi-VN` voice until the owner selects an enumerated identifier.

## 4. Audio session, microphone, and lifecycle

The Swift bridge implements:

- `AVAudioRecorder` AAC/M4A, 16 kHz mono for explicit PTT;
- `AVAudioSession.playAndRecord` with `measurement` while recording and `spokenAudio` while speaking;
- Bluetooth/headphone-compatible category options where iOS permits them;
- mutual exclusion between recording and speech;
- session deactivation with `notifyOthersOnDeactivation`;
- phone/Siri audio interruption handling;
- old-device route-loss handling;
- background cancellation for recording and speech;
- monotonic recording duration using `ProcessInfo.systemUptime`;
- temporary cache file deletion and canonical-directory validation.

`Info.plist` contains `NSMicrophoneUsageDescription` and is portrait-only. Permission states `notDetermined`, `granted`, `denied`, and `restricted` are represented in Flutter. Denied/restricted PTT shows an Open Settings action while text chat remains available.

Native interruption tests on a real iOS runtime: **BLOCKED by missing macOS/iOS tooling.** Dart/Character Engine interruption and stale-callback regressions pass.

## 5. Response modes and Character Engine

- `AUTO`: typed messages remain text-only; PTT replies use native speech when auto-play is enabled.
- `TEXT_ONLY`: typed/PTT responses never auto-speak.
- `VOICE_REPLY`: typed/PTT responses use native speech when auto-play is enabled.
- Manual speaker remains available independently of auto-play.

Regression coverage proves native PTT disables server TTS, reply text is spoken locally, manual speech avoids the backend audio endpoint, interruption leaves neither `listening` nor `talking` stuck, backgrounding before native `didStart` settles the requested turn, and callbacks from utterance A cannot mutate turn B. Existing Phase 5 timer/background protections remain green.

## 6. Deepgram STT

- Adapter/config remain server-only: `nova-3`, language `vi`.
- `DEEPGRAM_API_KEY`: absent from process, user, machine, and backend `.env` checks.
- Live Vietnamese STT and full PTT end-to-end: **BLOCKED separately by missing Deepgram credential.** No fake result is reported as live.

## 7. 9Router GPT/Grok

The server environment currently contains a 9Router key, so the opt-in live suite was rerun against the configured VPS without logging the key or content:

- GPT `cx/gpt-5.6-terra`: **PASS**; returned a strict envelope accepted by `ChatEnvelope`; response metadata reported `gpt-5.6-terra`; no forbidden asset metadata was present.
- Relationship primary `xai/grok-4.6`: **BLOCKED/UNAVAILABLE**, HTTP 503 after bounded retry.
- Relationship fallback `xai/grok-4.5`: **BLOCKED/UNAVAILABLE**, HTTP 503.

The opt-in test is excluded from normal CI and contains no credential. Server-side alias routing and fallback behavior remain covered by local tests.

## 8. Text chat and PTT status

- Typed text chat, SSE, text-first rendering, AUTO/TEXT_ONLY/VOICE_REPLY, retry, cancellation, and stale-event behavior: **PASS in Flutter/local tests**.
- PTT recorder → upload → fake/local STT → LLM → reply → native-speech abstraction: **PASS in tests**.
- Full PTT on iPhone/iOS Simulator with live Deepgram and native playback: **BLOCKED** by missing Deepgram key and iOS host/device.

## 9. Verification results

| Check | Result |
|---|---|
| Flutter tests | **146 passed** |
| `flutter analyze` | **PASS — no issues** |
| Backend default pytest | **100 passed, 3 skipped** (stack, paid voice, live 9Router opt-in modules) |
| Ruff | **PASS** |
| Phase 6.2 Docker baseline | **107 passed, 1 skipped** before adding the new opt-in 9Router module |
| iOS Swift/XCTest | **BLOCKED — no macOS/Xcode** |
| `flutter build ios --release --no-codesign` | **BLOCKED**; Windows Flutter reports no `ios` build subcommand/target |
| iOS device/simulator Voice Lab | **BLOCKED — no iOS runtime** |

`flutter doctor -v` confirms Flutter 3.47.4 on Microsoft Windows and lists no Xcode/iOS device toolchain. Therefore this report does not claim the Swift code compiled or native audio played.

## 10. Security

- Flutter/iOS client scan contains no Deepgram, ElevenLabs, or 9Router key, provider model ID, Bearer header, or voice secret.
- 9Router and Deepgram credentials remain backend-only.
- Native TTS requires no cloud credential and creates no TTS audio blob.
- No secret value is written to this report or test output.
- Private production remains disabled. Existing S3-F3 stays tracked: production private inactivity timing requires elapsed realtime/CLOCK_BOOTTIME-equivalent guarantees before Phase 10 enablement.
- iOS has no direct `FLAG_SECURE` equivalent; lifecycle privacy overlay remains, and this is not treated as production-private protection.

## 11. Remaining blockers

1. On macOS with supported Xcode, run `flutter build ios --release --no-codesign` and the `RunnerTests` target; resolve any Swift/compiler/signing-independent issue.
2. On an iPhone or iOS Simulator, enumerate installed `vi-VN` voices, record the list, select/QA a test voice, and verify preview start/finish/stop.
3. Validate AVAudioSession with backgrounding, phone/Siri interruption, Bluetooth/headphone route loss, PTT barge-in, and a second turn.
4. Provision `DEEPGRAM_API_KEY` server-side and run live Vietnamese STT/full PTT latency validation.
5. Restore the Grok primary/fallback routes behind 9Router; both returned HTTP 503 during this verification.

No Phase 7 or IPA/GitHub Actions packaging work was performed.
