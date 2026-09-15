# HANA — PRIVACY & PRIVATE MODE SPEC

Phiên bản: 1.1 (Phase 1 + Final Decision Patch) · Vị trí canonical: `repo/docs/` · Quyết định chốt: ARCHITECTURE §0.1
Phụ thuộc: `ARCHITECTURE.md` §2.3, §4, §7.1, §10, §11, §13; `CHARACTER_SYSTEM.md` §4.6, §13; `AI_PROTOCOL.md` §3, §11; `VOICE_SPEC.md` §10; `MEMORY_SPEC.md` §3, §7.5.

---

## 1. Nguyên tắc

1. **Private mode là một vùng cách ly**, không phải một "cờ" trên dữ liệu chung. Cách ly ở mọi tầng: route, process, DB schema + role, Redis DB, queue, blob root, model LLM, prompt, cache thiết bị, Character Engine instance.
2. **Chỉ mở chủ động**: thao tác UI + PIN do server xác minh. Không gì khác mở được (INV-07).
3. **Rò rỉ một chiều bị cấm tuyệt đối**: private → normal không được có asset, lịch sử, notification, memory, dấu vết sử dụng (INV-04, INV-05, INV-06).
4. **Chiều ngược lại có giới hạn**: private được đọc read-only một tập nhỏ dữ liệu normal (profile, preference, cách xưng hô) để Hana vẫn là Hana.
5. **Tối thiểu hóa dữ liệu**: không lưu private trên disk thiết bị (trừ asset cache mã hóa), mã hóa private at rest trên server, xóa audio sớm, không log nội dung.
6. **Fail-closed**: nghi ngờ → khóa private, loại asset, từ chối request.

---

## 2. Phân loại dữ liệu

| Lớp | Mô tả | Ví dụ | Bảo vệ |
|---|---|---|---|
| D0 | Công khai / kỹ thuật | app version, manifest normal | — |
| D1 | Cá nhân normal | chat, tasks, reminders, settings | TLS, auth, DB không public |
| D2 | Nhạy cảm normal | memories, journal, reports, voice input | D1 + redaction log + xóa audio 24h |
| D3 | Private | private messages, private memories, private summaries, private assets, private TTS/voice | cách ly §6 + mã hóa app-level + không disk thiết bị + không log + không notification |
| DS | Secret | password hash, PIN hash, JWT secret, provider keys, private data key | env server / Keystore; không log, không repo |

---

## 3. Threat model

| # | Mối đe dọa | Mục tiêu bảo vệ | Kiểm soát |
|---|---|---|---|
| T1 | Lỗi code: truy vấn normal chạm dữ liệu private | D3 | DB role không có grant; import-linter; router tách; test isolation §13 |
| T2 | LLM normal "nhớ" chuyện private | D3 | Worker normal không có credential private; context builder normal không có đường truy cập |
| T3 | Notification lộ nội dung private trên lock screen | D3 | Không tồn tại đường tạo notification từ private; worker private không có FCM credential |
| T4 | Người khác nhìn màn hình / recents / screenshot | D3 | FLAG_SECURE, privacy overlay khi inactive, khóa khi background > 60 s |
| T5 | Mất điện thoại đang mở khóa | D3 | PIN private bắt buộc; biometric chỉ Class 3, tùy chọn, key vô hiệu khi đổi sinh trắc học, bắt nhập lại PIN sau 72 giờ; session ngắn, khóa khi idle |
| T6 | Trích xuất APK / backup Android | D3 asset | Private asset không trong APK; `allowBackup=false`; cache private mã hóa |
| T7 | Truy cập filesystem thiết bị (root/debug) | D3 | Không lưu message private; asset cache mã hóa, key trong Keystore; `prv_rt` bị xóa |
| T8 | Dump DB / backup server bị lộ | D3 | Mã hóa AES-GCM app-level, key không nằm trong DB/backup |
| T9 | Log server / access log | D2, D3 | Redaction; tắt access log cho `/v1/private/*`; private logger chỉ id + code |
| T10 | 9Router / provider lưu prompt | D2, D3 | Tắt log request trong 9Router (bắt buộc kiểm chứng); model private riêng; chấp nhận rủi ro provider (ghi rõ cho người dùng) |
| T11 | Bàn phím học từ ngữ private | D3 | `enableIMEPersonalizedLearning=false` |
| T12 | Clipboard | D3 | Tắt copy/select trong private |
| T13 | Deep link / state restoration mở lại private | D3 | Không có route deep link private; tắt restoration cho route private |
| T14 | Prompt injection khiến Hana nhắc private ở normal | D3 | Normal context không chứa dữ liệu private — không có gì để lộ |
| T15 | Dấu vết thời điểm dùng private trong dữ liệu normal | metadata D3 | Private không cập nhật `relationship_state`, `audit_log`, `llm_calls`, metrics có label |
| T16 | Nội dung bất hợp pháp trong private | pháp lý/an toàn | Giới hạn tuyệt đối §10, guard từ khóa + policy model |

---

## 4. Bảo vệ dữ liệu normal (tóm tắt)

