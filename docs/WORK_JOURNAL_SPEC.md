# HANA — WORK JOURNAL & MONTHLY REPORT SPEC

Phiên bản: 1.1 (Phase 1 + Final Decision Patch) · Vị trí canonical: `repo/docs/` · Quyết định chốt: ARCHITECTURE §0.1
Phụ thuộc: `ARCHITECTURE.md` §8, §10; `AI_PROTOCOL.md` §6, §7; `STANDING_INSTRUCTIONS_SPEC.md` §3, §4.2, §6; `TIMEZONE_SPEC.md` §9.1–§9.2.

---

## 1. Mục tiêu

Người dùng gửi công việc đã làm mỗi ngày (bằng chat, voice, hoặc form) → Hana lưu **nguyên văn** theo ngày làm việc → định kỳ tổng hợp thành báo cáo chính xác, có trích dẫn, không bịa.

---

## 2. Khái niệm

| Khái niệm | Định nghĩa |
|---|---|
| **Entry** | Một đoạn văn bản người dùng gửi, gắn một `work_local_date`. Nguồn sự thật. |
| **Work day** | Ngày local (Asia/Ho_Chi_Minh) mà công việc thuộc về. Không nhất thiết bằng ngày gửi (cutoff, "hôm qua"). |
| **Item** | Đơn vị công việc do LLM tách từ entry (dữ liệu dẫn xuất, tái tạo được). |
| **Period** | Khoảng ngày local của một report (TIMEZONE_SPEC §9.2). |
| **Report** | Tài liệu tổng hợp một period, có version. |

---

## 3. Kênh ghi nhận

| Kênh | `source` | `date_basis` | Ghi chú |
|---|---|---|---|
| Chat text | `chat` | `default` / `explicit` | qua action `journal.append` |
| Voice | `voice` | `default` / `explicit` | transcript → như chat |
| Form UI (màn hình Nhật ký) | `ui` | `ui` | người dùng chọn ngày (mặc định `journal_default_date`) |

Private mode **không** ghi journal (PRIVACY_SPEC §5.8).

---

## 4. Quy tắc capture từ chat

### 4.1 Explicit capture (luôn bật)

Người dùng yêu cầu rõ: "lưu nhật ký", "ghi lại việc hôm nay", "note giúp anh công việc", "log việc: …" → LLM phát `journal.append` bất kể có standing instruction hay không.

**Guard xác định ở backend:** khi **không** có `journal_capture` active, `journal.append` chỉ được chấp nhận nếu tin nhắn người dùng hiện tại (chuỗi không dấu, lowercase) khớp regex từ khóa explicit trong `domain/journal/explicit_keywords.yaml` (mặc định: `nhat ky`, `luu`, `ghi lai`, `ghi nhan`, `note`, `log`). Không khớp → `needs_clarification(JOURNAL_CAPTURE_NOT_ENABLED)` → reply_repair hỏi "Anh muốn em lưu phần này vào nhật ký công việc không?".

### 4.2 Implicit capture (chỉ khi `journal_capture` active)

Khi instruction behavior `journal_capture` active, LLM phát `journal.append` nếu tin nhắn **kể lại công việc đã làm hoặc đang làm** trong một ngày cụ thể, ví dụ:

- "Nay anh fix xong bug login, review 2 PR."
- "Sáng họp khách, chiều viết tài liệu API."
- "Hôm qua deploy bản 1.2 lên staging."

**Không** capture:

- Kế hoạch tương lai: "Mai anh sẽ làm báo cáo." (có thể gợi ý tạo task)
- Cảm xúc không có nội dung công việc: "Mệt quá em ơi."
- Câu hỏi, trò chuyện đời tư.
- Nội dung đã được capture trong turn trước (LLM thấy trong `<journal_recent>`).

Không chắc → không phát action; CÓ THỂ hỏi "Anh muốn em lưu phần này vào nhật ký không?".

### 4.3 Chọn văn bản (verbatim)

