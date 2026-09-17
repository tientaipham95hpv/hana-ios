# HANA Phase 5.2 - Event and Timer Fix Report

## Result

**PHASE 5.2 - PASS**

- Fixed S2 findings: **3/3** (`S2-R1`, `S2-R2`, `S2-R3`).
- Test suite: **115/115 passed**.
- Adversarial stress: **PASS**.
- `flutter analyze`: **PASS** (no issues found).
- Android staging verification: **PASS**.
- Production release signing: **PASS (fail-closed as required)**.
- Phase 6 work: **not started**.

## S2-R1 - Stale turn timer cancels or mutates a new turn

### Root cause

Turn-related scheduled effects were guarded only by a timer tag/generation token. A callback from an already completed, cancelled, or failed turn could survive long enough to be delivered after a new turn became active. The reducer did not independently verify that the callback belonged to the currently active turn.

### Fix

- `Tick` and `ScheduleTick` now carry both a generation token and an optional `turnId` owner.
- Every turn-owned timer is scheduled with the active turn ID.
- A turn tick is processed only when both conditions hold:
  - its token matches the current generation for that timer tag; and
  - its `turnId` matches `state.currentTurnId`.
- Turn-owned timer generations are invalidated and their scheduled effects are cancelled on terminal paths, including cancellation, failure, TTS failure/completion, timeout, and barge-in.
- Turn-owned tags include TTS wait/playback limits, pre-speech, thinking dwell/rotation, and turn overlays.

This establishes the invariant that a timer created for turn A cannot mutate turn B, including when IDs are reused and when an old callback arrives after A/B/C rapid turnover.

### Regression coverage

- cancel A -> start B -> timeout A does not change B;
- fail A -> start B -> timeout A does not change B;
- `TtsFailed` A -> start B -> timeout A does not change B;
- stale pre-speech timer;
- stale TTS-wait timeout;
- rapid A/B/C sequence;
- reused turn ID with stale generation;
- explicit wrong-owner and wrong-generation ticks.

## S2-R2 - Background event loss and stuck engine

### Root cause

The paused reducer path treated pause as a blanket event filter. Normal TTS could continue while the app was in the background, but terminal events such as `TtsFinished`, `TtsFailed`, `TurnFailed`, and `TurnCancelled` could be discarded. On resume, state could therefore remain incorrectly stuck in `talking` or `thinking`.

### Fix

- Pause now suppresses foreground/UI input and visual-only activity, not all events.
- Lifecycle-critical turn, TTS, job-terminal, private-lock, and required terminal timeout events continue to update logical state while paused.
- Background TTS completion closes the turn or completes the post-speech reaction transition as appropriate.
- A ten-minute TTS playback watchdog provides a final convergence path if an audio boundary never emits finish/failure. Normal completion and barge-in cancel it.
- The existing paused-input regression test was renamed because its old broad name encoded the incorrect implication that all paused events were ignored. Its valid assertion—that foreground `PttPressed` is ignored while paused—was retained.

### Regression coverage

- talking -> pause -> `TtsFinished` -> resume;
- thinking -> pause -> `TurnFailed` -> resume;
- talking -> pause for two hours -> resume;
- pause -> `TurnCancelled` -> resume;
- multiple stale background events;
- post-speech reaction completion in background;
- background start timeout and playback watchdog;
- pause/resume terminal-event stress.

The engine state now reflects events that actually happened in the background and resumes from the converged logical state instead of remaining stuck.

## S2-R3 - Private 15-minute auto-lock early-wake race

### Root cause

The inactivity timer assumed its callback could not run before the verification clock reached the deadline. If it woke early, the policy correctly refused to lock, but the callback did not schedule the remaining interval, leaving the private session open indefinitely without further activity.

### Fix

- The callback recomputes elapsed time from the injected clock and `lastPrivateActivity`.
- At or after 15 minutes, it locks.
- Before 15 minutes, it schedules a new timer for `deadline - now`.
- User activity updates the last-activity timestamp, cancels the previous inactivity timer, and schedules the new deadline.
- Unlock establishes the initial activity/deadline state.
- Lock cancels private timers and clears inactivity state.
- Clock, timer driver, and unlock service are injectable for deterministic tests.

### Regression coverage

