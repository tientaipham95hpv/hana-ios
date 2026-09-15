# HANA — ACCEPTANCE CRITERIA

Phiên bản: 1.1 (Phase 1 + Final Decision Patch) · Vị trí canonical: `repo/docs/` · Quyết định chốt: ARCHITECTURE §0.1
Áp dụng cho: toàn bộ implementation v1. Một hạng mục chỉ được coi là xong khi mọi AC liên quan PASS.

---

## 0. Quy ước

### 0.1 Mức kiểm chứng

| Mã | Mức | Môi trường |
|---|---|---|
| U | Unit test | pytest / flutter test, không I/O thật |
| I | Integration test | Docker Postgres 16 + Redis 7 thật; `FakeChatGateway`, `FakeSttProvider`, `FakeTtsProvider`; `FakeClock` |
| W | Widget test | Flutter test với fake repositories |
| E | End-to-end | Android emulator/thiết bị + stack local compose + Fake gateway (hoặc 9Router thật khi ghi rõ) |
| C | CI check | lint, import-linter, grep, scan APK, ffprobe |
| M | Manual QA | checklist có ghi kết quả, ảnh/video bằng chứng |
| L | Live | 9Router thật (đánh dấu `-m live_9router`), không chạy trong CI mặc định |

### 0.2 Definition of Done (mọi hạng mục)

- DOD-1: Code theo layout ARCHITECTURE §5 và quy tắc import §2.3.
- DOD-2: AC liên quan PASS ở mức ghi trong bảng.
- DOD-3: Không invariant INV-01…INV-20 nào bị vi phạm (test tương ứng xanh).
- DOD-4: Migration có downgrade (trừ khi ghi rõ không thể), grants test xanh.
- DOD-5: Không secret trong repo (secret scan xanh).
- DOD-6: Log không chứa nội dung người dùng (test redaction xanh).
- DOD-7: Tài liệu spec được cập nhật nếu hành vi khác spec (khác spec mà không cập nhật = FAIL).

---

## 1. Tổng quát & hạ tầng

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-GEN-01 | `docker compose -f infra/compose.dev.yml up` khởi động postgres, redis, api, worker, worker_private, scheduler; `GET /readyz` = 200 trong ≤ 60 s | I/M |
| AC-GEN-02 | `readyz` trả 503 khi dừng Postgres hoặc Redis; trả 200 khi phục hồi | I |
| AC-GEN-03 | `alembic upgrade head` từ DB rỗng tạo schema `hana`, `hana_private`, extensions `pg_trgm`, `unaccent`, `btree_gist` | I |
| AC-GEN-09 | Target build V1 duy nhất là Android (flavor dev/staging/prod build được); repo không yêu cầu toolchain iOS | C |
| AC-GEN-10 | Tài liệu canonical nằm trong `repo/docs/` và được version-control cùng source | C |
| AC-GEN-11 | App Android build và chạy được khi **không** có `google-services.json` / FCM credential | C/E |
| AC-GEN-04 | Postgres `SHOW timezone` = `UTC`; container `TZ=UTC` | I |
| AC-GEN-05 | Postgres, Redis, 9Router không publish port ra ngoài trong `compose.prod.yml` (chỉ Caddy 80/443) | C |
| AC-GEN-06 | Flavor `prod`/`staging` từ chối cleartext HTTP | E |
| AC-GEN-07 | `import-linter` contracts pass | C |
| AC-GEN-08 | Tạo owner bằng CLI; không có endpoint đăng ký | I |

## 2. Auth & thiết bị

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-AUTH-01 | Login đúng → access JWT (15 phút) + refresh token; sai → 401 `AUTH_INVALID_CREDENTIALS` | I |
| AC-AUTH-02 | Refresh xoay vòng; dùng lại refresh token cũ → 401 `AUTH_REFRESH_REUSED` và mọi token của device bị thu hồi | I |
| AC-AUTH-03 | Login lần thứ 6 trong 15 phút từ cùng IP → 429 | I |
| AC-AUTH-04 | Thiết bị thứ 4 đăng nhập → 409 `CONFLICT` | I |
| AC-AUTH-05 | Revoke device → refresh token vô hiệu, private session của device bị hủy, `fcm_token` null | I |
| AC-AUTH-06 | Access token không bao giờ ghi xuống disk trên thiết bị (quét storage sau đăng nhập) | E |

