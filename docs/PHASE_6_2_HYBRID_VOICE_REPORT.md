# Phase 6.2 — Hybrid text + voice

> **Superseded for active TTS by Phase 6.3 (2026-09-17):** the ElevenLabs live blocker below is historical and is not a Phase 6.3/V1 dependency. V1 is now iOS-only and uses local `AVSpeechSynthesizer`; Deepgram remains the server-side STT choice. Android APK/ADB/emulator evidence in this report is historical and must not be used as a future V1 gate.

Date: 2026-09-17. Scope: Phase 6.2 only. No Phase 7 work was performed.

## Verdict

**PHASE 6.2 — BLOCKED.** The implementation, fake/local integration, migrations, Docker stack, Flutter tests, analyzer, and staging cold launch pass. Live Deepgram STT, live ElevenLabs TTS, and therefore real PTT end-to-end cannot be run because `DEEPGRAM_API_KEY`, `ELEVENLABS_API_KEY`, and `ELEVENLABS_VOICE_ID` are absent from process/user/machine environment and `backend/.env`. Fake providers are not counted as live evidence.

## 1. Architecture

- LLM traffic remains server-side through `NineRouterClient`.
- STT production wiring selects `DeepgramSpeechToTextProvider` directly.
- TTS production wiring selects `ElevenLabsTextToSpeechProvider` directly.
- Provider interfaces and deterministic fakes remain in the domain voice boundary; HTTP provider implementations live under `app/integrations`.
- `AI_FAKE`, `STT_PROVIDER`, and `TTS_PROVIDER` are independent. A real LLM can be combined with fake/live audio without coupling provider selection.
- Flutter sends semantic mode and response preferences only. It contains no provider name, model ID, voice ID, or API key.
- The obsolete 9Router audio adapter was removed. No runtime code calls 9Router audio endpoints.

Server-side defaults/mappings:

| Alias/purpose | Server route |
|---|---|
| `hana_chat` | `cx/gpt-5.6-terra` |
| `hana_chat_fallback` | `cx/gpt-5.6-sol` |
| `hana_relationship` | `xai/grok-4.6` |
| `hana_relationship_fallback` | `xai/grok-4.5` |
| `hana_private` | `xai/grok-4.6` (production private route remains disabled) |
| `hana_private_fallback` | `xai/grok-4.5` (production private route remains disabled) |
| `hana_stt` | Deepgram `nova-3`, language `vi` |
| `hana_tts` | ElevenLabs `eleven_flash_v2_5`, configured voice ID |

Deepgram's official prerecorded API uses raw audio at `POST /v1/listen` with `Authorization: Token`, and its official model/language table lists Nova-3 Vietnamese `vi`: <https://developers.deepgram.com/docs/pre-recorded-audio>, <https://developers.deepgram.com/docs/models-languages-overview>.

ElevenLabs' official API uses `POST /v1/text-to-speech/{voice_id}`, `xi-api-key`, and an audio output format query: <https://elevenlabs.io/docs/api-reference/text-to-speech/convert>. The default is `eleven_flash_v2_5`, because ElevenLabs' language documentation lists Vietnamese for Flash v2.5 but not Multilingual v2: <https://elevenlabs.io/docs/overview/capabilities/text-to-speech>.

## 2. Text and response modes

Three explicit modes are implemented and persisted locally with secure storage:

- `AUTO` (default): typed input is text-only; PTT input requests a voice reply.
- `TEXT_ONLY`: typed or PTT input returns text without TTS.
- `VOICE_REPLY`: typed or PTT input requests TTS when auto-play is enabled.

`Auto-play voice` is independently persisted. Turning it off prevents automatic synthesis in all modes; the per-message speaker button remains available. The backend stores `response_mode` and resolved `speak`, so worker restart does not lose the decision.

Local-stack proof for typed `AUTO`:

- `reply.ready` and `turn.completed` were emitted;
- no `tts.segment` was emitted;
- the reply remained persisted and usable;
- manual `POST /v1/turns/{turn_id}/speech` subsequently returned authenticated media segments without changing the completed turn state.

