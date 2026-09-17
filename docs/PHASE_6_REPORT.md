# Phase 6 — local backend + chat + voice V1 implementation report

Date: 2026-09-17. Scope: Windows local development only. No VPS, Phase 7 business features, production private authentication, or iOS.

## 1. Backend architecture

`backend/app` provides FastAPI routes, a PostgreSQL-backed turn orchestrator, an ARQ worker, adapters for chat/STT/TTS, a Character Director, Redis turn events, media storage, and a leader-lease scheduler skeleton. The API persists and enqueues; the worker owns the pipeline. Turn state is not held only in process memory.

## 2. Docker services

`infra/compose.dev.yml` starts PostgreSQL 16, Redis 7, `hana-api`, `hana-worker`, and `hana-scheduler` with healthchecks/readiness, restart policies, persistent named volumes, and host-only published ports. Defaults are `127.0.0.1:15432`, `:16379`, and `:18000` to avoid colliding with another local stack. The 9Router URL is environment-overridable; its default points to `http://host.docker.internal:20128/v1`. All five services were running; API, DB, and Redis were healthy.

## 3. DB schema and migration

Alembic baseline `0001_phase6` creates the `hana` schema and user/device, conversation, turn, message, LLM-call, media, audit, and minimal job-run tables. No Phase 7–9 business tables were added. UTC is set at database/session level; business dates use `Asia/Ho_Chi_Minh` via zoneinfo, not a fixed `+7`. Clean-database `alembic upgrade head` and downgrade/upgrade were exercised during stack bring-up; after final rebuild `alembic current` returned `0001_phase6 (head)`.

## 4. Redis

ARQ uses Redis for the worker queue; turn events use Redis Streams with TTL; cancellation uses a transient marker; rate limiting and scheduler leader lease use separate keys. PostgreSQL remains the source of truth. An expired event stream falls back to a persisted terminal snapshot.

## 5. Turn lifecycle

`POST /v1/turns` and `/v1/turns/voice` return 202 with a turn ID and events URL after persistence/enqueue. The worker advances through transcription (voice), context assembly, LLM, validated reply/cue, optional TTS, and terminal persistence. A client idempotency key prevents duplicate normal retries. Cancellation is terminal and idempotent; worker checks persisted terminal state before later writes. Manual local-stack probe queued a turn with worker stopped, restarted worker, and observed completion; a cancelled queued turn stayed cancelled after restart.

## 6. 9Router adapter

`NineRouterClient` uses alias-to-model configuration, connect/request timeout, bounded transient retry/backoff with jitter, no retry for invalid request/auth, cancellation propagation, and JSON-mode capability fallback. `NineRouterAudioProvider` calls OpenAI-compatible `/audio/transcriptions` and `/audio/speech`, with bounded retry and fresh multipart bytes on STT retry. Fake chat/STT/TTS adapters make tests independent of the live provider. Model aliases, URL, and optional API key are configuration, not domain constants or Flutter credentials.

## 7. AI envelope

The backend parses `hana.chat_envelope.v1` with strict semantic fields, validates JSON, requests one output repair where applicable, accepts only constrained safe plain text as recovery, and otherwise emits a concerned fallback. Unknown actions receive `ACTION_NOT_IMPLEMENTED` receipts and are never executed. The local fake now unwraps the user-data boundary and JSON-escapes the reply correctly; the boundary is not shown in the chat UI.

## 8. CharacterCue boundary

The backend emits only semantic emotion/intensity/special cue/context/reason. The client resolves visual assets locally. No asset ID, filename, path, weight, sensitivity, allowed modes, or delivery-class metadata is sent in cues or to the LLM. Phase 5 turn/timer correlation and background terminal-event convergence remain covered by the Flutter suite.

## 9. Chat text E2E

The Flutter Home Chat backend mode creates a real turn, follows SSE, shows the persisted reply, and drives the Character Engine. The final x86_64 staging APK was cold-launched on the installed Android TV AVD in portrait-size display; a UI-entered `Phase6 final text` produced `Em nghe anh nói: Phase6 final text`, with engine `idle` afterward. The normal-mode no-vault fallback remained visible; no hard-coded demo reply was used in backend mode.

## 10. Voice V1

Android PTT records through `MediaRecorder` after microphone permission, enforces a 400 ms minimum, uploads the temporary recording, and deletes it on success/failure. STT transcript is persisted and emitted; the normal turn pipeline then produces reply, segmented TTS media, and Character Engine talking/idle. Barge-in stops old TTS, cancels the old turn, and guards stale events. A voice upload failure now settles the local thinking state to concerned. On the final staging APK, emulator PTT produced `Xin chao Hana` transcript and assistant reply; after Home/background and resume the engine was `idle`.

## 11. STT/TTS