## 3. Chat text & turn

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-CHAT-01 | `POST /v1/turns` hợp lệ → 202 ≤ 300 ms (p95, local) và user message persist | I |
| AC-CHAT-02 | Gửi lại cùng `client_id` → trả turn cũ, không tạo message thứ hai | I |
| AC-CHAT-03 | SSE phát đúng thứ tự: `turn.accepted` → `turn.progress(thinking)` → `reply.ready` → `character.cue` → `tts.segment…` → `turn.completed` | I |
| AC-CHAT-04 | Ngắt SSE giữa chừng, reconnect với `Last-Event-ID` → nhận các event còn lại, không trùng `seq` | I |
| AC-CHAT-05 | Stream hết hạn → `GET /v1/turns/{id}` trả trạng thái cuối + assistant message | I |
| AC-CHAT-06 | Turn thứ hai khi turn đầu chưa xong, `supersede=false` → 409 `TURN_IN_PROGRESS`; `supersede=true` → turn đầu `cancelled` (nếu chưa tới `executing_actions`) | I |
| AC-CHAT-07 | Gateway timeout → fallback message `origin=system`, turn `failed(LLM_TIMEOUT, retryable)`, không action nào thực thi | I |
| AC-CHAT-08 | Envelope hỏng → 1 lần `output_repair`; vẫn hỏng và raw không chứa `{` → dùng raw làm reply; ngược lại fallback | I |
| AC-CHAT-09 | Tắt mạng thiết bị, gửi 3 tin → bubble `queued`; bật mạng → gửi đúng thứ tự, không trùng | E |
| AC-CHAT-10 | Assistant message không chứa chuỗi `{{` | U/I |
| AC-CHAT-11 | Prompt gửi gateway không chứa UUID, filename video, asset_id (regex) | I |
| AC-CHAT-12 | Prompt có `<now>` đúng giờ Việt Nam theo FakeClock | I |
| AC-CHAT-13 | Worker bị kill giữa `llm_pending` → sau ≤ 90 s turn `failed(WORKER_UNAVAILABLE)` | I |

## 4. AI protocol & actions

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-AI-01 | Ví dụ AI_PROTOCOL §12.1 → reminder `due_at = 2026-09-16T08:00:00Z`, reply render "15:00 Thứ Tư, 16/09" | I |
| AC-AI-02 | Ví dụ §12.2 → 2 instruction `pending_confirmation`, summary đúng STANDING_INSTRUCTIONS_SPEC §7 | I |
| AC-AI-03 | Ví dụ §12.3 → 1 journal entry, `raw_text` bằng chuỗi con gốc | I |
| AC-AI-04 | Ví dụ §12.4 → `DUE_IN_PAST` → `reply_repair` được gọi; repair lỗi → template có `detail_vi` | I |
| AC-AI-05 | Action type lạ / args sai / ref lạ → rejected, không side effect, không exception | U/I |
| AC-AI-06 | 6 action trong envelope → envelope invalid | U |
| AC-AI-07 | > 3 action phá hủy trong một turn → nhóm đó bị reject | U |
| AC-AI-08 | Hoàn tác trong 30 s đảo ngược đúng cho mọi action có undo (bảng §7.1); sau 30 s → 409 | I |
| AC-AI-09 | `LLM_JSON_MODE=auto` + gateway trả 400 `response_format` → gửi lại không field, lần sau không gửi field | I |
| AC-AI-10 | Tạo reminder trùng (cùng title, cùng `due_local`, trong 10 phút) → không tạo mới | I |
| AC-AI-11 | Mọi call ghi `llm_calls` chỉ metadata (không cột nội dung) | I |
| AC-AI-12 | `special_cue` không có trong catalog mode → cue gửi client = `null` | U |