## 3. PTT, STT, and transcript handling

Flutter retains explicit press/hold recording, release-to-submit, cancel gesture, minimum duration, permission handling, temporary file deletion, and transcript rendering from `transcript.final`. It never auto-records or records in the background.

Deepgram adapter behavior:

- raw short-clip upload with validated MIME and the API's `Token` header;
- configured `nova-3`, `language=vi`, and `smart_format=true`;
- bounded two-attempt retry only for network/timeout, 429, and 5xx;
- no retry for invalid request/auth;
- latency, duration, and request ID parsed internally;
- empty transcript remains a safe `STT_EMPTY` terminal path;
- raw input media is deleted in `finally` after the STT attempt;
- turn cancellation cancels the in-flight provider task and prevents a stale result.

Live Vietnamese accuracy and latency: **BLOCKED — no Deepgram credential/audio-provider call was made.**

## 4. TTS and text-first delivery

The assistant message is persisted and `reply.ready` is emitted before TTS synthesis begins. TTS failure emits `tts.failed` but the turn still reaches `turn.completed`; it does not roll back text.

ElevenLabs adapter behavior:

- voice ID, model, key, and output format are server configuration only;
- Vietnamese `language_code=vi` and MP3 `mp3_44100_128` output;
- bounded retry only for network/timeout, 429, and 5xx;
- no retry for 400/401/403/422;
- cancellation propagates to the HTTP task;
- response must be non-empty with an `audio/*` MIME;
- latency and provider request ID are captured internally, while SSE exposes only neutral `tts_latency_ms`.

Live voice quality, stable voice, valid paid-provider audio, and latency: **BLOCKED — ElevenLabs key and voice ID are absent.**

## 5. Flutter playback and Character Engine

- Settings expose AUTO/Text only/Voice reply and auto-play on/off.
- Each assistant message exposes play/stop controls.
- `just_audio` remains the only Hana speech playback path; source videos remain mute.
- Provider completion never directly changes the Character Engine. Playback callbacks emit `TtsStarted`, `TtsFinished`, `TtsFailed`, or `TtsStoppedByUser` with turn correlation.
- An early `TtsStarted` callback is buffered until the Phase 5 thinking minimum dwell and TTS gate are ready. Completion during that window is settled safely, preventing a stuck `thinking` state.
- Barge-in stops audio, cancels the previous turn where applicable, enters listening, and stale old-turn audio is rejected.
- Manual playback is rejected while a different active turn is running.

Flutter regressions cover AUTO typed silence, AUTO PTT voice selection, TEXT_ONLY PTT, manual speaker playback, talking-to-idle, barge-in, stale events, cancellation, background terminal events, duplicate SSE, and Phase 5 timer stress.

## 6. Semantic routing

Daily/assistant/work route to the chat family. Relationship mode can be selected only when the existing owner policy enables it and routes server-side to the relationship family. Flutter sends `daily` or `relationship`, never an `xai/*` or `cx/*` identifier. Retryable primary failures now make one bounded call to the matching fallback family. Private AI requests are rejected with `PRIVATE_MODE_DISABLED`; Phase 10 security work is still required.

Real results:

- GPT chat and GPT fallback retain the live Phase 6.1 evidence (`cx/gpt-5.6-terra` and `cx/gpt-5.6-sol`).
- Grok IDs were advertised by 9Router in Phase 6.1, but a new real relationship/private Grok turn was not run in Phase 6.2 because the transient 9Router secret was previously removed. Routing and fallback are unit/local-stack verified, not claimed live.

## 7. Storage and cleanup

- STT upload limit remains 2 MiB, duration 400–62000 ms, with the accepted audio MIME allowlist.
- Raw STT audio TTL metadata is 15 minutes, and the physical file is deleted immediately after the STT attempt.
- TTS audio is private authenticated media, default expiry 24 hours, never a public static directory.
- TTS cache is bounded to 100 MiB by oldest-file pruning.
- The leader scheduler deletes expired media files and rows in batches every minute.

