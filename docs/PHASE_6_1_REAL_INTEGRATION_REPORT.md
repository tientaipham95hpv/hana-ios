# Phase 6.1 — VPS 9Router real integration verification

Date: 2026-09-17. Scope: Windows host, existing Hana Docker stack, and the user-confirmed VPS 9Router. No Phase 7 work or local 9Router installation was performed.

## 1. 9Router status and endpoint

The verified integration endpoint is `http://185.185.80.197:20128/v1`. An unauthenticated Windows-host `GET /models` reached the VPS and returned HTTP 401. A Bearer-authenticated request, with an existing secret held only in process memory, returned HTTP 200 and 21 model records. This confirms network reachability and that Bearer authentication is required.

The endpoint is plain HTTP. It is acceptable only for this controlled integration test. Production must use HTTPS or a private authenticated tunnel; provider prompts, replies, audio, and credentials must not cross an unencrypted public path.

## 2. Models and alias mapping

`/v1/models` exposed chat routes in two namespaces: `cx/*` and `xai/*`. Observed IDs included `cx/gpt-6-astra`, `cx/gpt-5.6-sol`, `cx/gpt-5.6-terra`, `cx/gpt-5.6-luna`, their review variants, earlier GPT routes, and several `xai/grok-*` routes. No advertised STT or TTS model ID was present.

| Hana alias | Integration value | Result |
|---|---|---|
| `hana_chat` | `cx/gpt-5.6-terra` | PASS; response metadata reported `gpt-5.6-terra` |
| `hana_chat_fallback` | `cx/gpt-5.6-sol` | PASS via `purpose=output_repair`; `gpt-5.6-sol`, validated envelope |
| `hana_stt` | `hana_stt` requested | FAIL; VPS audio route lacks provider credential |
| `hana_tts` | `hana_tts` requested | FAIL; VPS audio route lacks provider credential |

Compose accepts all mappings through environment interpolation. No provider-specific model or VPS IP was added to domain code.

## 3. Connectivity

- Windows host: authenticated `GET /v1/models` → HTTP 200, 21 models.
- `hana-api`: `AI_FAKE=false`, authenticated `GET /v1/models` → HTTP 200, 21 models.
- `hana-worker`: `AI_FAKE=false`, authenticated `GET /v1/models` → HTTP 200, 21 models.
- During the live window `/readyz` reported `nine_router: ok` while API, DB, and Redis remained ready.

The secret and live URL were injected only as environment variables for recreated API/worker containers. They were not written to `.env`, source, image instructions, Flutter, or this report. After testing, API/worker were recreated with the default local `AI_FAKE=true` environment and no VPS key. Final inspection of API, worker, and scheduler confirmed `AI_FAKE=true`, no configured key, and no VPS IP in their environments; all five Hana services were running and API/Postgres/Redis were healthy.

## 4. Real chat through Hana

The path was Hana API → Redis/ARQ → Hana worker → `NineRouterClient` → VPS 9Router → real model → envelope validation → PostgreSQL → Redis SSE.

The first live attempt failed closed with `LLM_INVALID_OUTPUT` because the model returned invalid enum/type values. The backend prompt was made explicit about each required field, enum, and forbidden metadata; temperature was reduced to 0.2. This is a protocol-contract correction, not provider-specific domain logic.

The second live turn passed:

- persisted state `completed`, no error;
- valid Vietnamese reply;
- DB `llm_calls`: `gpt-5.6-terra|ok`;
- semantic CharacterCue: `happy/low/greeting/daily` plus cue ID/source/reason;
- SSE: `turn.accepted`, `turn.progress`, `reply.ready`, `character.cue`, `turn.completed`;
- `Last-Event-ID` replay omitted the consumed event;
- no asset ID, filename, path, allowed modes, delivery class, sensitivity, or weight leaked.

`hana_chat_fallback` was separately invoked through the real worker adapter and returned a schema-valid v1 envelope from `gpt-5.6-sol`.

Flutter could not be re-driven during the final live window because the only installed headless Android TV AVD came up `adb unauthorized`; no AVD data or ADB key was reset. The Flutter HTTP/SSE adapter was already proven against Hana in Phase 6, but this report does not claim a fresh live-provider Flutter UI pass.

## 5. Real STT

**FAIL.** A valid one-second, 16 kHz mono silence WAV generated locally was sent as non-sensitive multipart data using `httpx`, matching the Hana adapter shape:

- endpoint: `POST /v1/audio/transcriptions`;
- requested model: `hana_stt`;
- result: HTTP 400;
- response: `No credentials for provider: openai` (`invalid_request_error`, `bad_request`).

A voice turn through Hana using generated non-sensitive M4A reached the real provider path, persisted `STT_FAILED`, emitted concerned fallback `reply.ready`/`character.cue`, then `turn.failed`. No transcript was invented. Vietnamese accuracy and successful UTF-8 transcript remain unverified.

## 6. Real TTS

**FAIL.** A non-sensitive Vietnamese sentence was posted to `POST /v1/audio/speech`:

- requested model/voice: `hana_tts` / `hana`;
- result: HTTP 400;
- response: `No credentials for provider: openai` (`invalid_request_error`, `bad_request`).

A real Hana text turn with `speak=true` still persisted/displayed the LLM reply and completed safely. SSE contained `tts.failed` and zero `tts.segment` events. This validates graceful degradation, not real audio or playback. Fake audio is not counted.

## 7. Error handling and tests

Observed live failures were auth 401 without Bearer, initial invalid AI semantics, STT credential 400, and TTS credential 400. All converged without crash or fabricated success. Mock tests still cover 401/403/404/422 no-retry, invalid model alias, bounded 429/5xx retry, timeout, JSON-mode fallback, and audio retry.

- focused protocol/gateway suite: 35 passed;
- full backend without opt-in stack: 74 passed, 1 skipped;
- full backend with local-stack tests: 79 passed;
- `ruff check .`: pass;
- previous Flutter analyzer remained clean; no Flutter code changed in 6.1.

## 8. Security

- API key did not enter Flutter, Git-tracked config, report, command output, or application logs.
- Boolean scan found no key, Bearer header, or live prompt in Hana API/worker logs.
- Prompt logging remains off; private production routes remain disabled.
- Tests used public-style text and generated silence; no private content was sent.
- Semantic cue/SSE inspection found no asset metadata leak.
- Live environment was removed by recreating API/worker with local defaults.
- Production must replace public HTTP with HTTPS or a private authenticated tunnel.

## 9. Blockers and verdict

VPS connectivity and real chat are verified. The exact blocker is VPS audio provider configuration: both audio endpoints exist but cannot execute because the routed OpenAI provider has no credentials. Configure real STT/TTS provider credentials and working model/voice aliases, then repeat transcription, synthesis, Flutter playback, and quality tests. The AVD authorization problem also prevents a fresh Flutter live UI observation.

**PHASE 6.1 — FAIL.** Backend connectivity: PASS. Real chat: PASS. Real STT: FAIL (HTTP 400). Real TTS: FAIL (HTTP 400). The all-three live pass gate is not met. No Phase 7 work was performed.
