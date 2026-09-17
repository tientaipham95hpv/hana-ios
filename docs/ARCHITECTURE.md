# HANA — ARCHITECTURE

> **Phase 6.3 canonical override (2026-09-17):** V1 client is **Flutter iOS only**. Android source is retained only as non-gating migration residue. LLM remains backend → 9Router; STT is backend → Deepgram; TTS is Flutter → iOS platform channel → `AVSpeechSynthesizer`. The iOS client always requests `speak=false` from the backend and speaks the already-delivered reply text locally when AUTO/VOICE_REPLY/manual playback requires it. Earlier Android/APK/ADB, 9Router-STT/TTS, `just_audio` server-TTS, and server TTS-blob requirements in this document are retired for V1 wherever they conflict with this override.

Phiên bản: 1.2 (Phase 1 — foundation + Final Decision Patch + Phase 3.2 Asset Policy Patch)
Ngày: 2026-09-15
Trạng thái: CHỐT cho implementation. Mọi thay đổi phải cập nhật tài liệu này trước khi code.
Vị trí canonical: `repo/docs/` (version-control cùng source). Bản ở `Hana/docs/` chỉ là bản sao cũ giữ tạm, không chỉnh sửa tiếp.

Tài liệu liên quan: `PRD.md`, `CHARACTER_SYSTEM.md`, `AI_PROTOCOL.md`, `VOICE_SPEC.md`, `MEMORY_SPEC.md`, `WORK_JOURNAL_SPEC.md`, `STANDING_INSTRUCTIONS_SPEC.md`, `TIMEZONE_SPEC.md`, `PRIVACY_SPEC.md`, `ACCEPTANCE_CRITERIA.md`.

Quy ước từ khóa: **PHẢI** (MUST), **KHÔNG ĐƯỢC** (MUST NOT), **NÊN** (SHOULD), **CÓ THỂ** (MAY).

---

## 0. Tài liệu này là nguồn sự thật cho

- Ranh giới component và interface giữa chúng.
- Topology triển khai (Windows dev, VPS staging/production).
- Phân chia dữ liệu local (thiết bị) và server.
- REST API + SSE contract chung.
- Data model lõi (users, devices, turns, messages, media, tasks, reminders, notifications, audit).
- Job queue và scheduler.
- Security boundaries, failure modes, invariants tổng (INV-xx), mã lỗi, biến môi trường.

Các bảng dữ liệu chuyên biệt được định nghĩa trong spec riêng (xem §7.3 bảng chỉ mục). Mỗi bảng chỉ được định nghĩa ở **đúng một** tài liệu.

### 0.1 Quyết định chốt (Final Decision Patch, 2026-09-15)

| # | Quyết định | Chi tiết tại |
|---|---|---|
| D1 | Kỳ báo cáo tháng canonical là half-open `[ngày 15 tháng trước 00:00:00, ngày 15 tháng này 00:00:00)` Asia/Ho_Chi_Minh; UI: "Từ ngày 15 tháng trước đến hết ngày 14 tháng này"; không ngày nào thuộc hai kỳ; report tạo ngày 15 (sau khi kỳ đóng) hoặc muộn hơn; "báo cáo ngày 14" nếu có chỉ là wording UI | TIMEZONE_SPEC §9.2, STANDING_INSTRUCTIONS_SPEC §4.2, WORK_JOURNAL_SPEC §6.0 |
| D2 | **iOS là target release V1 duy nhất. Android ngoài phạm vi V1 acceptance.** | PRD §4.2; Phase 6.3 |
| D3 | FCM là tùy chọn ở mọi môi trường; local reminder hoạt động đầy đủ khi FCM chưa cấu hình | §3, §8.4, §8.6 |
| D4 | Mặc định cấu hình được: chào sáng 08:00, hỏi lại việc dang dở 14:00, hỏi thăm tối 21:30, quiet hours 23:00–07:00, cutoff ngày nghiệp vụ journal 04:00 | §7.2 `user_settings` |
| D5 | Private unlock: PIN 6 số là credential bắt buộc và luôn là fallback; biometric chỉ là lớp tiện lợi tùy chọn, không bao giờ là credential duy nhất | PRIVACY_SPEC §5.2–§5.3 |
| D6 | Tài liệu canonical ở `repo/docs/` | tiêu đề tài liệu |
| D7 | STT = Deepgram `nova-3`/`vi`; TTS = iOS `AVSpeechSynthesizer`/`vi-VN`; private LLM vẫn chưa enable production | AI_PROTOCOL §2.5, VOICE_SPEC §2 |
| D8 | **Asset policy (Phase 3.2, 2026-09-15):** dùng toàn bộ 43 video. Asset có hai trục tách biệt: `content_sensitivity ∈ {normal, suggestive, private}` (nội dung → cách phân phối/bảo vệ) và `allowed_modes ⊆ {daily, assistant, relationship, private}` (nơi hiển thị, owner override được). `daily`/`assistant` ưu tiên tier sensitivity thấp nhất trong pool; `relationship` chỉ khi owner bật; `private` dùng mọi asset được allow. Không yêu cầu asset riêng cho từng CoreState; thiếu → fallback, không fail build. Clip Phase 3 `reject` → `poor` + `excluded_by_default`; clip `review` → `review_flag`, không main-loop. LLM không bao giờ thấy/chọn asset; Character Engine chọn; video muted; voice chỉ TTS | CHARACTER_SYSTEM §2.5–§2.8, §4, §8.5, §11, §17; PRIVACY_SPEC §4.1; `PHASE_3_2_ASSET_POLICY_PATCH.md` |

---

## 1. Tổng quan hệ thống

```
┌──────────────────────────── iOS device (Flutter app) ────────────────────────────────┐
│  UI (chat, reminders, journal, reports, instructions, memory, settings)              │
│  Character Engine (pure Dart state machine) ─► VideoStage (2x video_player, muted)   │
│  VoiceRecorder (AVAudioRecorder) NativeTTS (AVSpeechSynthesizer, vi-VN)              │
│  LocalStore (drift/SQLite, normal only)  SecureStore (Keystore)  Outbox              │
│  LocalNotificationScheduler      AssetVault + PrivateVault (encrypted asset caches)  │
└───────────────┬──────────────────────────────────────────────────────▲───────────────┘
                │ HTTPS REST + SSE (JWT)                                │ FCM data msg
                ▼                                                       │
┌──────────────────────────── Server (Docker Compose) ─────────────────┴───────────────┐
│  Caddy (TLS, chỉ VPS) ─► api (FastAPI/uvicorn)                                         │
│                            │  enqueue            ▲ Redis Streams (turn events)         │
│                            ▼                     │                                     │
│                          redis (db0 normal, db1 private) ◄── worker (arq)              │
│                            ▲                          │   ├─ TurnOrchestrator          │
│                   leader lock / enqueue               │   ├─ PrivateTurnOrchestrator   │
│                          scheduler ───────────────────┘   ├─ Memory/Journal/Report jobs│
│                            │                              └─ Notification dispatcher ──┼─► FCM
│                            ▼                                                           │
│                          postgres (schema hana, schema hana_private)                   │
│                          blobstore (filesystem volume: media/, private_media/)         │
│                          9router (OpenAI-compatible gateway, server-side only) ─────────┼─► LLM providers
│                          Deepgram STT (server-side adapter)                            │
└────────────────────────────────────────────────────────────────────────────────────────┘

┌──────── Windows dev host (offline tooling) ────────┐
│ asset_pipeline (Python + ffmpeg/ffprobe)           │
│ assets_source (IMMUTABLE) ─► asset_analysis ─►     │
│ assets_processed/bundle        ─► mobile bundle    │
│ assets_processed/vault         ─► server vault     │
│ assets_processed/private_vault ─► server private   │
└────────────────────────────────────────────────────┘
```

Nguyên tắc nền:

1. **Server là nguồn sự thật** cho toàn bộ dữ liệu nghiệp vụ (INV-09). Thiết bị chỉ cache.
2. **LLM là bộ đề xuất, không phải bộ thực thi.** LLM trả về envelope JSON có cấu trúc; backend validate rồi mới thực thi qua domain service (INV-08).
3. **Character Engine chạy trên client**, nhận *semantic cue* (emotion/intensity/special_cue + `stage_context` do Director tính xác định) + sự kiện app, tự chọn asset từ manifest qua **Asset Policy Engine** (`content_sensitivity` × `allowed_modes` × owner policy). LLM và backend không bao giờ gửi filename/asset_id; LLM không thấy metadata asset (INV-02, INV-21).
4. **Video không có âm thanh. Giọng Hana chỉ đến từ TTS** (INV-03).
5. **Private mode là một "vùng" tách biệt** ở mọi tầng: route API, DB schema + DB role, Redis DB, queue, module code, Flutter feature scope, cache, manifest (INV-04..07, INV-15).
6. **Thời gian lưu UTC, tính nghiệp vụ theo Asia/Ho_Chi_Minh** (INV-01, INV-19).

---

## 2. Component boundaries

### 2.1 Bảng component