## 5. Voice

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-VOC-01 | Giữ mic ≥ 150 ms → ghi âm AAC 16 kHz mono; Hana `listening` ≤ 250 ms (p95) | W/E |
| AC-VOC-02 | Giữ < 400 ms / kéo vào vùng hủy → không upload, file bị xóa | W |
| AC-VOC-03 | 60 s → tự dừng và gửi | W |
| AC-VOC-04 | Bản ghi im lặng (< −45 dBFS) → không upload | W |
| AC-VOC-05 | Upload file không phải audio / duration lệch > 2 s → 422 `AUDIO_INVALID` | I |
| AC-VOC-06 | STT trả rỗng hoặc câu trong blocklist → `STT_EMPTY`, không có user message | I |
| AC-VOC-07 | Transcript hợp lệ → `transcript.final` rồi pipeline như text | I |
| AC-VOC-08 | Audio input normal có `expires_at = +24h` và bị cleanup xóa file | I |
| AC-VOC-09 | Nhấn mic khi TTS đang phát → âm thanh dừng ≤ 200 ms, ghi âm bắt đầu sau khi dừng | E |
| AC-VOC-10 | Cuộc gọi đến khi đang ghi → hủy ghi | M |
| AC-VOC-11 | (L) STT tiếng Việt qua 9Router với 20 câu mẫu: WER ≤ 15% | L/M |

## 6. TTS

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-TTS-01 | Toàn bộ bảng VOICE_SPEC §15 của `SpeechNormalizer` pass | U |
| AC-TTS-02 | Segmenter: mọi segment ≤ 220 ký tự; nối lại = input | U |
| AC-TTS-03 | Segment phát theo đúng thứ tự index kể cả khi synthesize xong lệch thứ tự | I |
| AC-TTS-04 | Speech text > 1.200 ký tự → đọc ≤ 1.000 ký tự đầu + câu "Phần còn lại…" | U |
| AC-TTS-05 | TTS lỗi segment 0 → `tts.failed`, turn `completed`, text hiển thị, Hana không vào `talking` | I/W |
| AC-TTS-06 | `speak_replies=never` → không có call TTS dù client gửi `speak=true` | I |
| AC-TTS-07 | Cache TTS normal: cùng segment/voice/speed → không gọi provider lần hai | I |
| AC-TTS-08 | TTS bytes không ghi disk thiết bị (quét thư mục app sau khi phát) | E |
| AC-TTS-09 | Tin proactive/reminder/report không tự đọc; chạm loa → `POST /speak` → phát | E |
| AC-TTS-10 | (L) TTS tiếng Việt qua 9Router: 20 câu mẫu chứa giờ/ngày/số được người dùng đánh giá "tự nhiên, dễ nghe" ≥ 18/20 | L/M |