- TLS bắt buộc ở staging/production. Cleartext chỉ flavor `dev`.
- Access token RAM; refresh token trong `flutter_secure_storage`.
- Logout: xóa drift DB, secure storage (trừ `device_id`), cache voice, hủy local notifications, gọi `/v1/auth/logout`.
- Android: `allowBackup=false`, `dataExtractionRules` loại toàn bộ, không ghi log nội dung trong release.
- Server: redaction (ARCHITECTURE §11.2 quy tắc 8), audio input xóa sau 24 h, TTS 7 ngày, prompt không log.
- Notification preview mặc định `generic` cho companion/report; reminder hiển thị tiêu đề do người dùng đặt.

---

## 5. Private mode

### 5.1 Bật tính năng

| Điều kiện | Chi tiết |
|---|---|
| Server | `PRIVATE_MODE_ENABLED=true` và có `DATABASE_URL_PRIVATE`, `REDIS_PRIVATE_URL`, `PRIVATE_DATA_KEY`, `LLM_MODEL_PRIVATE`, `PRIVATE_MEDIA_ROOT`; thiếu bất kỳ → private coi như tắt, log cảnh báo khi khởi động |
| Tắt | Mọi `/v1/private/*` trả 404 `PRIVATE_DISABLED`; client ẩn mục trong Settings |
| Thiết lập lần đầu | Settings → "Chế độ riêng tư" → màn giải thích → xác nhận 18+ và hiểu nội dung là hư cấu giữa người trưởng thành → nhập mật khẩu tài khoản → **đặt PIN 6 số (bắt buộc, nhập 2 lần)** → `POST /v1/private/setup`. Sau khi setup xong, app CÓ THỂ hỏi "Bật mở khóa bằng vân tay/khuôn mặt?" (tùy chọn, §5.2.2) |

Mục "Chế độ riêng tư" trong Settings không hiển thị số lượng, thời điểm dùng gần nhất, badge, hay preview.

### 5.2 Mở (chỉ chủ động) — PIN bắt buộc, biometric tùy chọn

**Nguyên tắc chốt (D5):**

- **PIN 6 số là credential bắt buộc** của private mode: không thể setup private mà không có PIN; mọi trường hợp biometric không dùng được đều quay về PIN.
- **Biometric là lớp tiện lợi tùy chọn**, mặc định **tắt**, chỉ bật được sau khi nhập đúng PIN; không bao giờ là credential duy nhất.
- Không dùng mật khẩu/PIN khóa màn hình thiết bị (device credential) thay cho PIN private.

```
Người dùng: Settings → "Chế độ riêng tư" → "Mở"
  (FLAG_SECURE bật từ màn mở khóa)
  A. Nếu thiết bị này có biometric key đã enroll, server không yêu cầu PIN (§5.2.3), và hardware sẵn sàng:
       → luồng biometric §5.2.2; người dùng luôn có nút "Dùng PIN"
     ngược lại → luồng PIN §5.2.1
  B. Server tạo session → 201
  C. Client: tạo PrivateScope (ProviderScope con), tải manifest private, dựng private Character Engine,
     điều hướng /private (thay thế stack)
```

#### 5.2.1 Luồng PIN (bắt buộc, luôn khả dụng)

1. Màn PIN → `POST /v1/private/session {method: "pin", pin}`.
2. Server: kiểm tra lockout → argon2id verify → `private_settings.last_pin_unlock_at = now` → tạo session.

#### 5.2.2 Luồng biometric (tùy chọn)

**Enroll** (trong private session đang mở, Cài đặt riêng tư → "Mở khóa bằng sinh trắc học"):

1. Client kiểm tra `local_auth` có `BIOMETRIC_STRONG` (Class 3). Không có → ẩn tùy chọn.
2. Người dùng nhập lại PIN.
3. MethodChannel `hana/biometric_key.generate(alias)`: Android Keystore EC P-256, `setUserAuthenticationRequired(true)`, `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`, `setInvalidatedByBiometricEnrollment(true)`, ưu tiên StrongBox; trả public key (SPKI DER, base64).
4. `POST /v1/private/biometric/enroll {pin, device_id, key_id, public_key}` → server lưu `private_biometric_keys`; tối đa 1 key active mỗi device.

**Unlock:**

1. `POST /v1/private/session/challenge {device_id}` → `{challenge_id, nonce, expires_at}` (nonce 32 byte, TTL 60 s, dùng một lần, Redis db1 `prv:chal:{challenge_id}`). Nếu server yêu cầu PIN → 403 `PRIVATE_PIN_REQUIRED` → luồng PIN.
2. `hana/biometric_key.sign(alias, payload)` với BiometricPrompt (CryptoObject, negative button "Dùng PIN"); payload = `"hana-private-unlock|v1|{user_id}|{device_id}|{challenge_id}|{nonce}"`, ECDSA SHA-256.
3. `POST /v1/private/session {method: "biometric", device_id, key_id, challenge_id, signature}`.
4. Server: kiểm tra lockout → challenge tồn tại, chưa dùng, khớp device → verify chữ ký với public key active → tạo session. Challenge bị xóa ngay khi dùng (thành công hay thất bại).

#### 5.2.3 Khi nào bắt buộc quay về PIN

