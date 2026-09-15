# HANA — STANDING INSTRUCTIONS SPEC (Chỉ thị thường trực & Routine)

Phiên bản: 1.1 (Phase 1 + Final Decision Patch) · Vị trí canonical: `repo/docs/` · Quyết định chốt: ARCHITECTURE §0.1
Phụ thuộc: `ARCHITECTURE.md` §8.5, §10; `AI_PROTOCOL.md` §7; `TIMEZONE_SPEC.md` §9; `WORK_JOURNAL_SPEC.md` §4, §6; `MEMORY_SPEC.md` §9.

---

## 1. Định nghĩa

**Standing instruction** là một yêu cầu người dùng đặt ra một lần và có hiệu lực lâu dài, cho đến khi người dùng tạm dừng hoặc hủy. Ví dụ:

> "Hàng ngày anh sẽ gửi công việc đã làm, em lưu lại. Mỗi tháng tổng hợp từ ngày 14 tháng trước đến ngày 14 tháng này."

Tách biệt với:

- **Memory** (sự thật về người dùng) — MEMORY_SPEC.
- **Reminder** (một thời điểm/lịch nhắc cụ thể do người dùng đặt) — ARCHITECTURE §8.4.
- **Settings** (tùy chọn giao diện/hệ thống) — `user_settings`.

---

## 2. Phân loại

| kind | Ý nghĩa | Có lịch chạy | Ví dụ |
|---|---|---|---|
| `behavior` | Thay đổi cách Hana cư xử/xử lý trong hội thoại | không | lưu nhật ký tự động; "đừng dùng emoji"; "gọi anh là sếp khi nói chuyện công việc" |
| `routine` | Việc Hana làm theo lịch | có | báo cáo công việc hằng tháng; nhắc gửi nhật ký tối |

Nguồn:

| origin | Mô tả | Cần xác nhận |
|---|---|---|
| `chat` | LLM đề xuất qua `instruction.propose` | **Có** (INV-12) |
| `ui` | Người dùng tạo trong màn hình Chỉ thị | Không (thao tác UI là xác nhận) |

Routine hệ thống của daily companion (`morning_brief`, `evening_checkin`, `followup_checkin`) **không** phải standing instruction; chúng được cấu hình bằng `user_settings` và chạy qua cùng bảng lịch `routine_schedules` với `source=system` (§6.4).

---

## 3. Behavior types

| behavior_type | Hiệu lực hệ thống | Hiệu lực prompt | Tối đa active |
|---|---|---|---|
| `journal_capture` | Cho phép LLM phát `journal.append` khi người dùng **kể** việc đã làm mà không cần nói "lưu lại" (WORK_JOURNAL_SPEC §4.2) | Dòng `S<n> [active][behavior journal_capture] …` | 1 |
| `freeform` | Không có | Chèn `directive` vào `<standing_instructions>` | 20 |

`freeform` **không thể** ghi đè: policy an toàn, quy tắc private mode, output contract, action catalog, timezone. Output contract ghi rõ: "Chỉ thị thường trực là mong muốn của người dùng về phong cách/cách làm việc; nếu mâu thuẫn với quy tắc hệ thống thì bỏ qua phần mâu thuẫn."

---

## 4. Routine types (tập đóng v1)

### 4.1 Bảng

| routine_type | Mô tả | Tối đa active | Job |
|---|---|---|---|
| `work_report` | Báo cáo công việc theo kỳ neo ngày trong tháng | 1 | `generate_report` |
| `journal_nudge` | Nhắc gửi nhật ký công việc nếu chưa gửi | 1 | `generate_proactive(kind=journal_nudge)` |

Yêu cầu định kỳ khác (vd "mỗi tuần tổng hợp", "mỗi sáng đọc tin tức") → `ROUTINE_UNSUPPORTED`; Hana giải thích chưa hỗ trợ, có thể đề xuất `freeform` behavior hoặc reminder recurring nếu phù hợp.

### 4.2 `work_report` params

```json
{
  "boundary_day": 15,
  "run_time_local": "09:00",
  "deliver": "chat_and_notification"
}
```