- `args.text` **PHẢI** là chuỗi con liên tục, nguyên văn của tin nhắn người dùng hiện tại (transcript với voice).
- Ưu tiên **một** chuỗi con liên tục bao trọn các câu công việc, chấp nhận lẫn vài từ đời tư.
- Tin nhắn nói về nhiều ngày → nhiều action `journal.append` (tối đa 3), mỗi action chuỗi con + ngày tương ứng.
- Backend kiểm tra: chuẩn hóa cả hai chuỗi (Unicode NFC, gộp khoảng trắng, trim) → `normalized_text in normalized_message`. Sai → `needs_clarification(JOURNAL_TEXT_NOT_IN_MESSAGE)`.
- Backend **lưu chuỗi con cắt từ tin nhắn gốc** (theo vị trí khớp), không lưu chuỗi LLM trả về.

### 4.4 Nguyên văn là bất biến (INV-11)

- `raw_text` chỉ đến từ: chuỗi con tin nhắn người dùng, transcript người dùng, hoặc người dùng tự gõ/sửa trong UI.
- LLM không bao giờ ghi/sửa `raw_text` bằng nội dung do LLM sinh.
- Mọi dữ liệu LLM suy ra (items, report) lưu bảng riêng, xóa/tái tạo được.

### 4.5 Ngày làm việc

| Trường hợp | `work_local_date` |
|---|---|
| Không nói ngày | `journal_default_date(message.created_at)` (cutoff 04:00, TIMEZONE_SPEC §9.1); LLM gửi `null`, `date_basis=default` |
| "hôm qua", "thứ Sáu", "ngày 12" | LLM phân giải theo `<now>` và `<journal_default_date>`, `date_basis=explicit` |
| Ngày tương lai | reject `JOURNAL_DATE_OUT_OF_RANGE` |
| Cũ hơn 60 ngày | reject `JOURNAL_DATE_OUT_OF_RANGE` (UI vẫn cho phép tới 366 ngày) |

### 4.6 Dedupe

Nếu tồn tại entry `active` cùng `user_id`, cùng `work_local_date`, `normalized(raw_text)` bằng nhau → không tạo mới; receipt trỏ entry cũ (`status=executed`).

### 4.7 Xác nhận cho người dùng

Reply dùng placeholder `{{aN.work_date}}` (AI_PROTOCOL §6.2). Receipt: `📒 Nhật ký hôm nay (Thứ Ba, 15/09)` với nút Hoàn tác (30 s) và Mở.

### 4.8 Sửa & xóa từ chat

- "Sửa lại, anh không review 2 PR mà 3 PR" → `journal.amend {ref: E1, text: "<chuỗi con tin mới>", mode: "replace"|"append"}`. `replace` thay toàn bộ `raw_text` bằng chuỗi con mới; `append` nối `\n` + chuỗi con.
- "Xóa cái nhật ký vừa rồi" → `journal.delete {ref}`.
- Mỗi thay đổi tạo revision (§8.2), `revision += 1`.

---

## 5. Tách item (`journal_extract`)

### 5.1 Kích hoạt

Sau khi entry được tạo/sửa: enqueue `journal_extract(entry_id, revision)` với `_job_id = jx:{entry_id}:{revision}`, `_defer_by = 10 s`. `work_journal_entries.extract_status = pending`.

### 5.2 Input / Output

Input: `raw_text`, `work_local_date`, danh sách project đã biết (30 ngày, tối đa 20 tên chuẩn hóa).

Output `journal_extract` v1:

```json
{
  "v": 1,
  "items": [
    {
      "summary": "Sửa lỗi đăng nhập",
      "project": "App đặt lịch",
      "status": "done",
      "duration_minutes": null,
      "evidence": "fix xong bug login"
    }
  ]
}
```

| Field | Ràng buộc |
|---|---|
| `items` | 0..20 |
| `summary` | 1..200 ký tự, tiếng Việt, động từ đầu câu |
| `project` | null hoặc 1..80; ưu tiên dùng đúng tên trong danh sách đã biết |
| `status` | `done|in_progress|blocked|planned` |
| `duration_minutes` | null, hoặc 1..1440 **chỉ khi người dùng nói rõ** thời lượng |
| `evidence` | chuỗi con nguyên văn của `raw_text`, 1..300 |

### 5.3 Validate & lưu