| # | Component | Chạy ở | Trách nhiệm | KHÔNG ĐƯỢC |
|---|---|---|---|---|
| C1 | **Flutter App** | iOS | UI, input text/PTT, AVSpeechSynthesizer TTS, hiển thị video, cache normal data, outbox, local notifications, private vault | Giữ API key provider; gọi 9Router/Deepgram trực tiếp; lưu private message xuống disk; tự quyết định lịch nhắc thay server |
| C2 | **Character Engine** (+ Asset Policy Engine) | Trong C1 (Dart thuần) | State machine 10 core state, stage context, chọn asset theo manifest (bundle/vault/private_vault) + owner asset policy (`content_sensitivity` × `allowed_modes`), xử lý special cue, fallback | Nhận filename/asset_id từ server/LLM; normal engine đọc private_vault manifest hoặc dùng context `private`; I/O trong reducer/policy engine |
| C3 | **VideoStage** | Trong C1 | Phát clip muted, crossfade, loop, preload | Bật volume > 0; phát file không có trong manifest |
| C4 | **api** (FastAPI) | Server | Auth, validate request, CRUD domain, tạo turn + enqueue, relay SSE từ Redis Stream, phục vụ media TTS, private session | Gọi LLM đồng bộ trong request (trừ health); giữ state turn trong RAM |
| C5 | **worker** (arq) | Server | Xử lý turn (Deepgram STT khi voice → context → LLM → validate → actions → reply), memory extraction, day summary, journal extraction, report generation, proactive message, push dispatch | Nhận request HTTP; thực thi action chưa validate; synthesize TTS cho active iOS path |
| C6 | **scheduler** | Server (1 instance leader) | Quét DB tìm occurrence/routine đến hạn, enqueue job idempotent, materialize recurrence, catch-up sau downtime | Thực thi job nặng trực tiếp; giữ lịch chỉ trong Redis |
| C7 | **AI Gateway Client** | Thư viện trong C5 | Gọi 9Router cho chat/embeddings với timeout/retry/alias; Deepgram adapter độc lập cho STT | Được import bởi C4 route handler (trừ health check) |
| C8 | **Character Director** | Thư viện trong C5 | Chuẩn hóa emotion/intensity/special_cue từ LLM → `CharacterCue` hợp lệ theo mode; sinh cue cho sự kiện hệ thống (lỗi, report xong) | Chọn asset; biết filename |
| C9 | **Voice Service** (STT/TTS adapters + SpeechNormalizer) | Thư viện trong C5 | Transcribe audio, chuẩn hóa text → speech, chia segment, synthesize, lưu blob | Dùng audio từ video |
| C10 | **PostgreSQL 16** | Server | Lưu bền mọi dữ liệu nghiệp vụ; schema `hana` + `hana_private` | Bị expose ra internet |
| C11 | **Redis 7** | Server | Queue arq, turn event streams, rate limit, private session, leader lock, debounce | Là nguồn sự thật duy nhất của bất kỳ dữ liệu nào |
| C12 | **BlobStore** | Server (filesystem volume, interface cho S3 sau) | Lưu TTS audio, voice input tạm, vault assets (`ASSET_VAULT_ROOT`), private_vault assets (`PRIVATE_MEDIA_ROOT/assets`) | Được phục vụ qua static public path |
| C13 | **9Router** | Server (internal network) / Windows host (dev) | Gateway OpenAI-compatible tới provider LLM, fallback giữa provider | Được expose public; nhận request từ client |
| C14 | **FCM** (tùy chọn) | Google | Gửi data message tới thiết bị khi đã cấu hình; hệ thống chạy đủ chức năng khi không có | Nhận nội dung private; trở thành phụ thuộc bắt buộc của reminder hay bất kỳ chức năng nào |
| C15 | **Asset Pipeline** | Windows dev host | Phân tích, gắn nhãn, transcode muted, sinh manifest, verify | Ghi/sửa/xóa `assets_source` |

### 2.2 Interface giữa component (tóm tắt, chi tiết ở §6 và các spec)

| Từ → Tới | Giao thức | Contract |
|---|---|---|
| C1 → C4 | HTTPS REST JSON, `Authorization: Bearer <access_jwt>` | §6 |
| C4 → C1 | SSE (`text/event-stream`) | §6.4 |
| C1 → C4 (private) | REST dưới `/v1/private/*` + header `X-Private-Session` | `PRIVACY_SPEC.md` §5 |
| C4 → C11 | arq enqueue (`hana:normal`, `hana:private`), `XREAD` streams | §10 |
| C5 → C11 | `XADD` turn events, cancel flags | §6.4, §9 |
| C5 → C7 → C13 | HTTP `POST {NINE_ROUTER_BASE_URL}/chat/completions`, `/audio/transcriptions`, `/audio/speech`, `/embeddings` | `AI_PROTOCOL.md` §2, `VOICE_SPEC.md` §5, §7 |
| C5 → C10 | SQLAlchemy async; pool `app` (role `hana_app`) và pool `private` (role `hana_private_rw`) | §7, `PRIVACY_SPEC.md` §6 |
| C6 → C10 | `SELECT … FOR UPDATE SKIP LOCKED` trên bảng lịch | §10 |
| C6 → C11 | leader lock `SET scheduler:leader <id> NX PX 30000`, enqueue job với `_job_id` xác định | §10 |
| C5 → C14 | FCM HTTP v1 API, data-only message | §8.6 |
| C5 → C8 | gọi hàm `direct(envelope, mode, context) -> CharacterCue` | `CHARACTER_SYSTEM.md` §6 |
| C1 (C2) ← C4 | SSE event `character.cue` payload `CharacterCue` | `CHARACTER_SYSTEM.md` §6 |
| C15 → C1 | File `bundle` (chỉ `content_sensitivity=normal`) + `bundle_manifest.json` copy vào `repo/mobile/assets/character/bundle/` lúc build | `CHARACTER_SYSTEM.md` §4 |
| C15 → C12 | Upload vault assets + `vault_manifest.json` lên `ASSET_VAULT_ROOT`; private_vault assets + `private_vault_manifest.json` lên `PRIVATE_MEDIA_ROOT/assets` | `CHARACTER_SYSTEM.md` §4.5–§4.6 |
| C1 (C2) ↔ C4 | `GET /v1/assets/manifest`, `GET /v1/assets/{asset_id}`, `GET/PATCH /v1/assets/policy`, `PUT/DELETE /v1/assets/policy/overrides/{asset_id}` | `CHARACTER_SYSTEM.md` §17.3 |
| C8 → C10 | Director đọc `relationship_stage_enabled`, `relationship_trigger` qua `domain/assets/policy_reader.py` | `CHARACTER_SYSTEM.md` §8.5.1 |

### 2.3 Quy tắc import (backend) — PHẢI enforce bằng `import-linter` trong CI

```
app/core            : không import domain/api
app/domain/private  : CÓ THỂ import core, domain/ai, domain/voice, domain/character,
                      domain/memory/profile_reader (read-only). KHÔNG import domain/reminders,
                      domain/tasks, domain/journal, domain/reports, domain/instructions,
                      domain/notifications.
app/domain/<normal> : KHÔNG import app/domain/private, app/api/v1/private, app/db/private_*
app/api/v1/<normal> : KHÔNG import app/api/v1/private, app/domain/private
app/db/private_*    : chỉ được import bởi app/domain/private và app/workers/private_jobs
app/domain/assets   : chỉ được import bởi app/api/v1/assets.py, app/api/v1/private/assets.py,
                      và app/domain/character (CHỈ policy_reader.py). KHÔNG được import bởi
                      app/domain/ai, app/domain/conversation (context builder), app/domain/memory,
                      app/domain/companion (INV-21)
```

Flutter: `lib/features/private/**` chỉ được import từ `lib/app/router.dart` (route lazy) và không file nào ngoài `lib/features/private/**` được import symbol từ đó. Enforce bằng custom lint / test quét import.

---

## 3. Topology triển khai

### 3.1 Local development (Windows)

| Thành phần | Cách chạy | Địa chỉ |
|---|---|---|
| postgres | Docker Compose `infra/compose.dev.yml` | `localhost:5432` (bind 127.0.0.1) |
| redis | Docker Compose | `localhost:6379` (bind 127.0.0.1) |
| api | Docker Compose (hoặc `uvicorn` trong venv khi debug) | `0.0.0.0:8000` (LAN để thiết bị thật truy cập) |
| worker, scheduler | Docker Compose | — |
| 9router | Chạy trên Windows host (Node) | `http://host.docker.internal:20128/v1` từ container |
| Flutter iOS | iOS Simulator (`http://127.0.0.1:8000`) hoặc iPhone trên LAN (`https://<DEV_HOST>`) | — |
| asset pipeline | Python 3.11 venv + ffmpeg trên host | — |

- Cleartext HTTP chỉ được phép cho local iOS Simulator dev với ATS exception tối thiểu; staging/prod PHẢI HTTPS và không có broad ATS exception.
- Container đặt `TZ=UTC`. Postgres `timezone = 'UTC'`.
- Push iOS/APNs là tùy chọn cho đến phase notification: khi chưa cấu hình, dispatcher ghi notification in-app với `push_state=skipped_unconfigured`, không lỗi. Local notification đã đồng bộ vẫn hoạt động.
- Target build V1: **iOS**. Minimum verification build là `flutter build ios --release --no-codesign` trên macOS/Xcode; Android không thuộc release gate.

### 3.2 Staging / Production (VPS)

- Một VPS Linux, Docker Compose `infra/compose.prod.yml`.
- Chỉ Caddy expose cổng 80/443. api, worker, scheduler, postgres, redis, 9router nằm trong network nội bộ `hana_internal`.
- Dashboard 9Router chỉ bind `127.0.0.1`, truy cập qua SSH tunnel.
- Volume: `pgdata`, `redisdata` (AOF bật), `media`, `private_media`, `asset_vault`, `backups`.
- Backup: `pg_dump` hằng ngày 03:00 Asia/Ho_Chi_Minh, mã hóa bằng `age` (public key trên server, private key giữ offline), giữ 14 bản.
- Staging và production là hai compose project riêng, DB riêng, secret riêng. Chỉ promote lên VPS khi toàn bộ AC local PASS.

---

## 4. Local vs Server responsibilities

### 4.1 Trách nhiệm xử lý

| Việc | Local (Flutter) | Server |
|---|---|---|
| Ghi âm PTT, đo độ dài, hủy | ✔ | |
| STT | | ✔ (worker → 9Router) |
| LLM | | ✔ |
| TTS synthesize/phát (`AVSpeechSynthesizer`) | ✔ | |
| Quyết định core state + chọn asset (Asset Policy Engine) | ✔ (Character Engine) | |
| Chuẩn hóa emotion từ LLM thành cue hợp lệ + tính `stage_context` xác định | | ✔ (Character Director) |
| Lưu owner asset policy (nguồn sự thật) | cache drift | ✔ `hana.asset_policy*`, `hana_private.private_asset_policy_overrides` |
| Mã hóa vault asset cache | ✔ (AES-GCM, key `vault_asset_key` trong Keystore) | |
| Tính giờ đến hạn reminder, recurrence | | ✔ (nguồn sự thật) |
| Bắn notification đúng giờ | ✔ chính (local scheduled, không cần FCM) | ✔ dự phòng tùy chọn (FCM nếu đã cấu hình và thiết bị chưa ack) |
| Lưu memory, journal, report, instruction | | ✔ |
| Tạo report tháng | | ✔ |
| Mã hóa private text at rest | | ✔ (AES-GCM app-level) |
| Mã hóa private_vault asset cache | ✔ (AES-GCM, key private trong Keystore, khác `vault_asset_key`) | |
| Xác thực private PIN | | ✔ |
| Private unlock bằng PIN 6 số (credential bắt buộc) | nhập PIN | ✔ xác minh argon2id |
| Private unlock bằng biometric (tùy chọn) | ✔ BiometricPrompt mở khóa key Keystore, ký challenge | ✔ xác minh chữ ký với public key đã enroll bằng PIN |
| Chặn screenshot/recents trong private | ✔ (FLAG_SECURE) | |