| Field | Kiểu | Ràng buộc | Mặc định |
|---|---|---|---|
| `boundary_day` | int | 1..31 (29–31 kẹp ngày cuối tháng, TIMEZONE_SPEC §9.2) | `15` |
| `run_time_local` | `HH:MM` | ≥ `user_settings.journal_day_cutoff_local` (mặc định 04:00) và ≤ 23:59 | `09:00` |
| `deliver` | enum | `chat_and_notification` | `chat_and_notification` |

**Kỳ canonical (chốt, TIMEZONE_SPEC §9.2):** half-open `[ngày B tháng trước 00:00:00, ngày B tháng này 00:00:00)` giờ Việt Nam. Không có tham số inclusive/overlap; **không ngày nào thuộc hai kỳ**.

Với workflow của người dùng, **B = 15**:

| Tháng đóng | Interval backend | Diễn đạt UI | Report được tạo |
|---|---|---|---|
| 09/2026 | `[2026-08-15 00:00, 2026-09-15 00:00)` | Từ ngày 15 tháng trước đến hết ngày 14 tháng này (15/08 – 14/09) | 15/09 lúc `run_time_local` (sau khi kỳ đóng), hoặc muộn hơn nếu catch-up |
| 10/2026 | `[2026-09-15 00:00, 2026-10-15 00:00)` | 15/09 – 14/10 | 15/10 |

Wording UI "báo cáo ngày 14" (gọi theo ngày cuối kỳ) được phép trong product copy nhưng **chỉ là wording**; interval backend và ngày chạy không đổi.

LLM phân giải lời người dùng thành `boundary_day` theo bảng TIMEZONE_SPEC §9.2: "từ ngày 14 tháng trước đến ngày 14 tháng này" → ngày 14 là ngày cuối được tính → `boundary_day = 15`. **Summary xác nhận luôn hiển thị rõ "từ ngày 15 tháng trước đến hết ngày 14 tháng này" và khoảng ngày của kỳ đầu tiên** để người dùng thấy chính xác trước khi xác nhận (§7).

### 4.3 `journal_nudge` params

```json
{ "time_local": "21:00", "weekdays": ["MO","TU","WE","TH","FR"], "skip_if_logged": true }
```

| Field | Ràng buộc | Mặc định |
|---|---|---|
| `time_local` | `HH:MM`, không nằm trong quiet hours | `21:00` |
| `weekdays` | tập con MO..SU, ≥ 1 | cả 7 ngày |
| `skip_if_logged` | bool | true |

Không tự tạo khi người dùng chỉ nói "hàng ngày anh sẽ gửi" — Hana CÓ THỂ hỏi "anh có muốn em nhắc lúc tối nếu anh quên không?" và chỉ tạo khi người dùng đồng ý.

---

## 5. Lifecycle

### 5.1 State machine

```
                    (origin=chat)                                (origin=ui)
instruction.propose ───────────► pending_confirmation      POST /v1/instructions ─► active
                                    │  │  │
              confirm (chat/UI) ────┘  │  └──── 24h không phản hồi ──► expired
                         │             └─────── reject ─────────────► rejected
                         ▼
                      active ◄──── resume ──── paused
                         │ ─────── pause ─────► paused
                         │
                         ├── revoke ──────────► revoked        (paused ──revoke──► revoked)
                         └── được thay thế ───► superseded     (khi instruction mới có replaces_ref được confirm)
```

Terminal: `rejected`, `expired`, `revoked`, `superseded`.

### 5.2 Quy tắc chuyển

| Chuyển | Điều kiện | Side effect |
|---|---|---|
| → `pending_confirmation` | validate §5.3 thành công | receipt có nút Xác nhận/Từ chối; `expires_at = now + 24h` |
| `pending` → `active` | `instruction.confirm` (turn **sau** turn đề xuất), hoặc `POST …/confirm` | routine: tạo `routine_schedules`, tính `next_run_at`; `replaces_ref` → cái cũ `superseded` và schedule cũ `enabled=false` |
| `pending` → `rejected` | `instruction.reject` / `POST …/reject` | — |
| `pending` → `expired` | scheduler thấy `expires_at < now` | notification inbox `kind=instruction` "Yêu cầu … chưa được xác nhận nên em chưa áp dụng." (không push) |
| `active` → `paused` | action/API | `routine_schedules.enabled=false` |
| `paused` → `active` | action/API | `enabled=true`, `next_run_at` tính lại từ now, **không** chạy bù kỳ đã lỡ khi paused |
| → `revoked` | action/API | schedule xóa (hard delete), runs giữ lại lịch sử |