- Item có `evidence` không phải chuỗi con (chuẩn hóa) → bỏ.
- `project_normalized = lower(unaccent(trim(project)))`.
- Nếu `revision` của entry đã thay đổi khi job xong → bỏ kết quả.
- Transaction: xóa items cũ của entry, insert items mới, `extract_status = done`.
- Hết retry → `extract_status = failed`; report vẫn chạy được dựa trên `raw_text` (§6.3 bước 3).

---

## 6. Báo cáo (work report)

### 6.0 Kỳ báo cáo (QUYẾT ĐỊNH CHỐT)

- **Mọi period trong hệ thống là half-open** `[start_local_date, end_exclusive_local_date)` theo Asia/Ho_Chi_Minh (TIMEZONE_SPEC §9.2). Lưu DB, API, `period_key`, stats đều dùng cặp này.
- Báo cáo tháng của người dùng: `boundary_day = 15` → `[ngày 15 tháng trước 00:00:00, ngày 15 tháng này 00:00:00)`.
- **Diễn đạt UI:** "Từ ngày 15 tháng trước đến hết ngày 14 tháng này"; khoảng cụ thể `15/08/2026 – 14/09/2026` (ngày hiển thị cuối = `end_exclusive − 1`).
- **Không ngày nào thuộc hai kỳ.** Membership: `start ≤ work_local_date < end_exclusive`.
- Report routine được tạo **ngày 15** lúc `run_time_local` (mặc định 09:00), tức sau khi kỳ đóng, hoặc muộn hơn khi catch-up.
- Nếu product copy gọi là "báo cáo ngày 14" (theo ngày cuối kỳ), đó **chỉ là wording UI**; interval backend và ngày chạy không đổi.

### 6.1 Nguồn kích hoạt

| Trigger | Period (half-open) | `partial` |
|---|---|---|
| Routine `work_report` (STANDING_INSTRUCTIONS_SPEC §6) | kỳ vừa đóng `[boundary(prev), boundary(this))` | false |
| `report.request {period:"latest_completed"}` | kỳ đã đóng gần nhất theo routine active (`end_exclusive ≤ business_today` lớn nhất) | false |
| `report.request {period:"current_to_date"}` | `[start kỳ hiện hành, business_today + 1)` | true |
| `report.request {period:"custom"}` / UI | `[start, end_exclusive)`, dài 1..366 ngày, `end_exclusive ≤ business_today + 1` | true nếu `end_exclusive > business_today` |
| Regenerate (UI/chat khi `stale`) | period của report cũ | giữ nguyên |

Không có routine active → `latest_completed`/`current_to_date` → `NO_REPORT_ROUTINE`.

### 6.2 Quyết định tạo version

- Routine run: nếu đã có report `ready` (không `stale`) cho cùng period → không tạo mới; `routine_runs.output_ref` = report đó; vẫn gửi message thông báo. Ngược lại tạo version mới.
- Yêu cầu thủ công/regenerate: luôn tạo version mới; version cũ `ready|stale` → `superseded` khi version mới `ready`.

### 6.3 Pipeline `generate_report(report_id)`

```
1. status = generating; nếu có requested_turn_id → XADD job.started
2. entries = work_journal_entries active
            WHERE work_local_date >= start_local_date AND work_local_date < end_exclusive_local_date
            ORDER BY work_local_date, created_at            -- KHÔNG dùng BETWEEN
3. entry nào extract_status ∈ {pending, failed} → chạy journal_extract đồng bộ (timeout 60 s mỗi entry, tối đa 20 entry; quá → dùng raw_text không item)
4. stats (xác định, backend tính, §6.4)
5. entries rỗng → content = template rỗng (§6.6), status ready, bỏ LLM, sang bước 9
6. Gán ref E1..En theo thứ tự bước 2
7. Tổng ký tự input > 40.000 → digest theo tuần (Thứ Hai–Chủ Nhật, cắt theo period):
      mỗi tuần 1 call report_digest (§6.5) → digest bullets có refs
   ngược lại → đưa thẳng entries
8. report_final (§6.5) → validate (§6.5.3)
9. render markdown (§6.6); lưu content_markdown, content_json, stats, source_entry_ids, source_hash
10. status = ready, generated_at = now
11. deliver (§6.7)
```