## 7. Character system & media

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-CHR-01 | Mọi dòng bảng CHARACTER_SYSTEM §8.3 có unit test reducer pass | U |
| AC-CHR-02 | Property test 10.000 event ngẫu nhiên: CHR-01, CHR-03, CHR-04 luôn đúng, không exception | U |
| AC-CHR-03 | Director: fuzz emotion/cue bất kỳ → output luôn hợp lệ; bảng §6.2 pass | U |
| AC-CHR-04 | Không có đường nào để server/LLM gửi asset_id/filename tới engine: `CharacterCue.fromJson` bỏ qua mọi field ngoài schema | U |
| AC-CHR-05 | Mọi CoreState có ≥ 1 asset normal hoặc có `coverage_waiver` được ghi rõ | C |
| AC-CHR-06 | Asset thiếu/hỏng → chọn variant khác → idle → poster; stage không bao giờ đen (widget test mô phỏng lỗi) | W |
| AC-CHR-07 | Thinking min dwell 500 ms: reply đến sau 100 ms vẫn giữ thinking ≥ 500 ms | U |
| AC-CHR-08 | `surprised` + TTS → overlay trước khi nói ≤ 1.200 ms; `happy medium` + TTS → overlay sau khi nói | U |
| AC-CHR-09 | Special cue trong cooldown bị bỏ qua | U |
| AC-CHR-10 | Idle 60 s trong quiet hours → `sleep`; chạm màn hình → `idle` | U |
| AC-CHR-11 | (M) Chuyển state trên thiết bị tầm trung: crossfade không giật, không khung đen, bộ nhớ ổn định sau 30 phút sử dụng | M |
| AC-MED-01 | `verify.py`: mọi file app-ready có đúng 1 stream video H.264 yuv420p, 0 audio, 0 attached pic | C |
| AC-MED-02 | sha256 toàn bộ `assets_source` trước = sau khi chạy pipeline | C |
| AC-MED-03 | File nguồn không có nhãn hoặc `decision≠include` → không có trong output | C |
| AC-MED-04 | Manifest ship không chứa tên file nguồn (vd regex `[A-Z]{4}\d{4}`) | C |
| AC-MED-05 | Mọi `VideoPlayerController` được tạo với `mixWithOthers: true` và `setVolume(0)` trước `play()` | W |
| AC-MED-06 | CI grep: không `setVolume(` với giá trị khác 0 trong `lib/` | C |
| AC-MED-07 | Đang phát nhạc app khác, mở Hana (video chạy, không TTS) → nhạc không bị dừng/giảm | M |
| AC-MED-08 | APK/AAB không chứa asset `p.*` hoặc thư mục `private/` | C |

## 8. Tasks, reminders, notifications

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-REM-01 | Tạo reminder → occurrences materialize 14 ngày; `due_at` đúng TIMEZONE_SPEC §7 | I |
| AC-REM-02 | Client đặt local notification 7 ngày + ack; tới giờ scheduler đánh dấu `fired_local`, không gửi FCM | I/E |
| AC-REM-03 | Occurrence không có ack → FCM data message đúng 1 lần (`_job_id`) | I |
| AC-REM-04 | Tắt mạng thiết bị sau khi đặt nhắc → notification vẫn nổ đúng giờ (±60 s) | E |
| AC-REM-05 | Snooze 10 phút → occurrence mới, nổ sau 10 phút | E |
| AC-REM-06 | Sửa giờ reminder → occurrences tương lai cũ `cancelled`, client nhận sync và thay lịch cục bộ | I/E |
| AC-REM-07 | Scheduler dừng 3 giờ qua giờ nhắc (không ack) → khi chạy lại push kèm "(trễ)"; dừng 7 giờ → `missed`, chỉ inbox | I |
| AC-REM-08 | Hai scheduler song song → mỗi occurrence xử lý đúng 1 lần | I |
| AC-REM-09 | Khi occurrence đến hạn → 1 assistant message `origin=reminder` (idempotent) | I |
| AC-REM-10 | Hoàn thành task có reminder non-recurring → reminder `completed`, occurrences tương lai `cancelled` | I |
| AC-REM-11 | Recurrence monthly ngày 31 → tháng 2 dùng ngày cuối tháng | U |
| AC-REM-12 | `FCM_ENABLED=false`: tạo reminder → local notification nổ đúng giờ (±60 s) kể cả offline; occurrence không ack → `fired_unacked`, inbox `push_state=skipped_unconfigured`; không lỗi, không retry | I/E |
| AC-REM-13 | `FCM_ENABLED=false`: sửa reminder trên server → client nhận thay đổi khi resume hoặc background sync và đặt lại alarm | E |
| AC-NOT-01 | Mọi notification có row inbox trước khi push | I |
| AC-NOT-02 | FCM token invalid → xóa token, không retry vô hạn | I |
| AC-NOT-03 | `notification_preview=generic` → body companion/report là câu chung | I |
| AC-NOT-04 | Quiet hours: không proactive; reminder vẫn nổ | I |
| AC-NOT-05 | `FCM_ENABLED=false`: proactive/report notification được hiển thị bằng local notification sau background sync, không trùng (dedupe `notification_id`) | E |