**Confirm cùng turn bị cấm:** envelope chứa cả `instruction.propose` và `instruction.confirm` cho cùng instruction là không thể (ref chỉ tồn tại ở turn sau). Validator reject `instruction.confirm` nếu instruction được tạo trong cùng `turn_id`.

**Xác nhận ngầm không hợp lệ:** LLM chỉ được phát `instruction.confirm` khi tin nhắn người dùng thể hiện đồng ý rõ ràng ("ừ", "đúng rồi", "ok em", "xác nhận"). Output contract nêu rõ; backend không kiểm tra ngữ nghĩa.

### 5.3 Validate khi propose

1. `kind=routine` ⇒ `routine_type` ∈ §4.1 và `params` qua JSON Schema tương ứng.
2. `kind=behavior` ⇒ `params.behavior_type` ∈ {`journal_capture`, `freeform`}; `freeform` cần `directive` 1..500 ký tự.
3. Giới hạn số active (§3, §4.1): vượt và không có `replaces_ref` → `ROUTINE_DUPLICATE` (needs_clarification). Nếu đã có `pending_confirmation` cùng loại → cái pending cũ chuyển `superseded` (đề xuất mới thay đề xuất cũ).
4. `replaces_ref` phải trỏ instruction `active|paused` cùng `kind` và cùng `routine_type`/`behavior_type`.
5. `journal_nudge.time_local` trong quiet hours → `needs_clarification` với detail "giờ đó đang trong giờ yên lặng".
6. Mode private → `ACTION_NOT_ALLOWED`.

---

## 6. Thực thi routine (scheduler)

### 6.1 `routine_schedules` được quét

Mỗi vòng scheduler (ARCHITECTURE §10.3):

```sql
SELECT … FROM hana.routine_schedules
WHERE enabled AND next_run_at <= :now
ORDER BY next_run_at
FOR UPDATE SKIP LOCKED
LIMIT 50;
```

Với mỗi row, trong **một transaction**:

1. Tính `period_key` cho lần chạy dự kiến `scheduled_for = next_run_at`:
   - `work_report`: `f"{start_local_date}--{end_exclusive_local_date}"` của kỳ half-open có `run_at = scheduled_for` (TIMEZONE_SPEC §9.2). Scheduler kiểm tra `scheduled_for ≥ local_to_utc(end_exclusive + journal_day_cutoff_local)`; sai → không tạo run, log `ROUTINE_RUN_BEFORE_CLOSE` (lỗi cấu hình).
   - routine hằng ngày: `business_date(scheduled_for).isoformat()`.
2. Áp dụng catch-up policy §6.3 → quyết định `run` hoặc `skip`.
3. `INSERT INTO routine_runs (schedule_id, period_key, scheduled_for, status) VALUES (…, 'queued' | 'skipped') ON CONFLICT (schedule_id, period_key) DO NOTHING`.
4. Nếu insert thành công và `run`: enqueue job `_job_id = f"routine:{schedule_id}:{period_key}"`.
5. Tính `next_run_at` kế tiếp **sau** `scheduled_for` (không phải sau `now`, để catch-up tuần tự) và cập nhật `last_run_at`.
6. Commit. Enqueue thất bại sau commit → `routine_runs.status=queued` sẽ được `requeue_stuck` xử lý (ARCHITECTURE §10.3).

### 6.2 Job

| routine_type | Job | Thành công | Thất bại (hết retry) |
|---|---|---|---|
| `work_report` | `generate_report(run_id)` | `routine_runs.status=succeeded`, `output_ref=work_reports.id` | `failed`; notification "Em chưa tạo được báo cáo kỳ …, em sẽ thử lại khi anh bấm Tạo lại" |
| `journal_nudge` | `generate_proactive(kind=journal_nudge, run_id)` | `succeeded` hoặc `skipped` (đã có log / quiet hours / cap) | `failed` (không thông báo) |
| system `morning_brief` / `evening_checkin` / `followup_checkin` | `generate_proactive(kind, run_id)` | như trên | như trên |

