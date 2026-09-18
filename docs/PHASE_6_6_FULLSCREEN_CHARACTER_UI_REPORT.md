# Phase 6.6 — Full-Screen Character-First iOS UI Report

Date: 2026-09-17
Scope: Phase 6.6 only. Phase 7 was not started.

## Verdict

**LOCAL PASS; GitHub Actions/device gates pending in this report.**

The Hana home route is now portrait, character-first, and full-screen. The character stage occupies the viewport edge-to-edge; chat, status, errors, history, and the composer are overlays rather than a permanent vertical split.

## Previous layout

Phase 6.5 used a `Scaffold` with a `Column`: a fixed 260px character area, status/chat rows below it, chat history in an `Expanded` list, and a bottom composer. This made the character occupy only part of the iPhone screen and allowed the keyboard to produce an effectively split/shortened stage.

## New Stack-based layout

`app/lib/chat/home_screen.dart` now uses:

```text
Scaffold(resizeToAvoidBottomInset: false)
└── Stack (character-stage-root)
    ├── Positioned.fill character-stage-viewport
    ├── top SafeArea chrome/status/errors
    ├── chat overlay with compact recent bubbles/history
    ├── keyboard-aware composer overlay
    └── privacy overlay when required
```

The stage is driven by the existing Character Engine resolution and events. UI code does not select character assets directly.

## Edge-to-edge and video policy

- `CharacterStageBackground` in `app/lib/chat/character_stage.dart` renders full bleed.
- The stage is not wrapped in `SafeArea`; interactive chrome is.
- Composer uses bottom safe-area padding for the home indicator.
- The stage and silhouette fallback remain the same viewport size when the keyboard opens.
- Manifest-driven `BoxFit.cover`, focal alignment, `contain_blur`, poster fallback, and silhouette fallback are preserved.
- Existing `MutedVideoSession` remains the source of truth for muted playback.
- Crossfade, generation cancellation, clip completion, timeout, and controller disposal semantics remain preserved.
- No character videos were added to the IPA bundle.

## Chat and composer overlays

Recent messages render as compact translucent bubbles over the character. History can be expanded in a bounded scrollable surface through `conversation-history-toggle`. Assistant bubbles preserve speaker/replay behavior through `ChatController.playMessage` and `stopAudio`. The composer remains keyed as `composer-overlay` and retains text input, send, PTT, unavailable PTT state, and developer demo behavior.

`MediaQuery.viewInsets.bottom` moves the composer above the keyboard while `Scaffold.resizeToAvoidBottomInset` remains disabled so the character viewport is not resized. Expanded history is bounded for small screens.

## Backend and no-media states

Phase 6.5 behavior remains visible but unobtrusive: misconfigured, connecting, connected, and offline states; full-screen silhouette/poster fallback with `Character media not downloaded yet`; and explicit PTT-unavailable messaging.

## Portrait-only enforcement

- Flutter startup calls `SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp])`.
- iPhone, iPad, and base iOS Info.plist orientation arrays contain portrait only.
- `TARGETED_DEVICE_FAMILY` remains `1,2`; iPad support is not removed.
- Native XCTest coverage was added for the orientation arrays.

## Tests

New widget/layout coverage verifies the full-screen Stack and stage viewport, chat/composer overlays, no-media fallback, keyboard insets, composer positioning, small portrait controls, and backend/PTT readability.

```text
flutter analyze
No issues found!

flutter test test/app_widget_test.dart
All tests passed! 13 tests

flutter test
All tests passed! 153 tests
```

Phase 6.5 had 150 tests; Phase 6.6 adds three layout/keyboard/small-viewport tests.

## Real-device / CI evidence

A physical iPhone and macOS simulator are not available in this Windows session. The commit must be dispatched through `.github/workflows/ios-unsigned.yml` to produce simulator build, native XCTest, unsigned device release, credential audit, and `Hana-unsigned.ipa`.

The workflow accepts the existing non-secret `backend_enabled` and `backend_base_url` dispatch inputs. No provider or signing credentials are added.

## Remaining validation

Install the new IPA on a physical iPhone, capture portrait cold-launch evidence, verify repeated keyboard open/close, full-screen media fallback and vault video, native voice/PTT and Voice Lab, and a backend text reply with a reachable deployment URL.

Phase 7 was not started.