### 4.2 Vị trí dữ liệu

| Dữ liệu | Server | Local | Ghi chú lưu local |
|---|---|---|---|
| Tài khoản, password hash, private PIN hash | ✔ | ✘ | |
| Access token (JWT 15 phút) | — | RAM | Không ghi disk |
| Refresh token | hash trong DB | `flutter_secure_storage` | |
| device_id | ✔ | secure storage | |
| Normal messages | ✔ | drift cache tối đa 500 tin gần nhất | xóa khi logout |
| Private messages | ✔ (ciphertext, `hana_private`) | **chỉ RAM** trong private session | KHÔNG BAO GIỜ ghi disk |
| Normal memories, journal, reports, instructions | ✔ | RAM (+ drift cache danh sách journal 60 ngày, reports metadata) | |
| Private memories | ✔ (ciphertext) | ✘ (chỉ RAM khi xem trong private) | |
| Tasks / reminders / occurrences | ✔ | drift cache occurrences 14 ngày tới | để local notification hoạt động offline |
| Outbox (text chưa gửi) | — | drift | chỉ normal |
| Asset `bundle` (chỉ `content_sensitivity=normal`) + `bundle_manifest.json` | ✘ | iOS app bundle | seed Phase 3.2: 0 video, chỉ `fallback.png` |
| Asset `vault` + `vault_manifest.json` | ✔ `ASSET_VAULT_ROOT` | cache mã hóa `app_support/asset_vault/` | runtime giải mã vào `cache/vault_rt/` (normal) hoặc `cache/prv_rt/` (private); xóa khi logout (PRIVACY_SPEC §4.1) |
| Asset `private_vault` + `private_vault_manifest.json` | ✔ `PRIVATE_MEDIA_ROOT/assets` | cache mã hóa `app_support/prv_assets/` | runtime giải mã vào `cache/prv_rt/`, xóa khi khóa |
| Owner asset policy | ✔ `hana.asset_policy`, `hana.asset_policy_overrides`; `hana_private.private_asset_policy_overrides` | drift cache (chỉ normal); private overrides chỉ RAM | |
| TTS audio normal | ✔ blob, TTL 7 ngày | stream, không cache disk | |
| TTS audio private | ✔ blob private, TTL 1 giờ | stream, không cache disk | |
| Voice input normal | ✔ blob, xóa sau 24h | file tạm, xóa ngay sau upload thành công | |
| Voice input private | ✔ blob private, xóa ngay sau STT | file tạm trong `cache/prv_rt/`, xóa ngay sau upload | |
| Settings | ✔ | drift cache | |
| FCM token | ✔ bảng devices | plugin quản lý | |
| LLM prompt/response log | ✘ mặc định (chỉ metadata `llm_calls`) | ✘ | |

---

## 5. Repository layout (bắt buộc)

```
repo/
  backend/
    pyproject.toml
    alembic/                      # một chuỗi migration duy nhất cho cả 2 schema
    app/
      main.py                     # tạo FastAPI app, mount routers
      core/
        config.py                 # pydantic-settings, đọc env §16
        clock.py                  # Clock interface: now_utc(); FakeClock cho test
        tz.py                     # BUSINESS_TZ + helper (TIMEZONE_SPEC §4)
        ids.py                    # uuid7
        security.py               # jwt, argon2id, rate limit helper
        crypto.py                 # AES-GCM cho private (PRIVACY_SPEC §6.3)
        errors.py                 # mã lỗi §14
        logging.py                # structlog + redaction
      db/
        app_session.py            # engine role hana_app
        private_session.py        # engine role hana_private_rw
        models/                   # SQLAlchemy models schema hana
        private_models/           # SQLAlchemy models schema hana_private
      api/v1/
        auth.py devices.py settings.py turns.py messages.py media.py
        reminders.py tasks.py journal.py reports.py instructions.py
        memories.py notifications.py assets.py health.py
        private/
          session.py turns.py messages.py memories.py assets.py media.py wipe.py
      domain/
        ai/            gateway.py protocol.py validator.py refs.py placeholders.py prompts/
        character/     director.py cues.py
        assets/        policy.py (asset_policy + overrides service) policy_reader.py (chỉ cờ relationship cho Director) vault.py (phục vụ vault manifest/file)
        voice/         stt.py tts.py speech_normalizer.py segmenter.py
        conversation/  orchestrator.py context_builder.py action_executor.py
        memory/        service.py extractor.py retriever.py profile_reader.py summaries.py followups.py
        reminders/     service.py recurrence.py
        tasks/         service.py
        journal/       service.py extractor.py
        reports/       service.py period.py generator.py
        instructions/  service.py routines.py schemas.py
        notifications/ service.py fcm.py
        companion/     proactive.py
        private/       orchestrator.py context_builder.py memory.py session.py assets.py wipe.py
      workers/
        settings.py    # arq WorkerSettings cho queue hana:normal
        private_settings.py  # arq WorkerSettings cho queue hana:private
        jobs/          turn.py memory.py journal.py reports.py proactive.py push.py maintenance.py
        private_jobs/  turn.py memory.py maintenance.py
      scheduler/
        main.py        # leader loop §10.3
    tests/
  mobile/
    pubspec.yaml
    android/
    assets/character/bundle/     # sinh bởi asset pipeline, gitignored (trừ bundle_manifest.json, fallback.png); chỉ sensitivity=normal
    lib/
      app/        bootstrap.dart router.dart lifecycle.dart flavors.dart
      core/       api/ (dio client, sse client, error mapping) auth/ storage/ (drift, secure)
                  outbox/ time/ (server clock offset, business tz) notifications/ logging/
      character/  engine/ (state, events, reducer, effects, stage_context) manifest/ (validator theo manifest_kind)
                  policy/ (Asset Policy Engine thuần: eligibility, tier, main-loop/variant, fallback)
                  vault/ (downloader, AES-GCM cache asset_vault, vault_rt) stage/ (VideoStage widget)
      features/
        chat/ voice/ reminders/ tasks/ journal/ reports/ instructions/ memory/ settings/ inbox/
        private/  session/ chat/ vault/ secure_window/ memory/
    test/
  tools/
    asset_pipeline/  probe.py label_check.py (schema v2 + coverage report) transcode.py manifest.py verify.py
                     sync_bundle.py publish_vault.py publish_private.py
  infra/
    compose.dev.yml compose.prod.yml Caddyfile postgres/init/ (roles, extensions) backup/
```

Thư viện đã chốt:

- Backend (Python 3.11): FastAPI, uvicorn, pydantic v2, pydantic-settings, SQLAlchemy 2 (async) + asyncpg, alembic, arq, redis-py, httpx, pyjwt, argon2-cffi, cryptography, structlog, rapidfuzz, python-multipart, pytest, pytest-asyncio, time-machine, import-linter.
- Postgres extensions: `pg_trgm`, `unaccent`, `pgcrypto` (gen_random_uuid dự phòng), `btree_gist` (exclusion constraint kỳ báo cáo). `pgvector` tùy chọn (MEMORY_SPEC §7.4).
- Flutter (iOS): riverpod, dio, drift, flutter_secure_storage, video_player, native platform channels for `AVSpeechSynthesizer`/`AVAudioRecorder`/`AVAudioSession`, local notifications, local_auth, timezone, uuid, cryptography. Existing Android dependencies/source may remain temporarily but are non-gating.

---

## 6. API contract

### 6.1 Quy ước chung

- Base path `/v1`. JSON UTF-8. Tên field `snake_case`.
- Timestamp trong API: ISO-8601 UTC có hậu tố `Z`, độ chính xác mili-giây, tên field kết thúc `_at` (vd `created_at`).
- Ngày nghiệp vụ: `YYYY-MM-DD`, field kết thúc `_local_date`.
- Giờ tường nghiệp vụ: `YYYY-MM-DDTHH:MM` (không offset), field kết thúc `_local`, luôn đi kèm ngữ cảnh `tz = "Asia/Ho_Chi_Minh"` (TIMEZONE_SPEC §6).
- Mọi response có header `X-Server-Time` (UTC ISO) để client tính clock offset.
- ID: UUIDv7 dạng string.
- Idempotency: request tạo mới (turn, reminder, task, journal entry, memory) PHẢI có `client_id` (UUID do client sinh). Trùng `client_id` → trả lại resource đã tạo, HTTP 200 thay vì 201/202.
- Pagination: cursor-based `?cursor=<opaque>&limit=<1..100>`; response `{ "items": [...], "next_cursor": "..."|null }`.
- Error envelope:

```json
{ "error": { "code": "TURN_IN_PROGRESS", "message": "human readable (vi)", "retryable": false, "details": {} } }
```

### 6.2 Auth & device

| Method | Path | Body / Query | Response |
|---|---|---|---|
| POST | `/v1/auth/login` | `{username, password, device: {device_id, platform:"android", app_version, device_name}}` | `{access_token, access_expires_at, refresh_token, user}` |
| POST | `/v1/auth/refresh` | `{refresh_token, device_id}` | như login (refresh token xoay vòng; token cũ bị thu hồi) |
| POST | `/v1/auth/logout` | `{device_id}` | 204; thu hồi refresh token của device, hủy private session của device |
| PUT | `/v1/devices/{device_id}/push-token` | `{fcm_token}` | 204 |
| GET | `/v1/me` | — | `{user, settings, relationship: {address_user, address_hana}, server_time}` |
| PATCH | `/v1/settings` | các field settings (§7.2 `user_settings`) | settings mới |

- Access JWT HS256, TTL 15 phút, claims: `sub` (user_id), `did` (device_id), `scp: "normal"`, `iat`, `exp`, `jti`.
- Refresh token: 32 byte ngẫu nhiên base64url, lưu `sha256` trong DB, TTL 30 ngày, rotate mỗi lần dùng; phát hiện dùng lại token đã rotate → thu hồi toàn bộ token của device (reuse detection).
- v1 là **single-owner**: tài khoản owner tạo bằng CLI `python -m app.cli create-owner`. Không có endpoint đăng ký. Tối đa 3 device active.