Lỗi ở bước 7–8 → retry job (ARCHITECTURE §10.2); hết retry → `failed` + notification.

### 6.4 Stats (INV-13 — không do LLM)

```json
{
  "period_start_local_date": "2026-08-15",
  "period_end_exclusive_local_date": "2026-09-15",
  "period_last_local_date": "2026-09-14",
  "calendar_days": 31,
  "days_with_entries": 22,
  "entry_count": 27,
  "item_count": 46,
  "items_by_status": {"done": 40, "in_progress": 5, "blocked": 1, "planned": 0},
  "projects": [{"name": "App đặt lịch", "item_count": 25}, {"name": "Website", "item_count": 12}],
  "total_duration_minutes": 5190,
  "duration_coverage_items": 18,
  "days_without_entries": ["2026-08-16", "2026-08-17"],
  "items_unavailable_entries": 0
}
```

- `projects`: nhóm theo `project_normalized`, hiển thị tên xuất hiện nhiều nhất; item không project → nhóm `Khác` (không liệt kê trong top nếu rỗng).
- `total_duration_minutes`: tổng các item có `duration_minutes`; hiển thị kèm "(ghi nhận cho {duration_coverage_items}/{item_count} mục)". Null nếu 0 item có thời lượng.
- `days_without_entries`: mọi ngày lịch `d` với `start ≤ d < end_exclusive` không có entry — **chỉ liệt kê, không đánh giá** (hệ thống không giả định ngày làm việc/ngày nghỉ).
- `calendar_days = end_exclusive − start` (số ngày); `period_last_local_date = end_exclusive − 1` chỉ phục vụ hiển thị.

### 6.5 LLM schemas

#### 6.5.1 `report_digest` v1 (input: entries của 1 tuần)

```json
{ "v": 1, "week_label": "11/08–17/08",
  "bullets": [ { "text": "≤ 300", "project": "string|null", "kind": "highlight|progress|issue|next", "refs": ["E3","E5"] } ] }
```

Tối đa 15 bullet/tuần.

#### 6.5.2 `report_final` v1

```json
{
  "v": 1,
  "overview": "string ≤ 800",
  "highlights": [ { "text": "≤ 300", "refs": ["E1"] } ],
  "by_project": [ { "project": "≤ 80", "bullets": [ { "text": "≤ 300", "refs": ["E2","E9"] } ] } ],
  "issues": [ { "text": "≤ 300", "refs": ["E7"] } ],
  "next_steps": [ { "text": "≤ 300", "refs": ["E20"] } ]
}
```

Giới hạn: `highlights` ≤ 10, `by_project` ≤ 10 (mỗi project ≤ 8 bullet), `issues` ≤ 8, `next_steps` ≤ 8.

Prompt yêu cầu: tiếng Việt, ngôi thứ nhất số ít của người dùng lược chủ ngữ (văn phong báo cáo), **không nêu con số thống kê** (số ngày, số mục, tổng giờ — hệ thống tự hiển thị), không thêm việc không có trong entries, mỗi bullet phải có refs.

#### 6.5.3 Validate

1. Schema pydantic; sai → output_repair 1 lần → sai → lỗi job.
2. Mỗi bullet: `refs` rỗng hoặc chứa ref không tồn tại → **bỏ bullet** (đếm `dropped_bullets`).
3. `dropped_bullets / total_bullets > 0.5` → coi là lỗi, retry job.
4. `overview` rỗng → template: "Kỳ này anh ghi nhận công việc ở {days_with_entries} ngày." (số từ stats).
5. Lọc `overview` và bullet chứa chữ số dạng thống kê (`\b\d+\s*(ngày|mục|giờ|task|việc)\b`) → giữ nguyên nhưng log `report_number_literal` (QA; không chặn vì có thể là "bản 1.2", "2 PR").

### 6.6 Markdown template (render xác định)