### 6.3 Catch-up policy (khi `now − scheduled_for` lớn)

| Routine | Trễ cho phép | Quá hạn |
|---|---|---|
| `work_report` | không giới hạn | vẫn chạy (tối đa 3 kỳ gần nhất chưa có run; kỳ cũ hơn → `skipped` với `reason=too_old`) |
| `journal_nudge` | 2 giờ | `skipped(late)` |
| `morning_brief` | 2 giờ | `skipped(late)` |
| `evening_checkin` | 1 giờ | `skipped(late)` |
| `followup_checkin` | 3 giờ | `skipped(late)` |

### 6.4 Routine hệ thống (daily companion)

- Khi tạo owner: insert `routine_schedules` với `source=system` cho `morning_brief` (mặc định 08:00), `followup_checkin` (mặc định 14:00), `evening_checkin` (mặc định 21:30); params lấy từ `user_settings` (ARCHITECTURE §7.2). Mọi giờ đều cấu hình được.
- `PATCH /v1/settings` hoặc action `settings.update` thay đổi `*_enabled`/`*_time_local` → service cập nhật `enabled`, `params`, `next_run_at` trong cùng transaction.
- `followup_checkin` khi `enabled` vẫn tự `skipped` nếu không có followup đến hạn.
- Giờ routine hệ thống rơi vào quiet hours (mặc định 23:00–07:00, cấu hình được) → run `skipped(quiet_hours)`; UI Settings cảnh báo khi người dùng chọn giờ như vậy.
- Proactive caps và quiet hours: ARCHITECTURE §8.5.

### 6.5 Maintenance jobs (không thuộc routine_schedules)

`day_summary` (03:30), `extend_recurrences` (00:10), `milestones` (00:20), `cleanup_media` (mỗi 10 phút), `expire_pending_instructions` (mỗi vòng) do scheduler gọi trực tiếp theo giờ local với idempotency key `maint:{job}:{local_date}` trong `job_runs`.

---

## 7. Summary (render cho placeholder và UI)

Backend sinh câu tóm tắt **xác định** từ params (không dùng LLM), hàm `render_instruction_summary(instruction, today)`:

| Loại | Mẫu |
|---|---|
| behavior `journal_capture` | `tự lưu công việc anh gửi vào nhật ký công việc của ngày tương ứng` |
| behavior `freeform` | `ghi nhớ: "{directive}"` |
| `work_report`, B ∈ 2..31 | `tổng hợp báo cáo công việc hằng tháng, kỳ từ ngày {B} tháng trước đến hết ngày {B−1} tháng này, em tạo báo cáo lúc {HH:MM} ngày {B} sau khi kỳ đóng` |
| `work_report`, B = 1 | `tổng hợp báo cáo công việc theo tháng dương lịch (trọn tháng trước), em tạo báo cáo lúc {HH:MM} ngày 1 sau khi tháng đóng` |
| hậu tố khi B ≥ 29 | `(tháng nào không có ngày {B} thì mốc là ngày cuối tháng)` |
| hậu tố cho mọi `work_report` | `; kỳ đầu tiên: {start dd/mm} – {last dd/mm}, báo cáo vào {run dd/mm}` (`last` = `end_exclusive − 1`; kỳ đầu tiên = kỳ có `run_at` đầu tiên > thời điểm xác nhận) |
| `journal_nudge` | `nhắc anh gửi nhật ký công việc lúc {HH:MM} {các ngày} nếu anh chưa gửi` |

Summary không bao giờ chứa cách diễn đạt khiến một ngày có vẻ thuộc hai kỳ (vd "từ 14 đến 14").

Ví dụ render cho params `boundary_day=15`, `run_time_local=09:00`, xác nhận lúc 09:30 ngày 15/09/2026:

> tổng hợp báo cáo công việc hằng tháng, kỳ từ ngày 15 tháng trước đến hết ngày 14 tháng này, em tạo báo cáo lúc 09:00 ngày 15 sau khi kỳ đóng; kỳ đầu tiên: 15/09 – 14/10, báo cáo vào 15/10