Provider interfaces include fake and 9Router adapters. TTS normalization/segmentation handles punctuation, numbers, common abbreviations, URL/email, emoji, and segment ordering. Audio is delivered through an authenticated app endpoint backed by private media keys and TTL, not a public static folder. The Flutter queue uses `just_audio`, turn correlation, generation invalidation, and one `TtsStarted` per turn. The local fake WAV path was exercised through the worker and emulator. Real 9Router STT/TTS model/voice support remains **unverified**.

## 12. SSE and reconnect

Events include turn ID, sequence, timestamp, type, and payload. The client sends `Last-Event-ID`, suppresses duplicate sequence processing, rejects malformed events, and applies only events correlated to its current turn. Terminal REST snapshots recover when Redis streams expire. The client now accepts a snapshot even if its sequence restarts at 1, and on exhausted SSE errors fetches persisted terminal state; stale asynchronous snapshots cannot mutate a later turn.

## 13. Error handling

Gateway auth/request failures do not retry; 429/5xx/timeout retry is bounded. Invalid AI output, empty/failed STT, failed TTS, unavailable gateway, network loss, malformed SSE, and failed voice upload have safe fallbacks. A text draft and client idempotency key survive a failed initial POST. If SSE and the REST snapshot endpoint are both unavailable, the current turn remains visible rather than inventing a terminal server state; recovery requires reconnection/retry.

## 14. Backend tests

`pytest -q`: **72 passed, 1 skipped** (the skip is the opt-in local-stack module). With `RUN_HANA_STACK_TESTS=1`, local Postgres/Redis/API/worker integration: **5 passed**. Coverage includes envelope validation/fallback, action rejection, semantic cues, persistence, idempotency, Redis/SSE replay, expired-stream snapshot, fake voice STT/TTS, audio access/TTL, worker retry policy, 9Router status/timeout and JSON-mode fallback, STT/TTS retry behavior, logging redaction, and timezone. `ruff check .`: pass.

## 15. Flutter tests

`flutter test --no-pub`: **130 passed**, including all 115 Phase 5 tests. New coverage includes API contract, SSE reconnect/duplicate/malformed/snapshot, turn correlation, text and fake voice flow, ordered TTS, barge-in, cancel, background terminal failure, network draft retention, REST recovery, stale snapshot, and voice-upload failure. `flutter analyze --no-pub`: **no issues**.

## 16. Real 9Router verification

**Blocked.** `http://127.0.0.1:20128/v1/models` refused connections on 2026-09-17; Windows had no listener on port 20128 and no running 9Router-named process. Local backend configuration is `AI_FAKE=true`, and no usable 9Router service/model credentials were present for an opt-in live suite. Therefore real chat completion, transcription, synthesis, alias mapping, provider voice quality, and real-provider E2E were not claimed as passing.

## 17. Security checks

The local `.env` and generated APK are gitignored; no Android keystore or `key.properties` was present. Production signing still fails closed without a keystore. The backend rejects dev-auth bypass or fake AI in staging/production, redacts structured log keys including authorization/token/audio/prompt/content, and defaults prompt logging off. Flutter does not call 9Router or carry its key. DB/Redis ports bind only to localhost. Private production routes/authentication are not enabled, and no private content path was connected to 9Router. Final arm64 APK audit: 0 video entries, all 43 forbidden source names checked, 0 failures. Emulator app/audio fatal-tag logcat: empty.

## 18. Limitations and remaining Phase 5 S3

- Real 9Router chat/STT/TTS and configured Hana voice cannot be verified until the host service, aliases, and optional credentials are supplied.
- The available emulator is an x86_64 Android TV AVD (resized to portrait), not a phone; local PTT transport and fake media playback pass, but hardware-specific microphone/audio quality is not certified.
- This phase intentionally has no production auth/private backend. **S3-F3** deep-sleep clock remains a blocker for future production private auto-lock; current private gate stays fail-closed. Remaining carry-over items are **S3-F4/S3-R5** stale debug artifacts and stronger ELF/signing audit (the staging build still warns about DWARF), **S3-F5** stress-harness gap, **S3-R6** VideoStage refinements, **S3-R7** private navigation/secure-window refinements, and **S3-R8** older visual/logging refinements. The touched **S3-F1/S3-R3** reaction/turn submission and **S3-F2** PTT pause paths were corrected without changing private production exposure.
- If both SSE and REST are offline after bounded reconnect, the UI reports loss of updates and retains the turn; automatic eventual recovery without a connection is not guaranteed.

## 19. Readiness for Phase 6 audit

Local fake-provider stack, migration, text/voice E2E, SSE recovery, tests, analysis, and emulator verification are ready for audit. **PHASE 6 — FAIL against the full pass gate**, solely because the required live 9Router chat integration and real STT/TTS provider capability have not been verified. Do not treat fake-provider success as live-provider success. No Phase 7 work was started.