```markdown
# Báo cáo công việc {dd/mm/yyyy start} – {dd/mm/yyyy last}
_Kỳ: từ ngày {dd/mm/yyyy start} đến hết ngày {dd/mm/yyyy last}_
_{"Bản tạm tính đến hôm nay · " nếu partial}Tạo lúc {HH:MM dd/mm/yyyy} (giờ Việt Nam) · Phiên bản {version}_

## Tổng quan
{overview}

## Số liệu
- Số ngày có nhật ký: {days_with_entries}/{calendar_days}
- Số mục nhật ký: {entry_count}
- Công việc: {done} hoàn thành · {in_progress} đang làm · {blocked} vướng mắc{ · {planned} dự kiến nếu > 0}
- Tổng thời gian ghi nhận: {h} giờ {m} phút (cho {duration_coverage_items}/{item_count} mục)   ← bỏ dòng nếu null

## Kết quả nổi bật
- {text} _({dd/mm}, {dd/mm})_

## Theo dự án
### {project}
- {text} _({dd/mm})_

## Vướng mắc
- …

## Việc tiếp theo
- …

## Ngày chưa có nhật ký
{dd/mm, dd/mm, …}   ← bỏ mục nếu rỗng
```

- Refs `E<n>` → danh sách ngày `dd/mm` duy nhất, tăng dần. `content_json` giữ ánh xạ `entry_id` để app deep-link.
- Section không có bullet → bỏ section.
- Period rỗng:

```markdown
# Báo cáo công việc {start} – {last}
_Kỳ: từ ngày {start} đến hết ngày {last}_
_Tạo lúc …_

Kỳ này chưa có nhật ký công việc nào.
```

### 6.7 Giao báo cáo

1. Insert `messages(role=assistant, origin=report, related_entity={type:"work_report", id})`, text template:
   `"Báo cáo công việc kỳ {start dd/mm} – {last dd/mm} xong rồi nè {u}. {câu đầu tiên của overview, ≤ 200 ký tự}"` (period rỗng: `"Kỳ {…} chưa có nhật ký công việc nào nên báo cáo trống {u} nha."`).
2. `character_cue` = Director `report_ready`.
3. `notifications(kind=report)` + push (body `generic`: "Báo cáo công việc đã sẵn sàng").
4. Nếu yêu cầu từ turn: client đang ở `working` nhận `JobFinished` khi `GET /v1/reports/{id}` trả `ready|failed` (poll 3 s, tối đa 5 phút).
5. UI chat hiển thị thẻ report (tiêu đề, số liệu, nút Mở/Chia sẻ).

### 6.8 Stale & regenerate

- Khi entry có `work_local_date` thuộc period (`start ≤ d < end_exclusive`; khi đổi ngày thì xét cả ngày cũ và ngày mới) của report `ready` được tạo/sửa (text hoặc ngày)/xóa → report `stale`, `stale_since = now` (cùng transaction với thay đổi entry).
- Tối đa 1 notification inbox (không push) mỗi report mỗi ngày local: "Nhật ký kỳ {…} vừa thay đổi. Anh muốn em tạo lại báo cáo không?" với nút Tạo lại.
- Report `stale` vẫn xem được, có banner "Có thay đổi sau khi tạo".
- `source_hash = sha256(sorted(entry_id:revision))` dùng để kiểm tra lại khi mở report (phòng trường hợp bỏ sót trigger).

### 6.9 Export

`GET /v1/reports/{id}/export?format=markdown` → `text/markdown; charset=utf-8`. Client mở share sheet / copy. (PDF: ngoài phạm vi v1.)

---

## 7. Lifecycle

### 7.1 Entry

```
[chat/voice/UI] ──validate──► active(revision=1, extract=pending) ──journal_extract──► extract=done|failed
active ──amend/PATCH──► active(revision+1, extract=pending) [+ revision row] [+ report stale]
active ──delete──► deleted (ẩn, undo 30 s) [+ report stale]
deleted ──undo──► active
deleted ──30 ngày──► HARD DELETE (entry + revisions + items)
```

### 7.2 Report

```
pending ──worker──► generating ──ok──► ready ──entry thay đổi──► stale
                        │                 │                       │
                        └──hết retry──► failed      version mới ready ──► superseded
failed ──regenerate──► (version mới) pending
```

---

## 8. Data model (schema `hana`)