## 8. Failure behavior

| Scenario | Result |
|---|---|
| STT error/empty | No LLM call without transcript; retry/re-record UX; terminal concerned response |
| LLM transient failure | One matching server-side fallback; otherwise existing safe terminal error |
| TTS unavailable | Text reply stays persisted/displayed; `tts.failed`; turn completes |
| Playback failure | Talking state terminates; text remains visible |
| Provider task cancelled | HTTP coroutine is cancelled and stale result cannot mutate a new turn |
| Typed chat while STT unavailable | Independent path; completes normally |

## 9. Tests and verification

Backend final source:

- normal pytest: **100 passed, 2 skipped** (Docker stack and paid live-provider modules opt-in);
- local Docker stack pytest: **107 passed, 1 skipped** (paid live-provider module skipped); the API/worker/scheduler images were rebuilt from the final source after removal of the legacy 9Router audio adapter;
- Ruff: **PASS**;
- clean DB `alembic upgrade head`: **PASS**;
- upgraded DB head: `0002_hybrid_voice_modes`;
- final Docker status: API, worker, scheduler, PostgreSQL, and Redis running; API/PostgreSQL/Redis healthy; local `/readyz` reports API/DB/Redis OK and 9Router intentionally fake.

Flutter:

- `flutter test`: **135 passed**;
- `flutter analyze`: **PASS, no issues**;
- staging x86_64 debug APK: **PASS** (`app-staging-debug.apk`, test build number 5001);
- ADB unauthorized condition: **resolved**; AVD appeared as `device`;
- APK install: **PASS**;
- cold launch: **PASS**; Hana process stayed alive, `MainActivity` was top-resumed, and the accessibility tree showed Home Chat, text input, send, PTT, state `idle`, Settings, and Character Lab;
- app fatal errors: none observed. The TV system image itself logged an unrelated SystemUI volume drawable failure;
- a complete emulator text/PTT/audio interaction was **not** achieved because the TV AVD exited during coordinate-driven input, and live audio credentials were absent.

Paid-provider tests are in a separate `live_voice` pytest module and require `RUN_HANA_LIVE_VOICE=1`. Normal CI never invokes paid APIs.

## 10. Security

- Boolean credential audit: Deepgram key absent; ElevenLabs key and voice ID absent.
- No Deepgram, ElevenLabs, 9Router key, provider name, model ID, or voice ID exists in Flutter source.
- No key is hard-coded in domain or integration code; `.env.example` contains empty placeholders only.
- Prompt logging remains off by default; provider adapters do not log audio, transcript, text, headers, or secrets.
- Private AI stays disabled and S3-F3 remains a Phase 10 blocker: production private timing must use elapsed realtime/CLOCK_BOOTTIME.
- CharacterCue boundary remains semantic; API/SSE does not send asset metadata.

## 11. Measured latency

No paid-provider latency is reported because no live call occurred. Reporting fake latency as live would violate the pass gate.

| Measure | Result |
|---|---|
| Deepgram STT latency | BLOCKED — credentials absent |
| 9Router LLM TTFT/total in Phase 6.2 | Not re-measured; live Phase 6.1 chat remains the latest evidence |
| ElevenLabs TTS latency | BLOCKED — credentials/voice absent |
| Real PTT end-to-end latency | BLOCKED — STT/TTS live gates absent |

## 12. Remaining blockers

1. Provision `DEEPGRAM_API_KEY` server-side and a non-sensitive Vietnamese fixture, then run the opt-in live STT test.
2. Provision `ELEVENLABS_API_KEY` and a selected Vietnamese-compatible `ELEVENLABS_VOICE_ID`, then run the opt-in live TTS test and listen for voice suitability.
3. Run the full real PTT path on a stable phone/portrait AVD and record STT, LLM, TTS, and end-to-end latency.
4. Optionally re-inject the 9Router secret to live-verify the Grok relationship route. Private production mode must remain disabled.

The implementation is ready for those integration credentials, but the Phase 6.2 live pass gate is not met. No Phase 7 work was started.
