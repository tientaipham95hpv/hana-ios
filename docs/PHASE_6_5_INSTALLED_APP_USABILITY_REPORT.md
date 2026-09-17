# Phase 6.5 — Installed App Usability Report

Date: 2026-09-17
Scope: Phase 6.5 only. Phase 7 was not started.

## Current verdict

**LOCAL IMPLEMENTATION PASS; REAL-IPHONE/CI GATES PENDING.**

The app no longer relies on a blank or placeholder home state. The default route is the Hana home screen and it now visibly renders character fallback, backend status, chat history guidance, text input/send, PTT state, and settings/developer access where permitted.

The following local checks pass:

- `flutter analyze`: PASS, no issues.
- `flutter test`: PASS, 150 tests.
- Widget tests also pass with randomized ordering.
- No character videos were added to the IPA or Flutter bundle.

A physical iPhone, macOS signing/build runner, and live backend were not available in this work session, so the real-device and new unsigned IPA gates remain open.

## Root cause of “opens but has nothing”

The startup route was already `/` → `HomeScreen`; the app was not launching into Character Lab or a hidden route. The apparent empty screen came from several overlapping UX/configuration problems:

1. `main.dart` asynchronously loaded the manifest before calling `runApp`, so a manifest/bootstrap problem could delay visible UI.
2. The character repository used `MockVaultAssetRepository` in non-debug builds and contained no local media. The resolver therefore had no playable assets.
3. `HomeScreen` rendered a neutral colored block while the runtime had no resolution, rather than an explicitly labelled silhouette/media state.
4. When `HANA_BACKEND_ENABLED` was false, the bottom of the page rendered the literal `Chat placeholder` instead of the actual text controls.
5. Backend configuration had a default Android emulator URL (`http://10.0.2.2:18000`), which is not a usable iPhone production endpoint, and there was no visible configuration status.
6. PTT was not explained when voice/backend configuration was absent.

## Startup route

- `app/lib/main.dart` loads the bundled manifest and then starts `HanaApp`.
- `HanaApp` maps `/` to `HomeScreen`.
- Settings remains a secondary route.
- Character Lab, Private harness, and Voice Lab remain debug/internal surfaces only.
- Release-like route tests confirm that private and Character Lab cannot be bypassed.

## Changes made

### Home UI

`app/lib/chat/home_screen.dart` now always presents:

- Hana character area.
- Visible silhouette fallback when there is no resolution/media.
- `Character media not downloaded yet — silhouette shown.` notice when local vault media is unavailable.
- Chat history area with an actionable first-use message: `Chưa có tin nhắn — hãy nói “Xin chào Hana”`.
- Text input with `Nhắn Hana…` hint.
- Send button.
- PTT button that remains visible even when unavailable.
- Response semantic-mode control when enabled by owner policy.
- Backend status strip.
- Settings and debug access according to build capability.

The former `Chat placeholder` branch was removed.

### Backend configuration/status

`app/lib/backend/backend_config.dart` now:

- Treats the backend URL as missing unless explicitly supplied through `HANA_BACKEND_BASE_URL`.
- Validates HTTP/HTTPS URL shape.
- Exposes `BackendConnectionState` values: connected, connecting, offline, misconfigured.

The home screen visibly reports `Backend: Chưa cấu hình`, `Backend: Đang kết nối`, or `Backend: Ngoại tuyến` according to the safe local state. No secret or API key is displayed. Sending text while unconfigured produces an explicit Vietnamese configuration error rather than silently doing nothing.

A configured backend still uses the existing client flow:

iPhone → `POST /v1/turns` → backend orchestration/9Router → SSE events → visible assistant message.

### Media bootstrap

The existing Phase 4 vault-only media policy is preserved. The 43 videos are not bundled. The existing vault availability refresh remains in place, and the UI now makes the no-media state explicit while rendering a silhouette.

### PTT and voice

PTT remains visible in all states. If the backend/voice path is not configured, the UI shows:

`Voice input not configured`

If microphone access is denied, the UI preserves text chat and explains that microphone access must be enabled in Settings.

Voice Lab remains available from Settings in debug/internal builds. The existing iOS implementation enumerates voice name, identifier, locale, and quality and supports test playback.

### Developer surfaces

`BuildCapabilities` remains debug-gated. A small explanatory comment was added; production routes are not expanded.

## Test evidence

Updated `app/test/app_widget_test.dart` covers:

- cold launch never blank;
- visible backend status;
- no-media notice and silhouette fallback;
- visible text input and send controls;
- visible PTT unavailable state;
- explicit misconfigured backend state;
- manifest failure retaining the usable shell;
- release-like route restrictions;
- Voice Lab access from Settings.

Observed results:

```text
flutter analyze
No issues found!

flutter test
All tests passed! 150 tests
```

The widget suite also passed with randomized ordering, confirming the new cases are not dependent on test order.

## Real-device evidence

Not available in this session.

Required follow-up on a physical iPhone:

1. Build with an explicit non-secret `HANA_BACKEND_BASE_URL` pointing to the reachable Hana backend.
2. Cold launch and capture the home screen.
3. Confirm silhouette/media notice.
4. Enter `Xin chào Hana` and verify visible SSE reply.
5. Disconnect backend and verify Offline/error/retry behavior.
6. Deny microphone permission and verify text chat remains usable.
7. Open Voice Lab and capture the actual vi/vi-VN voice list and test playback.
8. Build/package a new unsigned IPA and reinstall it.

## Remaining blockers

- Physical iPhone validation and screenshots have not been performed here.
- The current repository workflow still builds without backend dart-defines; a deployment invocation must supply the environment-specific non-secret base URL. It must not put provider credentials in the client.
- No real health endpoint/probe was added. A configured but not-yet-proven endpoint is intentionally displayed as `Đang kết nối`, not falsely claimed as connected.
- CI production of the new `Hana-unsigned.ipa` and installation/retest are pending.
- No push to `origin/main` was performed.

## Phase boundary

Phase 7 was not started.