### 6.3 Conversation (normal)

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/v1/turns` | `{client_id, text, speak: bool, supersede: bool}` | 202 `{turn_id, user_message, events_url}` |
| POST | `/v1/turns/voice` | multipart: `client_id`, `audio` (m4a), `duration_ms`, `speak`, `supersede` | 202 `{turn_id, events_url}` |
| GET | `/v1/turns/{turn_id}/events` | header `Last-Event-ID` tùy chọn | SSE §6.4 |
| GET | `/v1/turns/{turn_id}` | — | `{turn_id, state, error, user_message, assistant_message, character_cue, tts_segments[]}` |
| POST | `/v1/turns/{turn_id}/cancel` | — | 202 |
| GET | `/v1/messages` | `?cursor&limit` (mới → cũ) | `{items: Message[], next_cursor}` |
| GET | `/v1/messages/sync` | `?after_id=<uuid7>` | tin mới hơn, dùng khi app resume |
| GET | `/v1/media/{media_id}` | header Authorization | `audio/mpeg` bytes, hỗ trợ Range |
| POST | `/v1/messages/{message_id}/speak` | — | 202 `{speak_id, events_url}`; worker job `speak_message` phát `tts.segment`/`tts.failed`/`speak.completed` qua SSE `GET /v1/speak/{speak_id}/events` (stream `ev:speak:{speak_id}`); dùng cache TTS nếu còn |

Ràng buộc: `text` 1..4000 ký tự sau trim. `duration_ms` 400..62000, file ≤ 2 MB.

`Message`:

```json
{
  "id": "0192…", "role": "user|assistant|system_event",
  "origin": "chat|voice|proactive|reminder|report|system",
  "text": "…", "created_at": "2026-09-15T02:10:00.123Z",
  "turn_id": "…|null",
  "character_cue": { "emotion": "happy", "intensity": "medium", "special_cue": null } ,
  "receipts": [ { "type": "reminder.created", "entity_id": "…", "label": "⏰ 15:00 Thứ Tư, 16/09 — Họp team", "undo_until": "…Z" } ],
  "read_at": null
}
```

### 6.4 SSE turn events

Server gửi mỗi event dạng:

```
id: <redis stream entry id>
event: <event_type>
data: {"turn_id":"…","seq":3,"ts":"…Z", …payload}
```

| event | payload | Ghi chú |
|---|---|---|
| `turn.accepted` | `{state:"queued"}` | |
| `transcript.final` | `{user_message: Message, stt_latency_ms}` | chỉ voice turn |
| `turn.progress` | `{stage: "transcribing"|"thinking"|"acting"|"speaking"}` | client dùng cho Character Engine |
| `reply.ready` | `{assistant_message: Message}` | có `character_cue`, `receipts` |
| `character.cue` | `CharacterCue` | gửi ngay sau `reply.ready`; CHARACTER_SYSTEM §6 |
| `tts.segment` | `{index, media_id, media_url, duration_ms, char_start, char_end, is_last}` | theo đúng thứ tự index |
| `tts.failed` | `{code, index}` | text vẫn hợp lệ |
| `job.started` | `{job: "report_generation", job_id}` | client → state `working` |
| `turn.completed` | `{state:"completed"}` | đóng stream |
| `turn.failed` | `{code, retryable, message}` | đóng stream |
| `turn.cancelled` | `{}` | đóng stream |
| `: keepalive` | comment mỗi 15 giây | |

- Nguồn: Redis Stream `ev:turn:{turn_id}` (db0), `MAXLEN ~ 200`, `EXPIRE 900` giây sau event kết thúc.
- Resume: client reconnect với `Last-Event-ID` → api `XREAD` từ id đó. Nếu stream đã hết hạn → api trả event tổng hợp từ DB (`reply.ready`, các `tts.segment` còn media hợp lệ, trạng thái cuối).
- Client PHẢI xử lý event trùng theo `seq` (bỏ qua seq ≤ seq đã xử lý).

### 6.5 Tasks & reminders

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/v1/tasks` | `?status=open|done|all&due_before_local_date=` | Task[] |
| POST | `/v1/tasks` | `{client_id, title, notes?, due_local_date?, priority?}` | 201 Task |
| PATCH | `/v1/tasks/{id}` | các field | Task |
| POST | `/v1/tasks/{id}/complete` / `/reopen` / `/cancel` | — | Task |
| GET | `/v1/reminders` | `?status=active|all` | Reminder[] |
| POST | `/v1/reminders` | `{client_id, title, note?, due_local, recurrence?, task_id?}` | 201 Reminder (kèm `occurrences` 14 ngày) |
| PATCH | `/v1/reminders/{id}` | các field; tăng `version` | Reminder |
| POST | `/v1/reminders/{id}/cancel` | — | Reminder |
| GET | `/v1/reminders/sync` | `?since_version_cursor=` | `{reminders_changed[], occurrences_window[], cursor}` |
| POST | `/v1/reminder-occurrences/ack-scheduled` | `{device_id, items:[{occurrence_id, reminder_version}]}` | 204 |
| POST | `/v1/reminder-occurrences/{id}/done` | — | 204 |
| POST | `/v1/reminder-occurrences/{id}/snooze` | `{minutes: 5..1440}` | Occurrence mới |
| POST | `/v1/reminder-occurrences/{id}/dismiss` | — | 204 |

### 6.6 Các domain khác

| Nhóm | Endpoints | Spec |
|---|---|---|
| Journal | `GET /v1/journal/days?from_local_date&to_local_date`, `GET /v1/journal/days/{local_date}`, `POST /v1/journal/entries`, `PATCH /v1/journal/entries/{id}`, `DELETE /v1/journal/entries/{id}` | WORK_JOURNAL_SPEC §9 |
| Reports | `GET /v1/reports`, `GET /v1/reports/{id}`, `POST /v1/reports/generate` | WORK_JOURNAL_SPEC §9 |
| Instructions | `GET /v1/instructions`, `POST /v1/instructions/{id}/confirm|reject|pause|resume|revoke`, `PATCH /v1/instructions/{id}` | STANDING_INSTRUCTIONS_SPEC §9 |
| Memories | `GET /v1/memories`, `POST /v1/memories`, `PATCH /v1/memories/{id}`, `DELETE /v1/memories/{id}`, `GET /v1/followups`, `PATCH /v1/followups/{id}` | MEMORY_SPEC §10 |
| Notifications inbox | `GET /v1/notifications?after=<uuid7>&cursor=`, `POST /v1/notifications/{id}/read`, `POST /v1/notifications/{id}/displayed` (client đã hiện local notification, dedupe) | §8.6 |
| Assets | `GET /v1/assets/manifest` (vault manifest, ETag), `GET /v1/assets/{asset_id}` \| `/poster` \| `/blur`, `GET/PATCH /v1/assets/policy`, `PUT/DELETE /v1/assets/policy/overrides/{asset_id}` | CHARACTER_SYSTEM §4.5, §17.3; PRIVACY_SPEC §4.1 |
| Data control | `POST /v1/data/export` (job → media zip), `DELETE /v1/messages` (xóa lịch sử chat normal), `POST /v1/data/delete-all` (yêu cầu password), `POST /v1/devices/{device_id}/revoke` | PRIVACY_SPEC §9 |
| Private | toàn bộ dưới `/v1/private/*` | PRIVACY_SPEC §5.9 |
| Health | `GET /healthz` (process sống), `GET /readyz` (DB, Redis, 9Router `/api/health` hoặc `GET /v1/models`) | |

---

## 7. Data model lõi (schema `hana`)

### 7.1 Quy ước DB

- Postgres 16, `timezone = 'UTC'` ở cả server config và mỗi connection (`SET TIME ZONE 'UTC'` trong `connect` event).
- Timestamp: `timestamptz`, tên `*_at`. Ngày nghiệp vụ: `date`, tên `*_local_date`. Giờ tường: `timestamp without time zone`, tên `*_local`, luôn có cột `tz text NOT NULL DEFAULT 'Asia/Ho_Chi_Minh'` cùng bảng (INV-19).
- PK `uuid` (UUIDv7 sinh ở app). `created_at`, `updated_at` bắt buộc.
- Soft delete chỉ khi spec yêu cầu; mặc định hard delete.
- Không lưu nội dung private trong schema `hana` (INV-04).
- DB roles (tạo trong `infra/postgres/init`):
  - `hana_migrator`: owner cả 2 schema, chỉ dùng cho alembic.
  - `hana_app`: `USAGE` + CRUD trên `hana`. **Không có** `USAGE` trên `hana_private`.
  - `hana_private_rw`: `USAGE` + CRUD trên `hana_private`; `SELECT` trên `hana.users`, `hana.user_settings`, `hana.relationship_state`, `hana.memories` (chỉ cột không nhạy cảm qua view `hana.v_profile_memories`), không có quyền ghi `hana`.

### 7.2 Bảng định nghĩa trong tài liệu này

**users**

| Cột | Kiểu | Ràng buộc |
|---|---|---|
| id | uuid | PK |
| username | text | unique, not null |
| password_hash | text | argon2id |
| display_name | text | |
| is_owner | boolean | default true |
| created_at, updated_at | timestamptz | |

**user_settings** (1-1 users)

| Cột | Kiểu | Mặc định |
|---|---|---|
| user_id | uuid PK FK | |
| speak_replies | text enum `always|voice_turns_only|never` | `always` |
| tts_speed | numeric(3,2) | 1.00 (0.75..1.50) |
| notification_preview | text enum `full|generic` | `generic` |
| quiet_hours_start_local | time | 23:00 |
| quiet_hours_end_local | time | 07:00 |
| morning_brief_enabled / _time_local | boolean / time | true / 08:00 (chào buổi sáng) |
| followup_checkin_enabled / _time_local | boolean / time | true / 14:00 (hỏi lại việc dang dở) |
| evening_checkin_enabled / _time_local | boolean / time | true / 21:30 (hỏi thăm buổi tối) |
| journal_day_cutoff_local | time | 04:00 (cutoff ngày nghiệp vụ journal) |
| updated_at | timestamptz | |

Mọi giá trị mặc định trên là **mặc định cấu hình được** (quyết định D4) qua `PATCH /v1/settings`, màn Cài đặt, hoặc action `settings.update`. Ràng buộc: `journal_day_cutoff_local` trong `00:00..06:00`; giờ routine companion nằm trong quiet hours → UI cảnh báo, run bị `skipped(quiet_hours)`; `quiet_hours_start_local ≠ quiet_hours_end_local` hoặc bằng nhau nghĩa là tắt quiet hours. Đổi cutoff không đổi `work_local_date` của entry đã có; đổi cutoff lớn hơn `run_time_local` của routine report → reject (STANDING_INSTRUCTIONS_SPEC §4.2).