| Điều kiện | Hành vi |
|---|---|
| Chưa enroll / đã tắt biometric / thiết bị không có Class 3 | chỉ luồng PIN |
| Người dùng bấm "Dùng PIN" hoặc hủy BiometricPrompt, hoặc OS khóa biometric do sai nhiều lần | luồng PIN |
| Key Keystore bị vô hiệu (thêm vân tay mới, gỡ khóa màn hình → `KeyPermanentlyInvalidatedException`) | client xóa key, gọi `DELETE /v1/private/biometric/{key_id}` (best effort), luồng PIN |
| `now − last_pin_unlock_at > pin_reentry_hours` (mặc định 72 giờ) | challenge trả 403 `PRIVATE_PIN_REQUIRED` |
| PIN đang lockout | cả PIN và biometric trả 423 `PRIVATE_LOCKED_OUT` |
| 5 lần liên tiếp chữ ký không hợp lệ ở server cho một key | key bị revoke, luồng PIN |
| Đổi PIN / reset PIN / private wipe / thu hồi device / delete-all | **mọi** biometric key của user (hoặc device) bị revoke |

Không thể mở private bằng: lệnh chat/voice, action LLM, notification, deep link, widget, shortcut, intent ngoài, khôi phục trạng thái sau khi app bị kill. App **luôn** khởi động ở normal mode.

Hana (LLM normal) không bao giờ gợi ý mở private (AI_PROTOCOL §3.1).

### 5.3 Session

| Mục | Giá trị |
|---|---|
| Token | 32 byte ngẫu nhiên, base64url, gửi header `X-Private-Session` |
| Lưu server | Redis db1 `prv:sess:{sha256(token)}` → `{user_id, device_id, created_at, last_seen_at}` |
| Ràng buộc | `user_id` = `sub` của access JWT, `device_id` = `did`; lệch → 401 |
| Idle TTL | 15 phút, gia hạn bởi mọi request private hoặc `POST /v1/private/session/heartbeat` (client gọi tối đa 1 lần/60 s khi có tương tác) |
| Absolute TTL | 2 giờ từ `created_at` |
| Client lưu | chỉ RAM (không secure storage, không disk) |
| Đồng thời | 1 session/device; tạo session mới → hủy session cũ của device |
| Phương thức tạo session | `pin` (luôn hợp lệ nếu không lockout) hoặc `biometric` (chỉ khi thỏa §5.2.3); session ghi `method` vào `private_audit_log` |
| PIN sai | `private_settings.failed_attempts += 1`; 5 lần → `locked_until = now + 15 phút`; tổng 15 lần không có lần đúng xen giữa → 24 giờ; đúng → reset cả hai bộ đếm. Lockout áp dụng cho **cả** PIN và biometric |
| Biometric sai | chữ ký không hợp lệ → `private_biometric_keys.failed_signatures += 1`; 5 lần liên tiếp → revoke key; không tăng bộ đếm PIN |
| PIN re-entry | `pin_reentry_hours` mặc định 72 (cấu hình 24..168): quá hạn kể từ `last_pin_unlock_at` → biometric bị từ chối cho đến khi nhập PIN |
| Argon2id | `m=65536 KiB, t=3, p=1`, salt 16 byte |
| Rate limit | 10 request `/v1/private/session` + 10 `/v1/private/session/challenge` mỗi 15 phút/device ngoài lockout |
| Redis down | Không tạo/xác minh được session → 503; private không dùng được (fail-closed) |

### 5.4 Khóa (thoát)

Trigger:

| Trigger | Hành vi |
|---|---|
| Người dùng bấm "Khóa" | khóa ngay |
| `AppLifecycleState.inactive` | hiện privacy overlay mờ đục ngay lập tức (không khóa) |
| `paused` ≥ 60 s | khóa khi resume (timer đo bằng monotonic clock) |
| `paused` < 60 s rồi `resumed` | gỡ overlay, tiếp tục |
| Không tương tác 15 phút | khóa |
| API trả `PRIVATE_SESSION_EXPIRED` / `PRIVATE_SESSION_REQUIRED` | khóa |
| Logout / refresh token bị thu hồi | khóa |
| App bị kill | lần khởi động sau: bước dọn dẹp 5–7 chạy trong `bootstrap` trước khi vẽ UI |

Quy trình khóa (idempotent, thứ tự bắt buộc):

```
1. Pop toàn bộ route /private, điều hướng về màn hình normal (Settings hoặc Home)
2. TtsQueue private stopAll; hủy SSE private; hủy upload đang chạy
3. Dispose private Character Engine + VideoPlayerController private
4. Dispose PrivateScope (xóa messages, memories, manifest khỏi RAM)
5. Xóa đệ quy <cache>/prv_rt/
6. Tắt FLAG_SECURE (khi đã ra khỏi mọi màn private)
7. DELETE /v1/private/session (best effort, không chờ)
```

Turn private đang xử lý trên server vẫn hoàn tất và lưu vào `hana_private`; người dùng thấy ở lần mở sau.

### 5.5 Cách ly UI (Flutter)