---

## 8. Data model (schema `hana`)

### 8.1 `standing_instructions`

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK | |
| user_id | uuid | |
| kind | text `behavior|routine` | |
| behavior_type | text null `journal_capture|freeform` | |
| routine_type | text null `work_report|journal_nudge` | |
| title | text 1..80 | |
| directive | text 1..500 | lời diễn đạt (LLM hoặc người dùng), hiển thị UI |
| params | jsonb | đã validate |
| status | text `pending_confirmation|active|paused|rejected|expired|revoked|superseded` | |
| origin | text `chat|ui` | |
| source_message_id | uuid null | tin người dùng dẫn tới đề xuất |
| proposed_turn_id | uuid null | chặn confirm cùng turn |
| replaces_id | uuid null | |
| superseded_by | uuid null | |
| version | int | tăng khi PATCH params |
| expires_at | timestamptz null | chỉ khi pending |
| confirmed_at, paused_at, revoked_at | timestamptz null | |
| created_at, updated_at | timestamptz | |

Ràng buộc (partial unique index):

- `UNIQUE (user_id, routine_type) WHERE status IN ('active','paused') AND kind='routine'`
- `UNIQUE (user_id) WHERE status IN ('active','paused') AND behavior_type='journal_capture'`

### 8.2 `routine_schedules`

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK | |
| user_id | uuid | |
| source | text `instruction|system` | |
| instruction_id | uuid null FK | unique khi not null |
| routine_type | text `work_report|journal_nudge|morning_brief|evening_checkin|followup_checkin` | |
| params | jsonb | snapshot params tại lần cập nhật cuối |
| enabled | boolean | |
| next_run_at | timestamptz | |
| last_run_at | timestamptz null | |
| created_at, updated_at | timestamptz | |

Unique `(user_id, routine_type) WHERE source='system'`. Index `(enabled, next_run_at)`.

### 8.3 `routine_runs`

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK | |
| schedule_id | uuid FK | |
| period_key | text | §6.1 |
| period_start_local_date | date null | chỉ `work_report`; inclusive |
| period_end_exclusive_local_date | date null | chỉ `work_report`; exclusive |
| scheduled_for | timestamptz | |
| status | text `queued|running|succeeded|failed|skipped` | |
| skip_reason | text null `late|quiet_hours|cap|already_logged|too_old|no_content` | |
| attempt | smallint | |
| output_ref | uuid null | vd `work_reports.id`, `messages.id` |
| error_code | text null | |
| started_at, finished_at | timestamptz null | |
| created_at | timestamptz | |

`UNIQUE (schedule_id, period_key)` (INV-10).

Ràng buộc kỳ báo cáo không chồng (migration bật extension `btree_gist`):

```sql
ALTER TABLE hana.routine_runs
  ADD CONSTRAINT routine_runs_period_half_open
    CHECK ((period_start_local_date IS NULL) = (period_end_exclusive_local_date IS NULL)
           AND (period_start_local_date IS NULL OR period_end_exclusive_local_date > period_start_local_date)),
  ADD CONSTRAINT routine_runs_period_no_overlap
    EXCLUDE USING gist (
      schedule_id WITH =,
      daterange(period_start_local_date, period_end_exclusive_local_date, '[)') WITH &&
    ) WHERE (period_start_local_date IS NOT NULL);
```

---

## 9. API

| Method | Path | Body | Ghi chú |
|---|---|---|---|
| GET | `/v1/instructions?status=` | — | kèm `summary` render, `next_run_at`, run gần nhất |
| POST | `/v1/instructions` | `{client_id, kind, behavior_type?, routine_type?, title, directive, params}` | origin `ui`, active ngay |
| PATCH | `/v1/instructions/{id}` | `{title?, directive?, params?}` | chỉ `active|paused`; `version+1`; tính lại `next_run_at` |
| POST | `/v1/instructions/{id}/confirm` | — | chỉ `pending_confirmation` |
| POST | `/v1/instructions/{id}/reject` | — | |
| POST | `/v1/instructions/{id}/pause` | — | |
| POST | `/v1/instructions/{id}/resume` | — | |
| POST | `/v1/instructions/{id}/revoke` | — | UI xác nhận trước |
| GET | `/v1/instructions/{id}/runs?cursor=` | — | lịch sử chạy |