(Mọi thông tin về private mode — đã thiết lập hay chưa, xác nhận 18+, PIN hash — KHÔNG nằm ở đây mà ở `hana_private.private_settings`; client hỏi qua `GET /v1/private/status`.)

**devices**

| id (text, device_id do client sinh UUID) PK | user_id FK | platform | app_version | device_name | fcm_token text null | last_seen_at | revoked_at null | created_at |

**refresh_tokens**

| id uuid PK | user_id | device_id | token_sha256 bytea unique | family_id uuid | expires_at | rotated_at null | revoked_at null | created_at |

**turns** (không chứa nội dung text)

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK | |
| user_id | uuid FK | |
| client_id | uuid | unique (user_id, client_id) |
| input_kind | text `text|voice` | |
| state | text | §9 |
| speak | boolean | |
| user_message_id | uuid null FK messages | |
| assistant_message_id | uuid null FK messages | |
| input_media_id | uuid null FK media_objects | voice |
| superseded_by_turn_id | uuid null | |
| error_code | text null | §14 |
| llm_call_ids | uuid[] | |
| created_at, updated_at, completed_at | timestamptz | |

Index: `(user_id, state) WHERE state NOT IN ('completed','failed','cancelled')`.

**messages**

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK (v7) | thứ tự hiển thị theo `(created_at, id)` |
| user_id | uuid | |
| turn_id | uuid null | |
| role | text `user|assistant|system_event` | |
| origin | text `chat|voice|proactive|reminder|report|system` | |
| text | text not null | assistant: text đã render placeholder |
| character_cue | jsonb null | CharacterCue |
| receipts | jsonb not null default `[]` | |
| related_entity | jsonb null | `{type, id}` vd report |
| read_at | timestamptz null | |
| created_at | timestamptz | |

Index GIN trigram trên `unaccent(lower(text))` cho tìm kiếm (MEMORY_SPEC dùng).

**media_objects**

| id | user_id | kind `tts_audio|voice_input|export_zip` | storage_key text | mime | bytes int | duration_ms int null | sha256 bytea | cache_key text null (unique partial) | expires_at timestamptz | created_at |

**tasks**

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK | |
| user_id | uuid | |
| client_id | uuid null | unique (user_id, client_id) |
| title | text (1..200) | |
| notes | text null | |
| status | text `open|done|cancelled` | |
| priority | smallint 1..3 null | 1 cao |
| due_local_date | date null | |
| source_message_id | uuid null | |
| completed_at | timestamptz null | |
| created_at, updated_at | | |

**reminders**

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK | |
| user_id | uuid | |
| client_id | uuid null | unique (user_id, client_id) |
| task_id | uuid null FK tasks | |
| title | text (1..200) | |
| note | text null | |
| first_due_local | timestamp (no tz) | |
| tz | text | `Asia/Ho_Chi_Minh` |
| recurrence | jsonb null | TIMEZONE_SPEC §7 |
| status | text `active|completed|cancelled` | |
| version | int | tăng mỗi lần sửa lịch |
| materialized_until_local_date | date | |
| source_message_id | uuid null | |
| created_at, updated_at | | |

**reminder_occurrences**

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK | |
| reminder_id | uuid FK | |
| occurrence_local | timestamp (no tz) | |
| due_at | timestamptz | = convert(occurrence_local, tz) |
| is_snooze | boolean | |
| state | text | §8.4 |
| reminder_version | int | version lúc materialize |
| local_ack_device_id | text null | |
| local_ack_version | int null | |
| dispatched_at, delivered_at, acted_at | timestamptz null | |
| action | text null `done|snoozed|dismissed` | |
| created_at, updated_at | | |

Unique `(reminder_id, occurrence_local, is_snooze)`. Index `(state, due_at)`.

**notifications** (inbox, chỉ normal)

| id | user_id | kind `reminder|companion|report|instruction|system` | title | body | deep_link | related_entity jsonb | push_state `not_sent|sent|failed|skipped_local|skipped_quiet|skipped_unconfigured` | created_at | read_at |

**llm_calls** (metadata, không nội dung)

| id | purpose | model | mode `normal` | status `ok|timeout|http_error|invalid_output|refused` | latency_ms | prompt_tokens | completion_tokens | attempt | created_at |

(Private LLM calls ghi vào `hana_private.private_llm_calls`.)

**action_executions** (kết quả thực thi action do LLM đề xuất — AI_PROTOCOL §7)

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK | `execution_id` trong receipt |
| user_id | uuid | |
| turn_id | uuid | |
| action_index | smallint | unique (turn_id, action_index) |
| action_type | text | vd `reminder.create` |
| status | text `executed|rejected|needs_clarification|pending_confirmation|undone` | |
| entity_type | text null | |
| entity_id | uuid null | |
| error_code | text null | |
| undo_payload | jsonb null | dữ liệu đảo ngược (không chứa nội dung private — bảng này chỉ normal) |
| undo_until | timestamptz null | created_at + 30 s |
| created_at, updated_at | timestamptz | |

Endpoint: `POST /v1/action-executions/{id}/undo` → 200 `{status:"undone"}`; quá `undo_until` → 409 `CONFLICT`. Private action executions lưu ở `hana_private.private_action_executions` (cùng cấu trúc).

**job_runs** (theo dõi job nghiệp vụ không thuộc bảng riêng)

| id | job_type | idempotency_key unique | state `queued|running|succeeded|failed|dead` | attempt | scheduled_for | started_at | finished_at | error_code | created_at |

**audit_log** (normal)

| id | user_id | actor `user|hana|scheduler|system` | action text | entity_type | entity_id | meta jsonb (không nội dung người dùng) | created_at |

### 7.3 Chỉ mục bảng ở tài liệu khác

| Bảng | Schema | Định nghĩa tại |
|---|---|---|
| memories, conversation_summaries, followups, relationship_state, memory_extraction_cursors, v_profile_memories | hana | MEMORY_SPEC §4 |
| work_journal_entries, work_journal_entry_revisions, work_journal_items, work_reports | hana | WORK_JOURNAL_SPEC §8 |
| standing_instructions, routine_schedules, routine_runs | hana | STANDING_INSTRUCTIONS_SPEC §8 |
| asset_policy, asset_policy_overrides | hana | CHARACTER_SYSTEM §17.1–§17.2 |
| private_asset_policy_overrides | hana_private | CHARACTER_SYSTEM §17.2 |
| private_settings, private_biometric_keys, private_turns, private_messages, private_memories, private_summaries, private_extraction_cursors, private_media_objects, private_llm_calls, private_action_executions, private_audit_log | hana_private | PRIVACY_SPEC §6 |

---

## 8. Lifecycles

### 8.1 Chat text turn (normal)

```
Client                           api                    redis              worker                 9Router
  │ user nhấn Gửi                  │                       │                  │                       │
  │ Engine: turnSubmitted→thinking │                       │                  │                       │
  │ outbox insert(client_id)       │                       │                  │                       │
  │── POST /v1/turns ─────────────►│ validate, rate-limit  │                  │                       │
  │                                │ TX: insert turn(queued)+message(user)    │                       │
  │                                │── enqueue process_turn(job_id=turn_id) ─►│                       │
  │◄──── 202 {turn_id} ────────────│                       │                  │                       │
  │── GET /events (SSE) ──────────►│── XREAD ev:turn:id ──►│                  │                       │
  │                                │                       │◄─ XADD progress ─│ context_building      │
  │                                │                       │                  │── chat/completions ──►│
  │                                │                       │                  │◄──── envelope JSON ───│
  │                                │                       │                  │ validate → actions TX │
  │                                │                       │                  │ render placeholders   │
  │                                │                       │                  │ TX: message(assistant)│
  │◄── reply.ready, character.cue ─│◄──────────────────────│◄─ XADD ──────────│                       │
  │ Engine: replyReady(cue)        │                       │                  │── audio/speech ──────►│
  │◄── tts.segment #0..n ──────────│◄──────────────────────│◄─ XADD ──────────│◄───── mp3 ────────────│
  │ AudioPlayer queue; Engine talking                      │                  │                       │
  │◄── turn.completed ─────────────│                       │                  │ enqueue memory debounce│
  │ outbox remove; Engine ttsFinished→afterglow→idle       │                  │                       │
```

Chi tiết từng bước:

1. Client sinh `client_id` (UUIDv4), thêm bubble trạng thái `sending`, ghi outbox.
2. Nếu có turn khác chưa kết thúc: client gửi `supersede=true` (xem §9.3).
3. api validate → transaction: insert `turns(state=queued)`, `messages(role=user, origin=chat)`. Trùng `client_id` → trả turn cũ.
4. Enqueue `process_turn` vào queue `hana:normal`, `_job_id = "turn:" + turn_id`.
5. Worker chạy pipeline theo state machine §9. Timeout tổng cho turn: 60 giây đến `reply_ready`.
6. Sau `reply.ready`: text hiển thị ngay. iOS client tự quyết định native speech theo AUTO/TEXT_ONLY/VOICE_REPLY và gọi `AVSpeechSynthesizer`; backend turn không chờ TTS. TTS lỗi/cancel không làm turn fail.
7. `turn.completed` → client xóa outbox, bubble `sent`.
8. Hậu kỳ: enqueue `memory_extract` debounce (MEMORY_SPEC §6.1).

Offline: nếu POST thất bại do mạng, bubble chuyển `queued`, outbox retry với backoff 2s, 5s, 15s, 30s, rồi mỗi 60s khi có mạng; cùng `client_id` nên không trùng. Tin trong outbox quá 24 giờ → `failed`, người dùng tự gửi lại.

### 8.2 Voice turn

Xem `VOICE_SPEC.md` §3–§8. Tóm tắt: ghi âm PTT → `POST /v1/turns/voice` → worker state `transcribing` → STT → insert `messages(role=user, origin=voice)` → emit `transcript.final` → tiếp tục pipeline như text từ `context_building`.

### 8.3 Task lifecycle

`open → done | cancelled`; `done → open` (reopen). Tạo từ chat (action `task.create`) hoặc UI. Task không tự sinh notification; muốn nhắc thì tạo reminder có `task_id`. Hoàn thành task đang có reminder active non-recurring → reminder `completed`, occurrences tương lai `cancelled`.