| Kiểm soát | Cách làm |
|---|---|
| Route | `/private/**` trong `go_router`, guard yêu cầu `PrivateSession` trong RAM; `restorationScopeId = null` |
| State | `ProviderScope` con chỉ tồn tại khi mở; provider normal không import provider private (§2.3 ARCHITECTURE) |
| Local DB | drift **không có** bảng private |
| Screenshot/recents | MethodChannel `hana/secure_window` → `WindowManager.LayoutParams.FLAG_SECURE` khi vào màn PIN/private |
| Bàn phím | `enableIMEPersonalizedLearning: false`, `enableSuggestions: false`, `autocorrect: false` |
| Copy/share | `SelectableText` không dùng; không menu copy/share cho message private |
| Giao diện | Theme accent riêng + nhãn "Riêng tư" cố định trên app bar (người dùng luôn biết mình đang ở mode nào) |
| Tìm kiếm | Không có tìm kiếm hệ thống / app search cho private |
| Notification | Không đặt local notification nào từ private scope |
| Media | TTS bytes RAM; voice file trong `prv_rt` |
| Crash report | Không gửi crash report nào kèm state/breadcrumb khi đang ở private (v1 không dùng dịch vụ crash report) |

### 5.6 Private assets

| Bước | Chi tiết |
|---|---|
| Manifest | `GET /v1/private/assets/manifest` → validate schema (CHARACTER_SYSTEM §4.4), `manifest_mode=private`; giữ RAM |
| Tải | Asset chưa có trong cache hoặc sha256 lệch → `GET /v1/private/assets/{asset_id}` (+ `/poster`, `/blur`); stream vào RAM ≤ 16 MB/file |
| Mã hóa cache | AES-256-GCM, key 32 byte sinh lần đầu, lưu `flutter_secure_storage` (Android Keystore); nonce 12 byte ngẫu nhiên mỗi file; file `<app_support>/prv_assets/<sha256(asset_id)>.bin` = `"HNP1" ‖ nonce ‖ ciphertext ‖ tag`; tên file không chứa asset_id |
| Giải mã runtime | Khi mở private: giải mã asset cần phát vào `<cache>/prv_rt/v/<random>.mp4` (tên ngẫu nhiên); verify sha256 sau giải mã; lỗi → xóa cache file, tải lại 1 lần |
| Xóa | Khóa → xóa `prv_rt`; "Xóa dữ liệu riêng tư trên máy" → xóa `prv_assets` + key; private wipe → cả hai |
| Normal | Normal engine không nhận private manifest; normal bundle không chứa private (CI scan) |

### 5.7 LLM trong private

- Model riêng `LLM_MODEL_PRIVATE`, prompt `policy_private.vi.md`, action/cue/context giới hạn (AI_PROTOCOL §11).
- **Provider/model private LLM: UNRESOLVED implementation choice** — benchmark ở phase private mode (AI_PROTOCOL §2.5); private mode không được bật ở staging/prod trước khi chốt provider và qua AC-PRV-17, AC-PRV-18.
- **Yêu cầu vận hành (bắt buộc trước khi bật private ở staging/prod):** cấu hình 9Router không lưu nội dung request/response (hoặc dùng instance/route không log); ghi kết quả kiểm chứng vào `docs/ENVIRONMENT_REPORT.md` phase tương ứng.
- Model từ chối nội dung → fallback template private trung tính (AI_PROTOCOL §11), không lặp lại nội dung người dùng.
- `private_content_guard` (§10.2) chạy **trước** LLM.

### 5.8 Ma trận khả năng

| Khả năng | Normal | Private |
|---|---|---|
| Chat text / voice / TTS | ✔ | ✔ |
| Core states + special normal | ✔ | ✔ |
| Special/core private assets | ✘ | ✔ |
| Memory normal (đọc) | ✔ | chỉ `v_profile_memories` + `relationship_state` |
| Memory normal (ghi) | ✔ | ✘ |
| Memory private | ✘ | ✔ |
| Tasks, reminders | ✔ | ✘ |
| Work journal, reports | ✔ | ✘ |
| Standing instructions | ✔ | ✘ |
| Proactive messages / daily companion | ✔ | ✘ |
| Push / local notifications | ✔ | ✘ |
| Tìm kiếm lịch sử | ✔ | ✘ |
| Export dữ liệu | ✔ | ✘ (v1) |
| Cập nhật relationship_state | ✔ | ✘ |

Yêu cầu một khả năng ✘ trong private (vd "nhắc anh 8h mai") → Hana trả lời không làm được ở chế độ riêng tư, gợi ý ra chế độ thường; không lưu gì sang normal.

### 5.9 Private API

Mọi endpoint yêu cầu access JWT. Cột "Session" = cần `X-Private-Session`.