- 14:59 does not lock;
- 15:00 locks;
- wake five seconds early reschedules;
- repeated early wakes eventually lock;
- activity at 14:59 resets the deadline;
- 300 seeded randomized early-wake iterations;
- one simulated hour without activity is locked;
- background auto-lock boundary at 59/60 seconds for the staging debug harness.

## Adversarial and stress verification

`test/phase5_2_stress_test.dart` passed:

- **10,000** deterministic randomized turn/timer/lifecycle events, seed `5202026`;
- stale timer owners and generations;
- pause/resume interleaved with terminal events;
- **300** randomized private sessions with early/late timer jitter and repeated activity resets, seed `152026`.

Observed invariants:

- no crash;
- no wrong-turn mutation;
- no permanently stuck engine;
- no private session surviving its inactivity deadline without activity.

## Test and analysis results

- Exact command `flutter analyze`: **PASS**, no issues found.
- Exact command `flutter test`: **PASS**, **115/115 tests**.
- The suite contains the original 89 tests (with one incorrect paused-event test description corrected) plus Phase 5.2 regression, related-S3, and stress tests.
- Flutter printed informational notices that 12 newer package versions are incompatible with the current constraints; this did not affect analysis or tests.

## Android verification

### Build and static APK audit

The staging release build succeeded for all configured ABIs:

| ABI | APK size |
| --- | ---: |
| armeabi-v7a | 15,215,734 bytes |
| arm64-v8a | 18,095,640 bytes |
| x86_64 | 19,574,935 bytes |

The arm64 staging APK audit passed: 66 archive entries, zero packaged videos, 43 source-name checks, and zero failures.

### Emulator

- AVD: `Television_4K`, Android API 36, x86_64.
- Staging release installed and cold-launched successfully (`LaunchState: COLD`, 2,930 ms).
- A current staging-debug APK was then installed to exercise the debug-only private harness and mock TTS.
- Normal flow opened Home and Settings without fatal errors.
- Mock TTS was started, the app was backgrounded until completion, and resumed. The UI returned through the terminal reaction to `idle`; it was not stuck in `talking` or `thinking`.
- The private developer harness opened with `Context: private`. After background inactivity it auto-locked and returned to Settings on resume.
- Final log inspection found no fatal Android or Flutter errors.

The exact 15-minute/early-wake policy was verified deterministically in widget and stress tests rather than waiting 15 real minutes on the emulator. The emulator exercised the staging harness's 60-second background lock path.

### Production fail-closed check

`flutter build apk --release --flavor production --no-pub` failed intentionally with the expected message that production signing is not configured and a debug key must never be used. Production therefore remains fail-closed when the keystore is absent.

## Related low-risk S3 work completed

- Added a dedicated private engine effect executor and timer driver. Lock disposes/cancels the private runtime's effects.
- Prevented normal-engine resume/dispatch while the private route/session is active. Normal resumes only when private lock completes.
- Rejected invalid or expired private authorization before pausing normal runtime.
- Removed the stale generated release APKs at:
  - `app/build/app/outputs/flutter-apk/app-release.apk`;
  - `app/build/app/outputs/apk/release/app-release.apk`.

Both removed files were the old 178,184,695-byte generated artifact. Source was not changed to conceal an audit finding; the current per-ABI staging outputs were rebuilt from source. Removal is recoverable only from backup or by rebuilding.

## Remaining S3 findings

The following lower-severity work remains outside Phase 5.2 scope:

- final Phase 6 TTS interruption/`TtsStoppedByUser` contract;
- remaining `VideoStage` initialization-completion and one-shot activity edge coverage not related to the three fixed S2 defects;
- APK auditor automation for ELF/signature/size/debuggable checks;
- an older generated legacy `app-debug.apk` remains and should be handled by the broader artifact-cleanup policy;
- adaptive timeout/backoff, codec classification, initialization-while-paused, and unnecessary media re-selection improvements;
- nested private-route `popUntil` behavior and secure restoration on disposal;
- other previously recorded resolver, policy, vault, cue-registry, property-test, and late-future S3 improvements.

No remaining S3 item invalidates the three S2 fixes or Phase 5.2 pass criteria.

## Re-audit readiness

All three Phase 5 re-audit S2 reproducers are now represented by passing in-repository regressions. Analysis, full tests, adversarial stress, staging builds, emulator flows, APK content audit, and production fail-closed behavior pass. Phase 5.2 is ready for independent re-audit.