## 9. Memory & relationship & daily companion

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-MEM-01 | `memory.remember` → memory `source=explicit`, xuất hiện trong prompt turn sau | I |
| AC-MEM-02 | Extraction bỏ op có evidence chỉ là lời Hana; bỏ category `health/finance/sensitive_other` | I |
| AC-MEM-03 | Dedupe trigram: nội dung gần trùng → update, không add | I |
| AC-MEM-04 | Debounce: 5 turn trong 2 phút → 1 lần extraction | I |
| AC-MEM-05 | Retrieval: bộ fixture 50 memory/20 truy vấn → memory kỳ vọng trong top 8 ở ≥ 80% truy vấn | I |
| AC-MEM-06 | Memory `deleted` không bao giờ vào prompt | I |
| AC-MEM-07 | UI Ký ức: xem theo nhóm, nguồn gốc, sửa, ghim, xóa | W/E |
| AC-MEM-08 | Day summary chạy 03:30 cho ngày trước; downtime → chạy bù ≤ 7 ngày | I |
| AC-REL-01 | `first_interaction_local_date`, `active_days_count`, `current_streak_days` đúng qua chuỗi FakeClock nhiều ngày (có biên 17:00Z) | I |
| AC-REL-02 | Milestone 100 ngày được đưa vào context morning brief đúng 1 lần | I |
| AC-COMP-01 | Morning brief 08:00 local tạo đúng 1 message + notification; số reminder/giờ đầu tiên do backend render | I |
| AC-COMP-02 | Evening check-in bị bỏ qua nếu có tin người dùng trong 2 giờ gần nhất | I |
| AC-COMP-03 | Tối đa 3 proactive/ngày local | I |
| AC-COMP-04 | `skip=true` từ LLM → không message | I |
| AC-COMP-05 | Tắt morning brief trong Settings hoặc qua `settings.update` → không chạy ngày sau | I |
| AC-COMP-07 | Owner mới có mặc định: morning 08:00, followup 14:00, evening 21:30, quiet hours 23:00–07:00, journal cutoff 04:00; mỗi giá trị đổi được qua `PATCH /v1/settings` và `routine_schedules.next_run_at` cập nhật tương ứng | I |
| AC-COMP-06 | Proactive message chưa đọc < 30 phút khi mở app → engine phát cue 1 lần | W |