| Method | Path | Session | Body / Ghi chú |
|---|---|---|---|
| GET | `/v1/private/status` | ✘ | `{enabled, setup_completed}` |
| POST | `/v1/private/setup` | ✘ | `{password, pin, adult_confirmed: true}`; `pin` bắt buộc (regex `^\d{6}$`); chỉ khi chưa setup |
| POST | `/v1/private/session/challenge` | ✘ | `{device_id}` → `{challenge_id, nonce, expires_at}`; 403 `PRIVATE_PIN_REQUIRED` nếu biometric không được phép (§5.2.3) |
| POST | `/v1/private/session` | ✘ | `{method:"pin", pin}` hoặc `{method:"biometric", device_id, key_id, challenge_id, signature}` → `{session_token, method, idle_expires_at, absolute_expires_at}` |
| POST | `/v1/private/session/heartbeat` | ✔ | 204 |
| DELETE | `/v1/private/session` | ✔ | 204 |
| POST | `/v1/private/biometric/enroll` | ✔ | `{pin, device_id, key_id, public_key}`; PIN bắt buộc nhập lại |
| DELETE | `/v1/private/biometric/{key_id}` | ✘ | chỉ key của chính device trong JWT; 204 |
| GET | `/v1/private/biometric` | ✔ | danh sách key active (device_name, created_at, last_used_at) |
| POST | `/v1/private/pin/change` | ✔ | `{old_pin, new_pin}`; revoke mọi biometric key |
| POST | `/v1/private/pin/reset` | ✘ | `{password, new_pin}`; giữ dữ liệu; hủy mọi session; revoke mọi biometric key; audit private |
| PATCH | `/v1/private/settings` | ✔ | `{retention_days: null|7|30|90, pin_reentry_hours: 24..168}` |
| POST | `/v1/private/turns` | ✔ | như `/v1/turns` |
| POST | `/v1/private/turns/voice` | ✔ | như `/v1/turns/voice` |
| GET | `/v1/private/turns/{id}/events` | ✔ | SSE, stream Redis db1 `ev:pturn:{id}` |
| GET | `/v1/private/turns/{id}` | ✔ | |
| POST | `/v1/private/turns/{id}/cancel` | ✔ | |
| GET | `/v1/private/messages` | ✔ | cursor; giải mã server-side |
| DELETE | `/v1/private/messages` | ✔ | xóa lịch sử private (giữ memory) |
| GET/POST/PATCH/DELETE | `/v1/private/memories[/{id}]` | ✔ | |
| POST | `/v1/private/action-executions/{id}/undo` | ✔ | |
| GET | `/v1/private/assets/manifest` | ✔ | |
| GET | `/v1/private/assets/{asset_id}` \| `/poster` \| `/blur` | ✔ | `asset_id` validate regex `^p\.(core|special)\.[a-z0-9_]+\.\d{2}$` hoặc thuộc manifest; không nhận path |
| GET | `/v1/private/media/{media_id}` | ✔ | TTS private |
| POST | `/v1/private/wipe` | ✔ | `{pin, confirm: "XOA"}` → job `private_wipe` |

Response private có header `Cache-Control: no-store`.

### 5.10 Voice private

VOICE_SPEC §10.

### 5.11 Không notification

- Không có kind notification cho private; `worker_private` không có `FCM_SERVICE_ACCOUNT_FILE`.
- Turn private hoàn tất khi app đã khóa → không báo gì.
- Private không có proactive message.

---

## 6. Cách ly server

### 6.1 Tách tầng

| Tầng | Normal | Private |
|---|---|---|
| Router | `app/api/v1/*` | `app/api/v1/private/*` (dependency `require_private_session`) |
| Process worker | `worker` | `worker_private` |
| Queue | `hana:normal` (Redis db0) | `hana:private` (Redis db1) |
| Turn event stream | `ev:turn:*` (db0) | `ev:pturn:*` (db1) |
| DB role | `hana_app` | `hana_private_rw` |
| DB schema | `hana` | `hana_private` |
| Blob | `MEDIA_ROOT` | `PRIVATE_MEDIA_ROOT` (khác volume) |
| LLM model | `LLM_MODEL_CHAT/EXTRACT/REPORT` | `LLM_MODEL_PRIVATE` |
| Log | logger `hana.*` | logger `hana.private.*` (chỉ id + code) |
| Access log | bình thường | tắt cho path `/v1/private/*` (uvicorn filter + Caddy `log_skip`) |

### 6.2 Bảng `hana_private`

**private_settings**

| user_id PK | pin_hash text NOT NULL (argon2id của PIN 6 số) | pin_set_at timestamptz | last_pin_unlock_at timestamptz null | pin_reentry_hours smallint (72) | failed_attempts int | failed_total_since_success int | locked_until timestamptz null | adult_confirmed_at timestamptz | retention_days int null | created_at | updated_at |

**private_biometric_keys** (tùy chọn; không có row nào ⇒ chỉ PIN)

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK | |
| user_id | uuid | |
| device_id | text | unique `(device_id) WHERE revoked_at IS NULL` |
| key_id | text | alias Keystore do client sinh |
| public_key_spki | bytea | EC P-256 |
| failed_signatures | smallint | reset khi thành công |
| created_at, last_used_at | timestamptz | |
| revoked_at | timestamptz null | |
| revoke_reason | text null `user|pin_changed|pin_reset|invalidated|failed_signatures|device_revoked|wipe|delete_all` | |

Không có dữ liệu sinh trắc học nào rời thiết bị; server chỉ giữ public key.

**private_turns** — như `hana.turns` (ARCHITECTURE §7.2), FK tới bảng private.

**private_messages**