### 8.1 `work_journal_entries`

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK | |
| user_id | uuid | |
| client_id | uuid null | unique (user_id, client_id) cho UI |
| work_local_date | date | |
| raw_text | text 1..4000 | nguyên văn (INV-11) |
| source | text `chat|voice|ui` | |
| date_basis | text `default|explicit|ui` | |
| source_message_id | uuid null | |
| action_execution_id | uuid null | |
| revision | int | bắt đầu 1 |
| extract_status | text `pending|done|failed` | |
| status | text `active|deleted` | |
| created_at, updated_at | timestamptz | |
| deleted_at | timestamptz null | |

Index `(user_id, work_local_date) WHERE status='active'`.

### 8.2 `work_journal_entry_revisions`

| id | entry_id | revision | raw_text | work_local_date | changed_by `user|hana` | source_message_id null | created_at |

Unique `(entry_id, revision)`. Revision 1 được ghi khi tạo entry.

### 8.3 `work_journal_items`

| id | entry_id | entry_revision | idx smallint | summary | project null | project_normalized null | status | duration_minutes null | evidence | created_at |

### 8.4 `work_reports`

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK | |
| user_id | uuid | |
| instruction_id | uuid null | |
| routine_run_id | uuid null | |
| period_start_local_date | date | inclusive (đầu kỳ, 00:00:00 giờ Việt Nam) |
| period_end_exclusive_local_date | date | **exclusive** (00:00:00 ngày này không thuộc kỳ); `CHECK (period_end_exclusive_local_date > period_start_local_date)` |
| boundary_day | smallint null | từ routine lúc tạo (null với custom) |
| partial | boolean | |
| version | int | |
| status | text `pending|generating|ready|failed|stale|superseded` | |
| trigger | text `routine|chat|ui` | |
| requested_turn_id | uuid null | |
| content_markdown | text null | |
| content_json | jsonb null | output LLM đã validate + ánh xạ ref→entry_id |
| stats | jsonb null | §6.4 |
| source_entry_ids | uuid[] | |
| source_hash | bytea null | |
| dropped_bullets | int | |
| model | text null | |
| error_code | text null | |
| generated_at, stale_since | timestamptz null | |
| created_at, updated_at | timestamptz | |

Unique `(user_id, period_start_local_date, period_end_exclusive_local_date, version)`.

Không có cột ngày cuối inclusive; API trả thêm field dẫn xuất `period_last_local_date` chỉ để hiển thị.

Ràng buộc không chồng của các kỳ routine được enforce ở `hana.routine_runs` (một row cho mỗi kỳ, STANDING_INSTRUCTIONS_SPEC §8.3) bằng exclusion constraint `daterange(start, end_exclusive, '[)')`. `work_reports` có thể có nhiều version cho cùng một kỳ; report thủ công/custom/partial được phép có khoảng tùy ý nhưng vẫn luôn half-open.

---

## 9. API

| Method | Path | Body / Query | Response |
|---|---|---|---|
| GET | `/v1/journal/days` | `from_local_date`, `to_local_date` (≤ 92 ngày) | `[{local_date, entry_count, item_count}]` |
| GET | `/v1/journal/days/{local_date}` | — | `{local_date, entries: [Entry + items]}` |
| POST | `/v1/journal/entries` | `{client_id, work_local_date, raw_text}` | 201 Entry |
| PATCH | `/v1/journal/entries/{id}` | `{raw_text?, work_local_date?}` | Entry (revision+1) |
| DELETE | `/v1/journal/entries/{id}` | — | 200 `{undo_until}` |
| POST | `/v1/journal/entries/{id}/restore` | — | Entry (trước `undo_until`) |
| GET | `/v1/journal/entries/{id}/revisions` | — | Revision[] |
| GET | `/v1/reports` | `cursor`, `limit` | `[{id, period…, version, status, partial, generated_at, stats_brief}]` |
| GET | `/v1/reports/{id}` | — | report đầy đủ |
| POST | `/v1/reports/generate` | `{client_id, period, start_local_date?, end_local_date_exclusive?, regenerate_report_id?}` | 202 `{report_id}` |
| GET | `/v1/reports/{id}/export` | `format=markdown` | text/markdown |