## 10. Work journal & reports

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-JRN-01 | `journal.append` với text không phải chuỗi con → `JOURNAL_TEXT_NOT_IN_MESSAGE`, không entry | I |
| AC-JRN-02 | `raw_text` lưu là đoạn cắt từ tin nhắn gốc (giữ nguyên dấu/khoảng trắng gốc) | I |
| AC-JRN-03 | Tin 03:59 local → ngày hôm trước; 04:00 → hôm nay | I |
| AC-JRN-04 | Cùng nội dung + cùng ngày gửi 2 lần → 1 entry | I |
| AC-JRN-05 | Không có `journal_capture` active: tin kể việc không chứa từ khóa explicit → `journal.append` bị reject `JOURNAL_CAPTURE_NOT_ENABLED`, không entry; tin có "lưu nhật ký" → entry. Có `journal_capture` active → entry không cần từ khóa | I |
| AC-JRN-06 | Sửa entry → revision+1, row revision, items tái tạo, report liên quan `stale` | I |
| AC-JRN-07 | Xóa + khôi phục trong 30 s; sau 30 ngày hard delete | I |
| AC-JRN-08 | `journal_extract` bỏ item có evidence không phải chuỗi con | I |
| AC-RPT-01 | Routine `boundary_day=15` chạy `2026-10-15T02:00:00Z` (09:00 ngày 15/10), period half-open `[2026-09-15, 2026-10-15)`, `period_key=2026-09-15--2026-10-15`, đúng 1 report; UI hiển thị "15/09/2026 – 14/10/2026" | I |
| AC-RPT-02 | Stats khớp fixture tính tay (mọi field §6.4) | I |
| AC-RPT-03 | Bullet không ref / ref lạ bị bỏ; > 50% bị bỏ → retry job | I |
| AC-RPT-04 | Period rỗng → không gọi LLM, markdown template rỗng, message + notification | I |
| AC-RPT-05 | Input > 40.000 ký tự → digest theo tuần rồi final | I |
| AC-RPT-06 | Markdown snapshot khớp template §6.6 | U |
| AC-RPT-07 | Report giao: message `origin=report` + notification + cue `report_ready` | I |
| AC-RPT-08 | Regenerate → version mới `ready`, version cũ `superseded` | I |
| AC-RPT-09 | `report.request current_to_date` → `partial=true`, end = hôm nay | I |
| AC-RPT-10 | Không có routine → `latest_completed` → `NO_REPORT_ROUTINE` | I |
| AC-RPT-11 | Export markdown đúng `text/markdown; charset=utf-8` | I |
| AC-RPT-12 | Scheduler down qua ngày chạy (ngày 15) → khi chạy lại report vẫn tạo cho đúng kỳ đã đóng; không trùng | I |
| AC-RPT-13 | Không ngày nào thuộc hai kỳ: entry ngày 14/10 chỉ nằm trong kỳ `[09-15, 10-15)`; entry ngày 15/10 chỉ nằm trong kỳ `[10-15, 11-15)`; tổng entry của 12 kỳ liên tiếp = tổng entry toàn khoảng | I |
| AC-RPT-14 | Report routine không bao giờ được tạo trước `end_exclusive 00:00` + cutoff (vd trước 04:00 ngày 15) | I |
| AC-RPT-15 | Không có schema/API/tham số nào cho kỳ inclusive/overlap; `routine_runs` exclusion constraint chặn kỳ chồng nhau | I/C |
| AC-RPT-16 | Mọi chuỗi UI/summary/markdown của kỳ tháng dùng dạng "từ ngày 15 … đến hết ngày 14 …" hoặc "15/mm – 14/mm"; nếu có wording "báo cáo ngày 14" thì interval backend vẫn là `[15, 15)` (snapshot test) | U |

## 11. Standing instructions

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-SI-01 | Trace STANDING_INSTRUCTIONS_SPEC §12 end-to-end pass | I |
| AC-SI-02 | Routine từ chat không `active` khi chưa confirm; không có `routine_schedules` | I |
| AC-SI-03 | Confirm trong cùng turn đề xuất → reject | I |
| AC-SI-04 | Pending 24 h → `expired` + inbox (không push) | I |
| AC-SI-05 | Đề xuất `work_report` thứ hai khi đã có active, không `replaces_ref` → `ROUTINE_DUPLICATE` | I |
| AC-SI-06 | Pause qua ngày chạy → không run; resume → `next_run_at` tương lai, không chạy bù | I |
| AC-SI-07 | Summary render đúng cho `boundary_day` ∈ {1, 15, 28, 31}; câu "từ 14 tháng trước đến 14 tháng này" → `boundary_day=15`, summary "từ ngày 15 tháng trước đến hết ngày 14 tháng này" | U/I |
| AC-SI-08 | Summary luôn nêu ngày bắt đầu, kết thúc, ngày chạy kỳ đầu | U |
| AC-SI-09 | Routine không hỗ trợ ("mỗi tuần tổng hợp") → `ROUTINE_UNSUPPORTED`, không row | I |
| AC-SI-10 | Đổi `boundary_day` giữa kỳ → kỳ chuyển tiếp half-open, không hở/chồng | I |
| AC-SI-11 | UI: xác nhận/từ chối/sửa params/tạm dừng/hủy/xem lịch sử chạy | W/E |