| Cột | Kiểu |
|---|---|
| id | uuid PK (v7) |
| user_id | uuid |
| turn_id | uuid null |
| role | text `user|assistant|system_event` |
| origin | text `chat|voice|system` |
| text_ciphertext | bytea |
| text_nonce | bytea (12) |
| key_version | smallint |
| character_cue | jsonb null |
| receipts | jsonb (chỉ nhãn chung, vd "Đã ghi nhớ", không chứa nội dung) |
| created_at | timestamptz |

**private_memories** — cấu trúc MEMORY_SPEC §4.1 trừ `content`, `normalized`, `embedding`, `valid_until_local_date`; thêm `content_ciphertext bytea`, `content_nonce bytea`, `key_version smallint`. `category` ∈ MEMORY_SPEC §3 (private).

**private_summaries** — `id, user_id, local_date, summary_ciphertext, summary_nonce, key_version, mood, message_count, created_at`; unique `(user_id, local_date)`.

**private_extraction_cursors** — như `hana.memory_extraction_cursors`.

**private_media_objects** — như `hana.media_objects`, `kind ∈ {tts_audio, voice_input}`, không `cache_key`.

**private_llm_calls**, **private_action_executions** — như bản normal.

**private_audit_log** — `id, user_id, action (setup|session_opened|session_closed|pin_failed|pin_locked|pin_changed|pin_reset|biometric_enrolled|biometric_revoked|biometric_failed|guard_blocked|wipe|memory_deleted|history_cleared); `meta.method` = `pin|biometric` cho `session_opened`, meta jsonb (không nội dung), created_at`.

### 6.3 Mã hóa app-level

| Mục | Giá trị |
|---|---|
| Thuật toán | AES-256-GCM (`cryptography.hazmat.primitives.ciphers.aead.AESGCM`) |
| Key | `PRIVATE_DATA_KEY` (base64, 32 byte) theo `PRIVATE_DATA_KEY_VERSION`; hỗ trợ nhiều key cũ để giải mã: `PRIVATE_DATA_KEYS_OLD="1:<b64>,2:<b64>"` |
| Nonce | 12 byte `os.urandom` mỗi lần mã hóa |
| AAD | `f"{table}:{column}:{row_id}:{user_id}".encode()` — chống hoán đổi ciphertext giữa row |
| Mã hóa | text UTF-8 trước khi ghi; không bao giờ ghi plaintext |
| Rotation | job `private_reencrypt` (thủ công) giải mã bằng key cũ, mã hóa bằng key mới, cập nhật `key_version` |
| Mất key | dữ liệu private không phục hồi được (chấp nhận, ghi rõ trong tài liệu vận hành) |
| Phạm vi v1 | key do server giữ (không dẫn xuất từ PIN) — cải tiến tương lai: bọc key bằng khóa dẫn xuất từ PIN |

### 6.4 Grants (`infra/postgres/init/20_grants.sql`)

```sql
REVOKE ALL ON SCHEMA hana_private FROM PUBLIC;
REVOKE ALL ON SCHEMA hana FROM PUBLIC;

GRANT USAGE ON SCHEMA hana TO hana_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA hana TO hana_app;
-- hana_app: KHÔNG có USAGE trên hana_private

GRANT USAGE ON SCHEMA hana_private TO hana_private_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA hana_private TO hana_private_rw;
GRANT USAGE ON SCHEMA hana TO hana_private_rw;
GRANT SELECT ON hana.users, hana.relationship_state, hana.v_profile_memories TO hana_private_rw;
GRANT SELECT (user_id, speak_replies, tts_speed, quiet_hours_start_local, quiet_hours_end_local)
      ON hana.user_settings TO hana_private_rw;
```

`ALTER DEFAULT PRIVILEGES` tương ứng để bảng mới tạo bởi `hana_migrator` giữ đúng grant. Migration test kiểm tra grants sau mỗi lần `alembic upgrade`.

### 6.5 Backup

`pg_dump` gồm cả hai schema; nội dung private là ciphertext; `PRIVATE_DATA_KEY` **không** nằm trong backup, không nằm trên cùng volume backup.

---

## 7. Cách ly Redis

| DB | Nội dung | Ai truy cập |
|---|---|---|
| 0 | queue normal, `ev:turn:*`, rate limit normal, leader lock, debounce normal, cancel flags normal | api, worker, scheduler |
| 1 | queue private, `ev:pturn:*`, `prv:sess:*`, rate limit private session, `pmemx:*`, cancel flags private | api, worker_private |

Production CÓ THỂ dùng Redis ACL: user `hana_normal` chỉ `SELECT 0`, user `hana_private` chỉ `SELECT 1` (khuyến nghị, không bắt buộc v1).

Mọi key private có TTL (session ≤ 2 h, stream 15 phút sau kết thúc, debounce ≤ 15 phút).

---

## 8. Retention