### 8.4 Reminder lifecycle

Trạng thái reminder: `active → completed | cancelled`.

Trạng thái occurrence:

```
scheduled ──ack local──► locally_scheduled
    │                         │
    │ due (scheduler)         │ due (scheduler), version khớp
    ▼                         ▼
dispatched ──FCM ok──► pushed         fired_local
    │                     │                 │
    └──FCM fail x3──► push_failed           │
                          │                 │
(không ack, FCM chưa cấu hình) ──► fired_unacked   │
                          │                 │
         user action ─────┴─────────────────┴──► done | snoozed | dismissed
         không action sau 7 ngày ───────────────► expired
reminder bị sửa/hủy trước due ──────────────────► cancelled
server down, trễ > 6h khi scheduler quét ────────► missed (chỉ inbox, không push)
```

Quy tắc:

1. **Tạo:** validate `due_local` ≥ `now_local + 30s` (TIMEZONE_SPEC §8). Tính `due_at`. Materialize occurrences trong cửa sổ `[today_local, today_local + 14 ngày]`.
2. **Client scheduling:** khi nhận reminder (qua receipt, REST, hoặc `GET /v1/reminders/sync`), iOS client đặt local notification cho occurrences trong 7 ngày tới, notification id ổn định từ `occurrence_id`, rồi gọi `ack-scheduled`. Nếu quyền notification bị từ chối, client không ack và UI hướng dẫn mở Settings; server/in-app inbox giữ trạng thái nguồn sự thật.
3. **Scheduler (mỗi 15s):** chọn occurrences `state IN ('scheduled','locally_scheduled') AND due_at <= now()` với `FOR UPDATE SKIP LOCKED LIMIT 100`:
   - `locally_scheduled` và `local_ack_version = reminders.version` và device không bị revoke → `fired_local`, không push, tạo notification inbox `push_state=skipped_local`.
   - ngược lại, FCM đã cấu hình → `dispatched`, enqueue `push_reminder` `_job_id="push:rem:"+occurrence_id`.
   - ngược lại, FCM **chưa** cấu hình → `fired_unacked`, không push, inbox `push_state=skipped_unconfigured`; thông báo đến người dùng qua background sync (§8.6).
   - `now() - due_at > 6h` → `missed`, chỉ inbox.
4. **Tin nhắn chat kèm theo:** khi occurrence due, worker insert `messages(role=assistant, origin=reminder)` với text template (không gọi LLM): `"Anh ơi, đến giờ {title} rồi nè."` và `character_cue {emotion: neutral, intensity: low}`. Idempotent theo occurrence_id (`related_entity`).
5. **Snooze:** tạo occurrence mới `is_snooze=true`, `occurrence_local = now_local + minutes`; client đặt local notification + ack.
6. **Sửa reminder:** `version += 1`, xóa (cancel) occurrences tương lai chưa due, materialize lại; nếu FCM đã cấu hình gửi data message `{"type":"sync","scope":"reminders"}`; client luôn đồng bộ thêm bằng `GET /v1/reminders/sync` khi app resume và trong background sync (§8.6), nên không phụ thuộc FCM.
7. **Recurrence extension:** job `extend_recurrences` hằng ngày 00:10 local giữ cửa sổ 14 ngày.
8. **Quiet hours không áp dụng** cho reminder người dùng tự đặt.

### 8.5 Proactive message (daily companion)

1. Routine hệ thống (`morning_brief`, `evening_checkin`, `followup_checkin`) do scheduler kích hoạt (STANDING_INSTRUCTIONS_SPEC §6.4).
2. Job `generate_proactive(kind, local_date)` idempotency key `proactive:{kind}:{local_date}`.
3. Kiểm tra skip: quiet hours; đã có ≥ 3 proactive message trong local_date; `evening_checkin` bị bỏ qua nếu user có message trong 2 giờ gần nhất; không có dữ liệu có ý nghĩa.
4. Build context (MEMORY_SPEC §7) → LLM purpose `proactive_message` (AI_PROTOCOL §9.3). Output `skip=true` → dừng.
5. Insert `messages(role=assistant, origin=proactive, character_cue)` + `notifications(kind=companion)` + push nếu FCM đã cấu hình, ngược lại chờ background sync (§8.6) (body theo `notification_preview`: `generic` = "Hana nhắn cho anh").
6. Client mở app: tin chưa đọc, `created_at` < 30 phút → Character Engine phát cue một lần (CHARACTER_SYSTEM §9.4). Proactive message không tự phát TTS; người dùng chạm nút loa để nghe (gọi `POST /v1/messages/{id}/speak` → nhận `tts.segment` qua SSE).

### 8.6 Notification lifecycle

- Sinh ra bởi: reminder occurrence, proactive message, report sẵn sàng/lỗi, instruction chờ xác nhận hết hạn, system.
- Luôn tạo row `notifications` trước, sau đó quyết định push.
- Push FCM (**tùy chọn**, chỉ khi đã cấu hình): **data-only**, priority high, payload `{type, notification_id, title, body, deep_link}`; client tự hiển thị qua `flutter_local_notifications` trên channel `reminders` hoặc `companion`. Retry 3 lần (30s, 2m, 5m). Token invalid → xóa `devices.fcm_token`.
- **Khi FCM chưa cấu hình** (hành vi đầy đủ, không phải lỗi):
  - Reminder: local exact alarm là cơ chế chính và đủ (§8.4 bước 2) — hoạt động offline, không cần server lúc nổ.
  - Client đồng bộ `GET /v1/reminders/sync` + `GET /v1/notifications?after=` + `GET /v1/messages/sync` khi app mở/resume và mỗi 60 s khi foreground. Background refresh iOS dùng `BGTaskScheduler` theo best effort; không giả định chu kỳ chính xác.
  - Background sync tìm thấy notification `companion|report|instruction` chưa hiển thị → tạo local notification (dedupe theo `notification_id`); occurrence mới/đổi → đặt lại exact alarm + ack.
  - Proactive message và report vì vậy có thể đến trễ tới chu kỳ background sync; reminder không bị trễ.
  - `devices.fcm_token` null; server không cố gửi push.
- Không tồn tại channel/kind cho private (INV-06). Background sync không bao giờ đọc endpoint private.

### 8.7 Memory, journal, report, standing instruction

- Memory: MEMORY_SPEC §5–§9.
- Work journal: WORK_JOURNAL_SPEC §4–§5.
- Monthly report: WORK_JOURNAL_SPEC §6.
- Standing instruction: STANDING_INSTRUCTIONS_SPEC §5–§6.

---

## 9. Turn state machine (server)

### 9.1 States

| State | Ý nghĩa | Timeout |
|---|---|---|
| `queued` | Đã persist, chờ worker | 30s → requeue 1 lần, sau đó `failed(WORKER_UNAVAILABLE)` |
| `transcribing` | STT (voice) | 20s |
| `context_building` | Truy vấn memory/tasks/instructions | 3s (quá hạn → dùng context tối thiểu, không fail) |
| `llm_pending` | Đang gọi 9Router | 30s mỗi attempt |
| `validating` | Parse + validate envelope; có thể 1 lần repair call | 30s cho repair |
| `executing_actions` | Thực thi action trong transaction | 5s |
| `reply_repair` | Gọi LLM sinh lại reply khi action fail/clarify | 20s → fallback template |
| `reply_ready` | Assistant message đã persist | — |
| `speaking` | Đang synthesize TTS | 15s mỗi segment, 60s tổng (VOICE_SPEC §7.5) |
| `completed` | Kết thúc | terminal |
| `failed` | Lỗi, có `error_code` | terminal |
| `cancelled` | Người dùng hủy / supersede trước `executing_actions` | terminal |

### 9.2 Transitions

```
queued → transcribing (voice) | context_building (text)
transcribing → context_building | failed(STT_FAILED|STT_EMPTY)
context_building → llm_pending
llm_pending → validating | failed(LLM_TIMEOUT|LLM_UNAVAILABLE) *
validating → executing_actions | reply_ready (không action) | failed(LLM_INVALID_OUTPUT) *
executing_actions → reply_ready | reply_repair
reply_repair → reply_ready
reply_ready → speaking | completed
speaking → completed
(bất kỳ state trước executing_actions) → cancelled
```

`*` Khi fail ở LLM, worker vẫn insert assistant message fallback (AI_PROTOCOL §8.3) với cue `concerned`, `origin=system`, và turn kết thúc `failed` với `retryable=true`. Không action nào được thực thi.

### 9.3 Concurrency

- Tối đa 1 turn chưa terminal cho mỗi `(user_id, mode)`.
- POST turn mới khi đang có turn active:
  - `supersede=false` → 409 `TURN_IN_PROGRESS`.
  - `supersede=true` → set cờ Redis `cancel:turn:{old_id}`; nếu turn cũ chưa tới `executing_actions` → `cancelled`; nếu đã tới → hoàn tất persist nhưng bỏ TTS (`speaking` bị skip), event `turn.completed` có `superseded=true`. Turn mới được tạo ngay.
- Worker kiểm tra cờ cancel tại mỗi ranh giới state.

---

## 10. Job queue & scheduler

### 10.1 Queues

| Queue | Worker settings | Jobs |
|---|---|---|
| `hana:normal` | `app.workers.settings.WorkerSettings`, max_jobs 10 | `process_turn`, `speak_message`, `memory_extract`, `day_summary`, `journal_extract`, `generate_report`, `generate_proactive`, `push_reminder`, `push_notification`, `extend_recurrences`, `cleanup_media`, `data_export` |
| `hana:private` | `app.workers.private_settings.WorkerSettings`, max_jobs 4, Redis db1 | `process_private_turn`, `private_memory_extract`, `private_summary`, `private_cleanup`, `private_wipe` |

Hai worker process riêng (`worker`, `worker_private`) trong compose; `worker_private` chỉ nhận env `DATABASE_URL_PRIVATE` (role `hana_private_rw`, đã có quyền SELECT read-only trên các bảng profile normal theo §7.1), `REDIS_PRIVATE_URL`, `PRIVATE_DATA_KEY`, `PRIVATE_MEDIA_ROOT` và cấu hình 9Router. `worker` normal KHÔNG nhận các secret private.

> Ghi chú: api process cần phục vụ `/v1/private/*` nên api nhận cả hai bộ credential; cách ly trong api dựa vào router riêng + dependency riêng + import-linter + role DB (PRIVACY_SPEC §6).