Không có endpoint private tương ứng (private mode không có standing instructions).

---

## 10. Đưa vào prompt

`<standing_instructions>` (AI_PROTOCOL §4.2) gồm, theo thứ tự:

1. Mọi `pending_confirmation` (đánh dấu rõ `[pending_confirmation]`, LLM không được hành xử như đã active).
2. Mọi `active` behavior.
3. Mọi `active` routine (1 dòng: title + summary rút gọn).
4. `paused` không đưa vào.

Tổng ≤ 3.000 ký tự; vượt → cắt `freeform` cũ nhất (theo `confirmed_at`), luôn giữ `journal_capture` và routine.

---

## 11. Failure modes

| Sự cố | Hành vi |
|---|---|
| LLM đề xuất routine sai tham số (vd boundary_day 0, run_time_local trước cutoff) | schema reject → reply_repair hỏi lại |
| LLM tự confirm trong cùng turn | validator reject |
| LLM đề xuất khi người dùng chỉ hỏi thông tin ("em có thể tổng hợp báo cáo không?") | pending → người dùng từ chối/hết hạn 24h; không có side effect lịch |
| Người dùng xác nhận sau 24h | Instruction `expired`; Hana đề xuất lại |
| Scheduler chạy 2 lần cùng kỳ | `UNIQUE(schedule_id, period_key)` + `_job_id` |
| Scheduler down qua ngày chạy (ngày 15) | catch-up §6.3: report vẫn chạy khi scheduler lên, đúng interval của kỳ đã đóng |
| Người dùng sửa `boundary_day` giữa kỳ | `next_run_at` = run_at đầu tiên theo tham số mới mà > now; report đã tạo giữ nguyên. Kỳ chuyển tiếp (vẫn half-open): start = `end_exclusive_local_date` của report `ready` gần nhất của routine này (nếu có; nếu không thì theo công thức mới), end_exclusive theo công thức mới → có thể ngắn/dài hơn một tháng nhưng không hở, không chồng. `period_key` dùng start/end_exclusive thực tế |
| Paused qua ngày chạy report | Không chạy bù; người dùng dùng "Tạo báo cáo" thủ công |
| `journal_nudge` rơi vào quiet hours do đổi quiet hours sau khi tạo | Run `skipped(quiet_hours)`; UI hiện cảnh báo trên instruction |
| Revoke khi job đang chạy | Job hoàn tất (report vẫn lưu); không tạo run mới |

---

## 12. Ví dụ đầy đủ (trace)

Bối cảnh: `now = 2026-09-15T02:30Z` (09:30 Thứ Ba 15/09 giờ Việt Nam). Chưa có instruction.

**Turn 1** — người dùng: "Hàng ngày anh sẽ gửi công việc đã làm, em lưu lại. Mỗi tháng tổng hợp từ ngày 14 tháng trước đến ngày 14 tháng này."

1. LLM envelope như AI_PROTOCOL §12.2.
2. `standing_instructions`:
   - I1: `kind=behavior, behavior_type=journal_capture, status=pending_confirmation, origin=chat, expires_at=2026-09-16T02:30Z`.
   - I2: `kind=routine, routine_type=work_report, params={boundary_day:15, run_time_local:"09:00", deliver:"chat_and_notification"}, status=pending_confirmation` ("từ 14 tháng trước đến 14 tháng này" → ngày 14 là ngày cuối được tính → `boundary_day=15`).
3. Reply hiển thị:
   > Em hiểu rồi nè. Em sẽ tự lưu công việc anh gửi vào nhật ký công việc của ngày tương ứng, và tổng hợp báo cáo công việc hằng tháng, kỳ từ ngày 15 tháng trước đến hết ngày 14 tháng này, em tạo báo cáo lúc 09:00 ngày 15 sau khi kỳ đóng; kỳ đầu tiên: 15/09 – 14/10, báo cáo vào 15/10. Anh xác nhận giúp em hai mục này nha.