---

## 10. Failure modes

| Sự cố | Hành vi |
|---|---|
| LLM không capture dù người dùng kể việc | Người dùng nói "lưu lại" (explicit) hoặc thêm qua UI; không tự phát hiện |
| LLM capture nhầm chuyện đời tư | Người dùng hoàn tác 30 s / xóa; không vào report nếu xóa |
| LLM trả `text` không phải chuỗi con | `JOURNAL_TEXT_NOT_IN_MESSAGE` → hỏi lại |
| Gửi trùng nội dung | Dedupe §4.6 |
| Gửi sau nửa đêm | Cutoff 04:00 |
| journal_extract lỗi | Report dùng raw_text; stats `items_unavailable_entries` |
| Period có > 400 entry | Digest theo tuần; mỗi entry cắt 1.500 ký tự trong input LLM (raw_text lưu đủ) |
| LLM bịa bullet | Bullet không ref hợp lệ bị bỏ; ref hợp lệ nhưng nội dung sai lệch — không tự phát hiện ở v1; mọi bullet có ngày để người dùng đối chiếu |
| Report lỗi hết retry | `failed` + notification + nút Tạo lại |
| Entry sửa sau khi report tạo | `stale` §6.8 |
| Routine chạy khi report thủ công đã có | §6.2 |

---

## 11. Invariants

INV-11, INV-13 (ARCHITECTURE §13), cộng:

| ID | Invariant |
|---|---|
| WJ-01 | Mọi `raw_text` tạo từ chat/voice là chuỗi con của tin nhắn người dùng tương ứng. |
| WJ-02 | Report chỉ dùng entry `active` có `period_start_local_date ≤ work_local_date < period_end_exclusive_local_date`. |
| WJ-06 | Kỳ routine liên tiếp của cùng instruction không chồng, không hở; không ngày nào thuộc hai kỳ routine. |
| WJ-03 | Stats trong report bằng kết quả tính lại từ `source_entry_ids` tại thời điểm tạo. |
| WJ-04 | Mọi bullet trong `content_json` có ≥ 1 `entry_id` thuộc `source_entry_ids`. |
| WJ-05 | Private mode không có đường ghi/đọc journal hay report. |

---

## 12. Kiểm thử bắt buộc

- Capture golden: §4.2 ví dụ capture/không capture với FakeChatGateway (kiểm tra validator, không kiểm tra chất lượng LLM).
- Substring: LLM trả text đã "chỉnh câu" → reject; text khác khoảng trắng → chấp nhận, lưu theo bản gốc.
- Cutoff: tin 03:30 local → ngày hôm trước; 04:00 → hôm nay.
- Dedupe: gửi cùng nội dung 2 lần → 1 entry.
- Report B=15, kỳ `2026-08-15--2026-09-15`: entry ngày 15/08 và 14/09 có trong kỳ; entry ngày 15/09 **không** (thuộc kỳ `2026-09-15--2026-10-15`); entry ngày 14/08 không.
- Tin gửi 01:00 ngày 15/09 kể việc hôm trước → `work_local_date=2026-09-14` → nằm trong kỳ `08-15--09-15`; report chạy 09:00 15/09 có entry này.
- Không trùng lặp: tổng `entry_count` của 12 kỳ routine liên tiếp = số entry trong toàn khoảng (không entry nào bị đếm hai lần).
- Tiêu đề/UI: kỳ `2026-08-15--2026-09-15` hiển thị "15/08/2026 – 14/09/2026" và "từ ngày 15/08/2026 đến hết ngày 14/09/2026".
- Insert `routine_runs` thứ hai có khoảng chồng (cùng schedule) → vi phạm exclusion constraint.
- Stats deterministic: fixture 27 entry → đúng từng số §6.4.
- Bullet không ref / ref lạ bị bỏ; > 50% bị bỏ → retry.
- Period rỗng → không gọi LLM, markdown template rỗng.
- Stale: sửa entry trong period sau khi report ready → `stale`, 1 notification/ngày.
- Digest: fixture 60.000 ký tự → gọi `report_digest` theo tuần rồi `report_final`.
- Markdown render snapshot test.