### 10.2 Retry policy mặc định

| Job | Max attempts | Backoff |
|---|---|---|
| process_turn | 1 (không retry tự động; người dùng bấm retry tạo turn mới) | — |
| memory_extract, journal_extract, day_summary | 3 | 1m, 5m, 30m |
| generate_report | 3 | 5m, 30m, 2h |
| generate_proactive | 2 | 5m |
| push_* | 3 | 30s, 2m, 5m |

Job hết attempt → `job_runs.state = dead` + log error + (report) notification lỗi.

### 10.3 Scheduler loop

```
loop mỗi 15 giây:
  nếu không giữ được leader lock (SET scheduler:leader <instance_id> NX PX 30000 / gia hạn nếu đang giữ): sleep, continue
  now = clock.now_utc()
  1. due_reminder_occurrences(now)            → §8.4
  2. due_routine_runs(now)                    → STANDING_INSTRUCTIONS_SPEC §6
  3. requeue_stuck():
       turns state=queued quá 30s             → enqueue lại 1 lần
       job_runs state=queued quá 2 phút và không có job trong Redis → enqueue lại cùng _job_id
       job_runs state=running quá lease (10 phút) → queued (attempt+1)
  4. mỗi 10 phút: cleanup_media (media_objects.expires_at < now), cleanup Redis streams hết hạn
```

- Mọi enqueue dùng `_job_id` = idempotency key (INV-10). Mọi side effect có unique constraint trong DB tương ứng.
- Scheduler khởi động lại sau downtime: bước 1–2 tự catch-up theo quy tắc trễ của từng domain (§8.4, STANDING_INSTRUCTIONS_SPEC §6.3).

---

## 11. Security boundaries

### 11.1 Trust zones

| Zone | Thành phần | Tin cậy |
|---|---|---|
| Z0 Untrusted | Internet, FCM, provider phía sau 9Router | không |
| Z1 Device | Flutter app, dữ liệu local | tin cậy một phần (có thể mất máy) |
| Z2 Edge | Caddy | TLS termination |
| Z3 App | api, worker, scheduler | tin cậy |
| Z3P Private app | router `/v1/private`, `worker_private`, repo private | tin cậy, tách credential |
| Z4 Data | postgres, redis, blobstore | chỉ Z3/Z3P truy cập |
| Z5 Gateway | 9router | chỉ worker truy cập; mọi output của nó là untrusted input |

### 11.2 Quy tắc

1. Output LLM/STT là **untrusted input**: validate schema, giới hạn độ dài, không bao giờ eval/format như code, không dùng làm path/URL/SQL.
2. Nội dung người dùng trong prompt đặt trong khối dữ liệu có nhãn; memory/journal được đánh dấu là dữ liệu, không phải chỉ thị (AI_PROTOCOL §10).
3. Secrets chỉ trong `.env` server (không commit) hoặc secret file mount; không bao giờ đến thiết bị (INV-14).
4. Rate limit (Redis token bucket, theo user): turns 20/phút, voice 10/phút, login 5/15 phút/IP, private session 5 lần sai → khóa 15 phút, API khác 120/phút.
5. Postgres/Redis/9Router không publish port trên VPS. Dev bind 127.0.0.1 (trừ api).
6. CORS tắt (không web client).
7. Upload: kiểm tra MIME bằng `ffprobe`, giới hạn size, lưu tên file do server sinh.
8. Log: structlog JSON; bộ lọc redaction xóa các key `text`, `content`, `transcript`, `reply`, `prompt`, `audio`, `pin`, `password`, `token` ở mọi mức log; private logger chỉ log id + mã lỗi (INV-15).
9. iOS: Keychain/file-protection entitlements được audit ở security phase; không log nội dung trong release. Android hardening cũ không còn là V1 gate.

---

## 12. Failure modes (tổng)

| # | Sự cố | Phát hiện | Hành vi hệ thống | Hiển thị cho người dùng |
|---|---|---|---|---|
| F01 | 9Router không phản hồi / timeout | httpx timeout 30s | 1 retry nếu 429/503 có `retry-after ≤ 5s`; sau đó fallback message, turn `failed(LLM_TIMEOUT/LLM_UNAVAILABLE)` | Bubble fallback + nút "Thử lại"; Hana `concerned` |
| F02 | LLM trả JSON sai schema | pydantic | 1 repair call; vẫn sai → xử lý plain-text nếu an toàn (AI_PROTOCOL §8.2) hoặc fallback | Như F01 nếu fallback |
| F03 | LLM từ chối (refusal) | heuristic + `finish_reason=content_filter` | `LLM_REFUSED`, fallback nhẹ nhàng | Bubble fallback |
| F04 | Action không hợp lệ (giờ quá khứ, ref sai) | validator domain | Không thực thi action đó; `reply_repair` hỏi lại | Hana hỏi làm rõ |
| F05 | STT lỗi / rỗng | exception / transcript trống | `failed(STT_FAILED|STT_EMPTY)`, xóa audio private | Bubble "Em chưa nghe rõ, anh nói lại nha" (template), cue `concerned` low |
| F06 | TTS lỗi | exception | event `tts.failed`, turn vẫn `completed` | Text hiển thị, icon loa gạch; Engine bỏ `talking` |
| F07 | Redis down | readyz fail, exception | api trả 503 `DEPENDENCY_UNAVAILABLE` cho turn; REST CRUD vẫn chạy nếu không cần Redis (rate limit fail-open cho GET, fail-closed cho private session → private không vào được) | Banner "Hana đang bảo trì"; reminder local vẫn nổ |
| F08 | Postgres down | readyz | 503 toàn bộ; worker job retry | Banner lỗi kết nối; client dùng cache read-only |
| F09 | Worker chết giữa turn | turn kẹt state không terminal quá timeout | scheduler: `queued` → requeue; state khác quá 90s → `failed(WORKER_UNAVAILABLE)` | Nút thử lại |
| F10 | Mất Redis data (flush) | job_runs queued không có trong Redis | scheduler requeue theo DB | Không thấy |
| F11 | Hai scheduler cùng chạy | leader lock | chỉ leader làm việc; nếu lock hỏng, unique constraint chặn side effect trùng | Không thấy |
| F12 | FCM lỗi / token hết hạn | HTTP error | retry 3; token invalid → xóa; inbox vẫn có | Thấy trong inbox |
| F12b | FCM chưa cấu hình | `FCM_ENABLED=false` / thiếu credential | không push, `push_state=skipped_unconfigured`; reminder local vẫn nổ; background sync §8.6 | Reminder đúng giờ; tin Hana/report có thể trễ tới chu kỳ sync |
| F13 | Thiết bị offline khi gửi | dio error | outbox retry | Bubble `queued` |
| F14 | Mất kết nối SSE | stream đóng | reconnect `Last-Event-ID` sau 1s, 2s, 5s; quá 30s → `GET /v1/turns/{id}` | Không thấy nếu hồi phục |
| F15 | Đồng hồ thiết bị lệch | so `X-Server-Time` | client dùng offset cho mọi hiển thị "bây giờ"; lệch > 5 phút → log + banner nhẹ | Banner nếu lệch lớn |
| F16 | Asset hỏng / thiếu / pool rỗng theo policy | sha256 lúc khởi động (lazy), lỗi decoder, Asset Policy Engine trả rỗng | loại asset khỏi pool phiên này, chọn lại → fallback CHARACTER_SYSTEM §11.3 (idle(ctx) → daily → poster → silhouette); không bao giờ mượn asset không eligible | Không thấy (hoặc ảnh tĩnh) |
| F23 | Vault chưa tải / server asset không truy cập được / vault manifest vi phạm `manifest_kind` | downloader lỗi, validator | stage silhouette/poster, tải nền khi có mạng (`AssetReady`); manifest vi phạm bị từ chối toàn bộ, log critical; chat không bị ảnh hưởng | Stage ảnh tĩnh; Cài đặt → Nhân vật & hình ảnh hiện tiến độ tải |
| F17 | Private session hết hạn giữa turn | 401 `PRIVATE_SESSION_EXPIRED` | turn vẫn hoàn tất phía server trong private schema; client khóa private, xóa RAM | Màn hình khóa private |
| F18 | App bị kill trong private mode | lần khởi động sau | xóa `cache/prv_rt/`, khởi động normal mode | Không thấy nội dung private |
| F19 | Scheduler down nhiều giờ | khởi động lại | catch-up: reminder trễ ≤ 6h push kèm "(trễ)"; > 6h `missed`; routine report luôn chạy bù | Inbox |
| F20 | Hết dung lượng disk blob | exception ghi | TTS fail (F06), voice upload 507 `STORAGE_FULL`, alert log | Thông báo lỗi |
| F21 | Provider TTS/STT không hỗ trợ tiếng Việt tốt | QA thủ công | đổi model/voice qua env, không đổi code | — |
| F22 | Migration lỗi | alembic exit code | deploy dừng, không start api | — |

Failure mode chuyên biệt: CHARACTER_SYSTEM §14, VOICE_SPEC §11, MEMORY_SPEC §12, WORK_JOURNAL_SPEC §10, STANDING_INSTRUCTIONS_SPEC §11, TIMEZONE_SPEC §11, PRIVACY_SPEC §11.

---

## 13. Invariants (danh sách tổng — ID dùng chung mọi tài liệu)