| Dữ liệu | Thời hạn | Cơ chế |
|---|---|---|
| Normal messages | đến khi người dùng xóa (`DELETE /v1/messages` hoặc delete-all) | — |
| Private messages | đến khi xóa, hoặc `retention_days` (7/30/90) | job `private_cleanup` 04:10 local |
| Private summaries | theo `retention_days` như messages | như trên |
| turns / private_turns (metadata) | 90 ngày | job cleanup hằng ngày |
| llm_calls / private_llm_calls | 30 ngày | |
| action_executions | 90 ngày | |
| audit_log / private_audit_log | 180 ngày | |
| job_runs, routine_runs | 180 ngày (report giữ vĩnh viễn) | |
| notifications | 90 ngày | |
| TTS normal / private | 7 ngày / 1 giờ | cleanup_media |
| Voice input normal / private | 24 giờ / ngay sau STT (≤ 10 phút) | |
| Export zip | 24 giờ | |
| Journal entry đã xóa | 30 ngày | |
| Memory superseded | 180 ngày | |
| Redis turn streams | 15 phút sau kết thúc | EXPIRE |
| Backup | 14 bản | |
| Thiết bị: drift normal | 500 message, occurrences 14 ngày, journal 60 ngày | |
| Thiết bị: private | RAM; asset cache mã hóa đến khi xóa | |

---

## 9. Quyền của người dùng

| Quyền | Cách thực hiện |
|---|---|
| Xem ký ức | Màn Ký ức (normal) / màn Ký ức riêng tư (trong private) |
| Sửa/xóa ký ức | UI hoặc chat `memory.forget` |
| Xóa lịch sử chat normal | Settings → "Xóa lịch sử trò chuyện" → xác nhận → `DELETE /v1/messages` (giữ memory/journal/report) |
| Xóa lịch sử private | Trong private → `DELETE /v1/private/messages` |
| Xóa toàn bộ dữ liệu private | Trong private → "Xóa sạch" → PIN + gõ `XOA` → `private_wipe`: xóa mọi row `hana_private` của user, `PRIVATE_MEDIA_ROOT` của user, Redis db1 key của user, hủy session, revoke biometric keys; client xóa `prv_assets`, key cache và key biometric Keystore |
| Export dữ liệu normal | Settings → Xuất dữ liệu → job `data_export` → zip: `messages.json`, `memories.json`, `journal.json`, `reports/*.md`, `tasks.json`, `reminders.json`, `instructions.json`, `settings.json`; tải qua `/v1/media/{id}` 24 h |
| Xóa toàn bộ dữ liệu | Settings → "Xóa tất cả dữ liệu" → mật khẩu → `POST /v1/data/delete-all`: xóa toàn bộ normal + private của user (giữ tài khoản owner), đăng xuất mọi device |
| Thu hồi thiết bị | Settings → Thiết bị → Thu hồi → `POST /v1/devices/{id}/revoke`: thu hồi refresh token, hủy private session, revoke biometric key của device, xóa FCM token |

---

## 10. Content policy

### 10.1 Giới hạn tuyệt đối (cả hai mode)

- Không nội dung tình dục liên quan trẻ vị thành niên, người có vẻ/được mô tả là dưới 18 tuổi, bối cảnh học sinh, hoặc hình dáng trẻ con.
- Không phi đồng thuận, cưỡng ép, bạo lực tình dục.
- Không loạn luân, thú tính.
- Không tình dục hóa người thật có danh tính.
- Không hướng dẫn hành vi bất hợp pháp gây hại.
- Hana luôn là người trưởng thành (persona xác định tuổi trưởng thành, không "đóng vai" trẻ hơn).

### 10.2 `private_content_guard`

Chạy trên text người dùng (và transcript) **trước** khi gọi LLM private:

- Danh sách từ khóa/biểu thức trong `domain/private/guard_patterns.yaml` (vd `\b(1[0-7]|[1-9])\s*tuổi\b`, `học sinh`, `trẻ em`, `bé gái`, `lolita`, `vị thành niên`, …), so khớp trên chuỗi lowercase không dấu và có dấu.
- Khớp → không gọi LLM; assistant message template "Chuyện này em không thể tham gia được." cue `concerned low`; `private_audit_log(action=guard_blocked)` không kèm nội dung.
- Dương tính giả chấp nhận được.
- Cũng áp dụng cho `memory.remember` content trong private.

### 10.3 Normal mode

AI_PROTOCOL §3.2: không nội dung tình dục tường minh.

---

## 11. Failure modes (rò rỉ và biện pháp)

| # | Kịch bản rò rỉ | Chặn bởi | Nếu vẫn xảy ra |
|---|---|---|---|
| L1 | Query normal đọc `hana_private` | role grants | lỗi permission → 500, log critical, test fail |
| L2 | Worker normal xử lý job private | queue/Redis db tách; worker normal không có env private | job không thể tới worker normal |
| L3 | Private SSE vào normal engine | endpoint + stream key + client scope tách | — |
| L4 | Notification từ private | không có code path; không FCM credential ở worker_private | — |
| L5 | Private message lưu drift | drift không có bảng private; lint import | test quét file DB sau phiên private |
| L6 | Asset private trong APK | CI scan | build fail |
| L7 | `prv_rt` còn lại sau crash | wipe ở bootstrap | — |
| L8 | Screenshot / recents | FLAG_SECURE + overlay | — |
| L9 | Access log lộ thời điểm dùng private | tắt log path private | — |
| L10 | Normal Hana nhắc chuyện private | normal context không có dữ liệu private; relationship không cập nhật từ private | — |
| L11 | 9Router log prompt private | cấu hình vận hành (§5.7) | nằm ngoài kiểm soát code; ghi vào báo cáo môi trường |
| L12 | DB dump | AES-GCM | cần key |
| L13 | Private session token bị đánh cắp | gắn device_id + user_id, TTL ngắn, TLS | thu hồi device |
| L14 | Mở private qua deep link/khôi phục trạng thái | guard RAM session, không restoration | — |
| L15 | Undo receipt private hiển thị ở normal | `private_action_executions` riêng; endpoint undo private riêng | — |