4. Receipts: 2 thẻ, mỗi thẻ nút **Xác nhận** / **Từ chối** / **Sửa** (mở màn hình chỉnh params: ngày mốc, giờ tạo).

**Turn 2** — người dùng: "Đúng rồi em."
→ context `S1 [pending_confirmation]…`, `S2 [pending_confirmation]…` → LLM `instruction.confirm S1`, `instruction.confirm S2`.
→ I1 `active`. I2 `active`, tạo `routine_schedules(source=instruction, routine_type=work_report, next_run_at=2026-10-15T02:00Z)`.

**Hằng ngày** — người dùng gửi "Hôm nay anh …" → `journal.append` (WORK_JOURNAL_SPEC §4). Nhật ký gửi lúc 01:00 ngày 15/10 kể việc ngày 14/10 → `work_local_date=2026-10-14` (cutoff 04:00) → thuộc kỳ `[15/09, 15/10)`.

**2026-10-15T02:00Z** (09:00 ngày 15/10) — scheduler: `period_key = 2026-09-15--2026-10-15`, entries `2026-09-15 ≤ work_local_date < 2026-10-15`, insert `routine_runs`, enqueue `generate_report` → WORK_JOURNAL_SPEC §6. Tiêu đề UI: "Báo cáo công việc 15/09/2026 – 14/10/2026".

Kỳ `[15/08, 15/09)` đã đóng và có `run_at` (09:00 15/09) trước thời điểm xác nhận nên **không** tự chạy bù. Hana có thể nói "Nếu anh cần báo cáo kỳ 15/08 – 14/09, anh bảo em nhé" và dùng `report.request {period:"latest_completed"}` khi được yêu cầu.

---

## 13. Invariants

INV-10, INV-12 (ARCHITECTURE §13), cộng:

| ID | Invariant |
|---|---|
| SI-01 | Không `routine_schedules` nào có `source=instruction` trỏ tới instruction không `active` mà vẫn `enabled=true`. |
| SI-02 | Tối đa 1 `work_report` và 1 `journal_nudge` ở trạng thái `active|paused` mỗi người dùng. |
| SI-03 | `instruction.confirm` không bao giờ áp dụng cho instruction được đề xuất trong cùng turn. |
| SI-04 | Summary hiển thị cho người dùng khi xác nhận luôn nêu rõ ngày bắt đầu, ngày kết thúc và ngày chạy của kỳ đầu tiên. |
| SI-05 | Private mode không đọc, không tạo, không thay đổi standing instruction. |
| SI-06 | Routine `work_report` chỉ dùng kỳ half-open `[start, end_exclusive)` (TIMEZONE_SPEC §9.2); run chỉ được tạo sau khi kỳ đóng; không ngày nào thuộc hai kỳ. |

---

## 14. Kiểm thử bắt buộc

- Trace §12 end-to-end với FakeClock + FakeChatGateway: trạng thái DB sau từng turn, `params.boundary_day = 15`, `next_run_at = 2026-10-15T02:00Z`.
- Pending hết hạn sau 24h → `expired` + notification inbox (không push).
- Confirm cùng turn → rejected.
- Scheduler chạy 2 instance song song trên cùng DB (test concurrency) → đúng 1 `routine_runs` và 1 job.
- Catch-up: routine B=15 active; FakeClock nhảy từ 2026-10-14 tới 2026-12-20 → 3 run cho `2026-09-15--2026-10-15`, `2026-10-15--2026-11-15`, `2026-11-15--2026-12-15`, không tạo trùng, không kỳ nào chồng nhau.
- Pause trước 15/10, resume 17/10 → không có run kỳ `2026-09-15--2026-10-15`.
- Render summary cho B ∈ {1, 15, 28, 31} khớp bảng mẫu; không summary nào chứa mẫu "từ ngày N … đến hết ngày N".
- Params có `run_time_local < journal_day_cutoff_local` → reject.
- Ngày 2026-10-16 sửa `boundary_day` 15 → 20 (report `2026-09-15--2026-10-15` đã `ready`) → kỳ chuyển tiếp `2026-10-15--2026-10-20` (15/10 – 19/10) chạy 20/10; kỳ sau đó `2026-10-20--2026-11-20`.