| ID | Invariant | Enforce bằng |
|---|---|---|
| INV-01 | Mọi timestamp lưu bền là UTC (`timestamptz`, session UTC). Mọi tính toán nghiệp vụ (ngày, tuần, tháng, giờ nhắc, quiet hours, kỳ report) dùng `ZoneInfo("Asia/Ho_Chi_Minh")`. Không hardcode offset `+7`. | `core/tz.py`, lint cấm chuỗi `timedelta(hours=7)`/`+07:00` ngoài tz.py, test |
| INV-02 | LLM và backend không bao giờ gửi/quyết định filename, path, asset_id, URL video. Character Engine chỉ nhận `CharacterCue` (enum). | JSON schema envelope, test fuzz, client parser chỉ nhận enum |
| INV-03 | Mọi video app-ready có 0 audio stream; player volume = 0 và `mixWithOthers=true`. Giọng Hana chỉ từ TTS. | `verify.py` fail build, unit test manifest, widget test |
| INV-04 | Code path normal không đọc/ghi dữ liệu private. | DB role grants, import-linter, router tách, test integration |
| INV-05 | Asset `content_sensitivity ≥ suggestive` không bao giờ nằm trong iOS app bundle/IPA (bundle chỉ `normal`). Asset `delivery=private_vault` không có trong bundle/vault manifest, chỉ tải qua private session. Normal engine không load private_vault manifest. | build check quét app/IPA, validator `manifest_kind`, test ISO-08/09/27 |
| INV-06 | Không notification (push/local/inbox) nào được tạo từ private mode hoặc chứa nội dung private. | không có code path; action private không có loại notification; test |
| INV-07 | Private mode chỉ mở bằng thao tác UI chủ động + PIN server xác minh. LLM, scheduler, notification, deep link không mở được. App luôn khởi động ở normal mode. | router guard, test |
| INV-08 | LLM không ghi DB trực tiếp; mọi side effect qua action đã validate bởi domain service. | kiến trúc orchestrator, test |
| INV-09 | PostgreSQL là nguồn sự thật; Redis chỉ chứa dữ liệu tái tạo được hoặc ephemeral. | review, test F10 |
| INV-10 | Mọi thực thi theo lịch có idempotency key xác định + unique constraint DB. | schema, test chạy scheduler 2 lần |
| INV-11 | Journal raw text lưu nguyên văn từ người dùng; dữ liệu LLM suy ra lưu riêng và tái tạo được. | WORK_JOURNAL_SPEC §4.4, test |
| INV-12 | Routine standing instruction do người dùng tạo từ chat chỉ `active` sau xác nhận tường minh. | state machine, test |
| INV-13 | Thống kê và ngày trong report do backend tính; mọi bullet LLM phải trích dẫn entry ref tồn tại. | validator, test |
| INV-14 | Secrets không ở thiết bị, không trong repo, không trong log. | gitignore, redaction, CI secret scan |
| INV-15 | Nội dung private không log, không vào audit normal, mã hóa at rest (AES-GCM). | crypto layer, logger private, test |
| INV-16 | `assets_source` bất biến; pipeline chỉ đọc. | pipeline mở file read-only, checksum trước/sau |
| INV-17 | (Sửa Phase 3.2) File nguồn không có nhãn hợp lệ bị loại; thiếu `content_sensitivity` / `allowed_modes` → fail-closed `private` / `[private]`; `hard_block` không bao giờ publish. `review_flag`, `technical_quality=poor`, `excluded_by_default` **không** loại asset khỏi thư viện. | `label_check.py`, pipeline test |
| INV-18 | (Sửa Phase 3.2) Video stage không bao giờ trống: state(ctx) → idle(ctx) → state/idle(daily) (assistant, relationship) → poster → silhouette. Thiếu coverage không fail build; fallback không mượn asset không eligible cho context. | engine test, `label_check` exit 0 khi coverage thiếu |
| INV-19 | Ngày nghiệp vụ là `date` tên `*_local_date`; giờ tường là `timestamp` không tz tên `*_local` + cột `tz`. | review migration, test schema |
| INV-20 | Thời gian/ngày của kết quả action trong reply do backend render (placeholder), không do LLM viết tự do. | AI_PROTOCOL §6, test |
| INV-21 | (Mới Phase 3.2) Quyền hiển thị asset chỉ do Asset Policy Engine trên client quyết định từ manifest đã verify + owner asset policy + `stage_context`. LLM không thấy/chọn/biết asset_id, filename, `content_sensitivity`, `allowed_modes`, `stage_context`; không action LLM nào đọc/ghi owner asset policy; Director tính `stage_context` xác định. | import-linter (`domain/ai`, `domain/conversation` ✗ `domain/assets`), AIP-06, AC-CHAT-11, AC-AI-13 |
| INV-22 | (Mới Phase 3.2) StageContext `private` chỉ tồn tại trong private engine; normal engine không bao giờ chọn asset theo `private`. Với `daily`/`assistant`, asset được chọn luôn thuộc tier `content_sensitivity` thấp nhất của pool; `relationship` chỉ khi owner bật. | engine property test (CHR-04, CHR-07), ISO-28, AC-AST-04/05/07 |

---

## 14. Mã lỗi

| Code | HTTP | retryable | Ý nghĩa |
|---|---|---|---|
| `AUTH_INVALID_CREDENTIALS` | 401 | no | |
| `AUTH_TOKEN_EXPIRED` | 401 | yes (refresh) | |
| `AUTH_REFRESH_REUSED` | 401 | no | thu hồi device |
| `VALIDATION_ERROR` | 422 | no | |
| `RATE_LIMITED` | 429 | yes | header `Retry-After` |
| `TURN_IN_PROGRESS` | 409 | yes | |
| `TURN_NOT_FOUND` | 404 | no | |
| `LLM_TIMEOUT` | — (SSE) | yes | |
| `LLM_UNAVAILABLE` | — | yes | |
| `LLM_INVALID_OUTPUT` | — | yes | |
| `LLM_REFUSED` | — | no | |
| `STT_FAILED` | — | yes | |
| `STT_EMPTY` | — | yes | |
| `TTS_FAILED` | — | yes | |
| `AUDIO_INVALID` | 422 | no | |
| `ACTION_INVALID` | — | no | chỉ trong receipts |
| `WORKER_UNAVAILABLE` | — | yes | |
| `DEPENDENCY_UNAVAILABLE` | 503 | yes | |
| `STORAGE_FULL` | 507 | yes | |
| `PRIVATE_DISABLED` | 404 | no | cố ý giống not found |
| `PRIVATE_SESSION_REQUIRED` | 401 | no | |
| `PRIVATE_SESSION_EXPIRED` | 401 | no | |
| `PRIVATE_PIN_INVALID` | 401 | no | |
| `PRIVATE_PIN_REQUIRED` | 403 | no | biometric không được phép lúc này; dùng PIN (PRIVACY_SPEC §5.2.3) |
| `PRIVATE_BIOMETRIC_INVALID` | 401 | no | chữ ký/challenge không hợp lệ |
| `PRIVATE_LOCKED_OUT` | 423 | yes | `Retry-After` |
| `ASSET_POLICY_CONFIRM_REQUIRED` | 422 | no | override thêm `daily`/`assistant` cho asset sensitivity ≥ suggestive cần `confirm_sensitive=true` (CHARACTER_SYSTEM §17.3) |
| `NOT_FOUND` | 404 | no | |
| `CONFLICT` | 409 | no | |

---

## 15. Observability

- Log JSON có `request_id`, `turn_id`, `job_id`, `user_id` (hash), `mode`.
- Metrics (Prometheus endpoint `/metrics` chỉ trong internal network): `turn_duration_seconds{stage}`, `llm_latency_seconds{purpose}`, `llm_errors_total{code}`, `tts_latency_seconds`, `stt_latency_seconds`, `scheduler_lag_seconds`, `push_total{result}`, `job_failures_total{job}`. Metric private chỉ có tổng count, không label nội dung.
- Không lưu prompt/response. `LLM_PROMPT_LOGGING=true` chỉ hợp lệ khi `APP_ENV=local`, và không bao giờ áp dụng cho private (khởi động fail nếu cấu hình sai).

---

## 16. Biến môi trường

| Biến | Bắt buộc | Ví dụ / mặc định | Dùng bởi |
|---|---|---|---|
| `APP_ENV` | ✔ | `local|staging|production` | all |
| `DATABASE_URL_APP` | ✔ | `postgresql+asyncpg://hana_app:…@postgres:5432/hana` | api, worker, scheduler |
| `DATABASE_URL_PRIVATE` | ✔ nếu private bật | role `hana_private_rw` | api, worker_private |
| `REDIS_URL` | ✔ | `redis://redis:6379/0` | api, worker, scheduler |
| `REDIS_PRIVATE_URL` | ✔ nếu private bật | `redis://redis:6379/1` | api, worker_private |
| `NINE_ROUTER_BASE_URL` | ✔ | `http://host.docker.internal:20128/v1` | worker, worker_private |
| `NINE_ROUTER_API_KEY` | ✔ | secret | worker, worker_private |
| `LLM_MODEL_CHAT` | ✔ | tên model/combo trong 9Router | worker |
| `LLM_MODEL_EXTRACT` | ✔ | model rẻ | worker |
| `LLM_MODEL_REPORT` | ✔ | model mạnh | worker |
| `LLM_MODEL_PRIVATE` | ✔ nếu private bật | model cho phép nội dung người lớn | worker_private |
| `LLM_JSON_MODE` | | `auto|on|off` (auto) | worker |
| `STT_MODEL` | ✔ | | worker, worker_private |
| `TTS_MODEL`, `TTS_VOICE` | ✔ | | worker, worker_private |
| `EMBEDDING_MODEL` | | rỗng = tắt semantic retrieval | worker |
| `JWT_SECRET` | ✔ | ≥ 32 byte | api |
| `PRIVATE_DATA_KEY`, `PRIVATE_DATA_KEY_VERSION` | ✔ nếu private bật | base64 32 byte, `1` | api, worker_private |
| `PRIVATE_MODE_ENABLED` | | `false` | api |
| `FCM_ENABLED`, `FCM_SERVICE_ACCOUNT_FILE` | không (tùy chọn ở mọi môi trường) | `false` | worker |
| `MEDIA_ROOT`, `PRIVATE_MEDIA_ROOT` | ✔ | `/data/media`, `/data/private_media` | api, worker, worker_private |
| `ASSET_VAULT_ROOT` | ✔ | `/data/asset_vault` (volume `asset_vault`, không static route) | api |
| `LLM_PROMPT_LOGGING` | | `false` | worker |
| `LOG_LEVEL` | | `INFO` | all |

`BUSINESS_TZ` **không** là biến môi trường: là hằng số `Asia/Ho_Chi_Minh` trong `core/tz.py` (TIMEZONE_SPEC §3).

---

## 17. Performance budgets (mục tiêu local + VPS 2 vCPU)

| Chỉ số | p50 | p95 |
|---|---|---|
| POST /v1/turns → 202 | 80 ms | 300 ms |
| Submit → `reply.ready` (text, không action) | 4 s | 12 s |
| `reply.ready` → `tts.segment #0` | 1.2 s | 3 s |
| PTT release → `transcript.final` (câu 5s) | 2 s | 6 s |
| Chuyển core state trên client (event → frame đầu clip mới) | 250 ms | 500 ms |
| Scheduler lag (due → enqueue) | 15 s | 30 s |
| Cold start app → stage idle hiển thị | 1.5 s | 3 s |