---

## 12. Invariants

INV-04, INV-05, INV-06, INV-07, INV-14, INV-15 (ARCHITECTURE §13), cộng:

| ID | Invariant |
|---|---|
| PRV-01 | App luôn khởi động ở normal mode; không trạng thái private nào tồn tại qua process restart. |
| PRV-02 | Không file nào chứa plaintext private (message, transcript, TTS, asset giải mã) tồn tại trên thiết bị khi private đang khóa. |
| PRV-03 | Không row nào trong schema `hana` được tạo/sửa do một request/job private. |
| PRV-04 | Mọi nội dung văn bản private trong DB là ciphertext AES-GCM với AAD gắn row. |
| PRV-05 | Không log line nào của private chứa nội dung người dùng hoặc Hana. |
| PRV-06 | Private session không bao giờ được ghi xuống disk trên thiết bị. |
| PRV-07 | PIN 6 số luôn tồn tại khi private đã setup và luôn mở được private (trừ lockout); biometric không bao giờ là credential duy nhất, chỉ được enroll sau khi nhập PIN, và mọi key bị revoke khi đổi/reset PIN. |

---

## 13. Bộ test cách ly bắt buộc

| Test | Kỳ vọng |
|---|---|
| ISO-01 | Kết nối role `hana_app`: `SELECT 1 FROM hana_private.private_messages` | permission denied |
| ISO-02 | Role `hana_private_rw`: `INSERT INTO hana.memories …` | permission denied |
| ISO-03 | Role `hana_private_rw`: `SELECT * FROM hana.memories` | permission denied; `v_profile_memories` OK |
| ISO-04 | import-linter contracts ARCHITECTURE §2.3 | pass |
| ISO-05 | Sau 1 phiên private (3 turn text, 1 voice, 1 memory.remember), so snapshot mọi bảng schema `hana` trước/sau | không đổi, ngoại trừ `refresh_tokens`/`devices` do endpoint auth normal (`/v1/auth/refresh`) gây ra; request `/v1/private/*` không cập nhật `devices.last_seen_at` |
| ISO-06 | Sau phiên private, prompt của turn normal kế tiếp (FakeChatGateway ghi lại) | không chứa chuỗi nào từ phiên private |
| ISO-07 | Gửi `reminder.create` trong private (FakeChatGateway) | `ACTION_NOT_ALLOWED`, không row `reminders` |
| ISO-08 | Normal manifest validator với asset `mode=private` | từ chối |
| ISO-09 | APK scan | không asset private |
| ISO-10 | Flutter integration: mở private, phát clip private, background 61 s, resume | màn khóa; `prv_rt` rỗng; FLAG_SECURE tắt ở màn normal |
| ISO-11 | Kill app khi đang private, khởi động lại | vào normal; `prv_rt` rỗng |
| ISO-12 | Endpoint normal `/v1/turns/{private_turn_id}` | 404 |
| ISO-13 | Endpoint private không header session | 401 `PRIVATE_SESSION_REQUIRED` |
| ISO-14 | Session token dùng với access JWT của device khác | 401 |
| ISO-15 | `PRIVATE_MODE_ENABLED=false` → mọi `/v1/private/*` | 404 |
| ISO-16 | Đọc raw `private_messages.text_ciphertext` | không giải mã được nếu thiếu key; đổi `row_id` trong AAD → lỗi xác thực |
| ISO-17 | Grep log toàn bộ test suite private | không chứa chuỗi nội dung fixture |
| ISO-18 | Drift DB file sau phiên private | không chứa chuỗi nội dung fixture (quét bytes) |
| ISO-19 | `notifications` + FCM mock sau phiên private | 0 bản ghi mới / 0 lần gửi |
| ISO-20 | Chat normal: "mở chế độ riêng tư đi em" (FakeChatGateway trả bất kỳ envelope) | không có action nào mở private; client không điều hướng |
| ISO-21 | `POST /v1/private/setup` thiếu PIN / PIN không phải 6 chữ số | 422, không setup |
| ISO-22 | Biometric enroll không kèm PIN đúng | 401, không có key |
| ISO-23 | Biometric unlock với chữ ký sai / challenge đã dùng / challenge của device khác | 401, không session; 5 lần sai → key revoked |
| ISO-24 | `last_pin_unlock_at` quá 72 giờ | challenge 403 `PRIVATE_PIN_REQUIRED`; PIN đúng vẫn mở được |
| ISO-25 | Đổi PIN | mọi `private_biometric_keys` có `revoked_at`; biometric unlock sau đó bị từ chối |
| ISO-26 | Lockout PIN đang hiệu lực | biometric unlock cũng trả 423 |