## 12. Timezone

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-TZ-01 | Toàn bộ test matrix TIMEZONE_SPEC §12 (T01–T27) pass | U/I/W |
| AC-TZ-02 | CI lint: không `timedelta(hours=7)`, `+07:00`, `datetime.now(`, `datetime.utcnow(`, `date.today(` ngoài module cho phép; không `DateTime.now()` ngoài `core/time/` | C |
| AC-TZ-03 | Mọi cột thời điểm là `timestamptz`; cột ngày nghiệp vụ `date` tên `*_local_date`; cột giờ tường `timestamp` tên `*_local` có cột `tz` (test introspect schema) | I |
| AC-TZ-04 | API: mọi instant kết thúc `Z`; field `*_local` gửi kèm offset → 422 | I |
| AC-TZ-05 | Thiết bị đặt timezone khác → UI vẫn hiển thị giờ Việt Nam, notification nổ đúng instant | E |
| AC-TZ-06 | Đồng hồ thiết bị lệch 10 phút → hiển thị "bây giờ" và lịch notification bù offset | E |

## 13. Private mode

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-PRV-01 | Toàn bộ bộ test ISO-01…ISO-20 (PRIVACY_SPEC §13) pass | I/W/E/C |
| AC-PRV-02 | Private chỉ mở chủ động từ Settings bằng PIN 6 số, hoặc biometric nếu người dùng đã tự bật; không lệnh chat/voice/notification/deep link nào mở được | E |
| AC-PRV-19 | Setup private bắt buộc PIN 6 số; biometric mặc định tắt và chỉ enroll được sau khi nhập đúng PIN | I/E |
| AC-PRV-20 | Mọi màn mở khóa biometric có nút "Dùng PIN"; hủy/lỗi biometric/key bị vô hiệu → luồng PIN mở được private | E |
| AC-PRV-21 | ISO-21…ISO-26 pass (PIN bắt buộc, re-entry 72 giờ, revoke key khi đổi PIN, lockout áp cho cả biometric) | I |
| AC-PRV-03 | App khởi động lại luôn ở normal mode | E |
| AC-PRV-04 | PIN sai 5 lần → 423 `PRIVATE_LOCKED_OUT` 15 phút | I |
| AC-PRV-05 | Session idle 15 phút / absolute 2 giờ → 401 `PRIVATE_SESSION_EXPIRED`, client khóa | I/E |
| AC-PRV-06 | `inactive` → overlay ngay; background ≥ 60 s → khóa khi quay lại | E |
| AC-PRV-07 | Screenshot trong private bị hệ thống chặn; recents hiển thị trống | M |
| AC-PRV-08 | Private text trong DB là ciphertext; AAD sai → giải mã thất bại | I |
| AC-PRV-09 | Không row `hana.*` nào thay đổi do request/job private (ISO-05) | I |
| AC-PRV-10 | Không notification/FCM nào từ private (ISO-19) | I |
| AC-PRV-11 | Private asset cache mã hóa; `prv_rt` rỗng sau khóa và sau kill app | E |
| AC-PRV-12 | Private wipe xóa sạch mọi row private, blob private, key Redis db1, cache thiết bị | I/E |
| AC-PRV-13 | Guard từ khóa chặn trước LLM (FakeChatGateway không nhận call) | I |
| AC-PRV-14 | Yêu cầu reminder/journal trong private → Hana từ chối, không row normal | I |
| AC-PRV-15 | Access log không có dòng `/v1/private/*` | I |
| AC-PRV-16 | `PRIVATE_MODE_ENABLED=false` → Settings không hiện mục; mọi endpoint 404 | I/W |
| AC-PRV-17 | Normal Hana không bao giờ đề xuất private mode (golden prompt test: persona/policy chứa quy tắc; M: 20 prompt dụ dỗ với 9Router thật, 0 lần gợi ý) | I/L |
| AC-PRV-18 | Trước khi bật private ở staging/prod: bằng chứng 9Router không log nội dung request được ghi vào báo cáo môi trường; provider private LLM đã được benchmark và chốt (hiện UNRESOLVED) | M |

## 14. Security & privacy chung

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-SEC-01 | Secret scan repo xanh; `.env*` bị ignore | C |
| AC-SEC-02 | Log redaction: chạy toàn bộ integration suite, grep log không thấy chuỗi nội dung fixture | I |
| AC-SEC-03 | Rate limits ARCHITECTURE §11.2 quy tắc 4 hoạt động | I |
| AC-SEC-04 | Upload file lớn hơn giới hạn → 413/422, không lưu | I |
| AC-SEC-05 | `android:allowBackup="false"`, data extraction rules loại toàn bộ | C |
| AC-SEC-06 | Logout xóa drift DB, cache voice, local notifications | E |
| AC-SEC-07 | Delete-all xóa mọi dữ liệu normal + private của user, đăng xuất mọi device | I |
| AC-SEC-08 | Export zip chỉ chứa dữ liệu normal, hết hạn 24 h | I |
| AC-SEC-09 | `LLM_PROMPT_LOGGING=true` với `APP_ENV≠local` → process từ chối khởi động | I |
| AC-SEC-10 | `GET /v1/media/{id}` của user khác / không token → 404/401 | I |

## 15. Failure modes

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-FAIL-01 | Mỗi dòng F01–F22 (ARCHITECTURE §12) có test hoặc checklist M tương ứng, kết quả khớp cột "Hành vi" | I/M |
| AC-FAIL-02 | Redis flush khi có job queued → scheduler requeue theo DB, không mất report/reminder | I |
| AC-FAIL-03 | 9Router trả 503 liên tục 5 phút → app vẫn dùng được các màn CRUD, chat trả fallback | I/E |
| AC-FAIL-04 | Manifest normal hỏng → app chạy, stage hiển thị fallback, chat hoạt động | W |

## 16. Hiệu năng

| ID | Tiêu chí | Mức |
|---|---|---|
| AC-PERF-01 | Chỉ số ARCHITECTURE §17 đạt ở môi trường local với FakeChatGateway độ trễ 2 s | I/E |
| AC-PERF-02 | VOICE_SPEC §13 đạt với 9Router thật trên mạng Wi-Fi | L/M |
| AC-PERF-03 | Cold start → stage idle ≤ 3 s trên thiết bị tầm trung | M |
| AC-PERF-04 | 30 phút chat liên tục: bộ nhớ app không tăng quá 150 MB so với lúc đầu | M |

## 17. Tiêu chí hoàn thành Phase 1 (tài liệu)

| ID | Tiêu chí | Kết quả kỳ vọng |
|---|---|---|
| AC-P1-01 | 11 file tồn tại trong `docs/`: PRD, ARCHITECTURE, CHARACTER_SYSTEM, AI_PROTOCOL, VOICE_SPEC, MEMORY_SPEC, WORK_JOURNAL_SPEC, STANDING_INSTRUCTIONS_SPEC, TIMEZONE_SPEC, PRIVACY_SPEC, ACCEPTANCE_CRITERIA | có |
| AC-P1-02 | Component boundaries, data flow, state machine, failure modes, invariants, security boundaries, private isolation, media rules, local vs server được chốt | có (ARCHITECTURE §2, §4, §8–§13; CHARACTER_SYSTEM §5, §8; PRIVACY_SPEC) |
| AC-P1-03 | Interface Flutter ↔ FastAPI ↔ 9Router ↔ PostgreSQL ↔ Redis ↔ Character Engine ↔ TTS/STT ↔ scheduler được mô tả | có (ARCHITECTURE §2.2, §6, §10; AI_PROTOCOL §2; VOICE_SPEC §2, §5, §7) |
| AC-P1-04 | Lifecycle chat text, voice, reminder, work journal, memory, monthly report | có |
| AC-P1-05 | Không có code ứng dụng được tạo trong Phase 1 | có |
| AC-P1-06 | Final Decision Patch áp dụng: kỳ half-open 15→15 thống nhất ở mọi tài liệu; Android target V1 / iOS ngoài phạm vi; FCM tùy chọn; mặc định cấu hình được; PIN bắt buộc + biometric tùy chọn; provider STT/TTS/private LLM ghi UNRESOLVED | có (ARCHITECTURE §0.1) |
| AC-P1-07 | Tài liệu được sync sang `repo/docs/` (canonical), bản gốc `Hana/docs/` giữ nguyên | có |
