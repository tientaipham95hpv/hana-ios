# HANA — MEMORY SPEC (Memory, Relationship continuity, Daily companion inputs)

Phiên bản: 1.1 (Phase 1 + Final Decision Patch) · Vị trí canonical: `repo/docs/` · Quyết định chốt: ARCHITECTURE §0.1
Phụ thuộc: `ARCHITECTURE.md` §7, §10; `AI_PROTOCOL.md` §4, §7, §9; `TIMEZONE_SPEC.md` §9; `PRIVACY_SPEC.md` §5–§6.

---

## 1. Mục tiêu

Hana phải *nhớ* như một người bạn đồng hành: biết người dùng là ai, thích gì, đang có chuyện gì dang dở, hôm qua nói gì, quen nhau bao lâu — nhưng:

- không bịa đặt ký ức,
- người dùng xem/sửa/xóa được mọi ký ức,
- ký ức private không bao giờ rò sang normal,
- ký ức là **dữ liệu**, không phải chỉ thị.

---

## 2. Các lớp memory

| Lớp | Bảng | Sinh bởi | Dùng cho | Normal/Private |
|---|---|---|---|---|
| L0 Ngắn hạn | `messages` / `private_messages` | chat | lịch sử trong prompt (≤ 30 tin) | cả hai (tách bảng) |
| L1 Tóm tắt ngày | `conversation_summaries` / `private_summaries` | job `day_summary` | `<recent_days>` | cả hai (tách bảng) |
| L2 Ký ức dài hạn | `memories` / `private_memories` | explicit action, extraction job, UI | `<profile_memories>`, `<relevant_memories>` | cả hai (tách bảng) |
| L3 Trạng thái quan hệ | `relationship_state` | hệ thống + extraction | `<relationship>` | chỉ normal (private đọc read-only) |
| L4 Việc dang dở (followups) | `followups` | extraction job | `<followups>`, proactive | chỉ normal |
| L5 Standing instructions | `standing_instructions` | STANDING_INSTRUCTIONS_SPEC | `<standing_instructions>` | chỉ normal |

---

## 3. Category và độ nhạy cảm

| Category | Ví dụ | Auto-extract normal | Auto-extract private | Cho private đọc (read-only) |
|---|---|---|---|---|
| `profile` | tên, nghề, nơi sống, ngày sinh | ✔ | ✘ (không ghi normal từ private) | ✔ |
| `preference` | thích cà phê đen, ghét hành | ✔ | ✘ | ✔ |
| `people` | Minh là trưởng nhóm; mẹ tên Lan | ✔ | ✘ | ✘ |
| `work` | đang làm dự án X, stack Flutter | ✔ | ✘ | ✘ |
| `routine` | thường chạy bộ 6h sáng | ✔ | ✘ | ✘ |
| `relationship` | kỷ niệm với Hana, biệt danh, cách xưng hô | ✔ | ✘ | ✔ (chỉ biệt danh/xưng hô qua `relationship_state`) |
| `goal` | muốn giảm 5kg trong năm | ✔ | ✘ | ✘ |
| `health` | dị ứng hải sản | **chỉ explicit** | ✘ | ✘ |
| `finance` | lương, nợ | **chỉ explicit** | ✘ | ✘ |
| `sensitive_other` | chính trị, tôn giáo, xu hướng tính dục | **chỉ explicit** | ✘ | ✘ |
| `private_intimate` | (chỉ trong `private_memories`) | ✘ | ✔ | — |
| `private_preference` | (chỉ trong `private_memories`) | ✘ | ✔ | — |

"Explicit" = người dùng nói rõ "nhớ giúp anh…", "em ghi nhớ là…" → action `memory.remember`, hoặc tạo từ UI.

`private_memories.category` ∈ {`private_intimate`, `private_preference`, `profile`, `preference`, `relationship`} — chỉ tồn tại trong schema private, không liên thông.

---

## 4. Data model

### 4.1 `hana.memories`

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK | |
| user_id | uuid | |
| client_id | uuid null | unique (user_id, client_id) — tạo từ UI |
| category | text | §3 (không gồm `private_*`) |
| content | text 1..300 | câu khẳng định ngôi thứ ba, tiếng Việt, vd "Anh tên Tài, làm kỹ sư phần mềm." |
| normalized | text | `lower(unaccent(content))`, sinh ở app |
| importance | smallint 1..5 | 5 = cốt lõi |
| confidence | numeric(3,2) 0..1 | explicit/UI = 1.00 |
| source | text `explicit|extracted|ui|system` | |
| source_message_ids | uuid[] | |
| status | text `active|superseded|deleted` | |
| superseded_by | uuid null | |
| pinned | boolean | người dùng ghim hoặc importance=5 |
| valid_until_local_date | date null | ký ức có hạn (vd "tuần này anh đi Đà Nẵng") |
| last_referenced_at | timestamptz null | cập nhật khi được đưa vào prompt |
| reference_count | int | |
| embedding | vector(N) null | chỉ khi bật semantic (§7.4) |
| created_at, updated_at | timestamptz | |
| deleted_at | timestamptz null | |

Index: GIN `gin_trgm_ops` trên `normalized`; `(user_id, status, category)`; `(user_id, pinned) WHERE status='active'`.

### 4.2 `hana.v_profile_memories` (view cho private đọc)

```sql
SELECT id, user_id, category, content, importance, pinned
FROM hana.memories
WHERE status = 'active' AND category IN ('profile', 'preference');
```

Grant `SELECT` cho `hana_private_rw` **chỉ** trên view này (không trên bảng).

### 4.3 `hana.conversation_summaries`

| id | user_id | local_date date | summary text ≤ 1200 | mood text null (`good|neutral|low`) | message_count int | first_message_id, last_message_id | model | created_at |

Unique `(user_id, local_date)`.

### 4.4 `hana.followups`

| Cột | Kiểu | Ghi chú |
|---|---|---|
| id | uuid PK | |
| user_id | uuid | |
| content | text ≤ 200 | "Hỏi thăm lịch khám răng của anh" |
| about_local_date | date null | ngày sự việc diễn ra |
| check_local_date | date | ngày nên hỏi thăm |
| status | text `open|done|dismissed|expired` | |
| source_message_ids | uuid[] | |
| last_asked_at | timestamptz null | lần cuối proactive message hỏi thăm |
| created_at, updated_at, closed_at | | |

Tự `expired` khi `check_local_date < business_today − 3`.

### 4.5 `hana.relationship_state` (1-1 user)

| Cột | Kiểu | Mặc định / Ghi chú |
|---|---|---|
| user_id | uuid PK | |
| address_user | text | `anh` |
| address_hana | text | `em` |
| user_preferred_name | text null | "anh Tài" |
| first_interaction_local_date | date | ngày tin nhắn đầu tiên |
| last_user_message_at | timestamptz null | |
| last_proactive_at | timestamptz null | |
| active_days_count | int | số ngày local có ≥ 1 tin người dùng |
| current_streak_days | int | chuỗi ngày liên tiếp |
| milestones_celebrated | jsonb | `["days_100"]` |
| tone_notes | text ≤ 500 null | "anh thích đùa, không thích quá sến" — cập nhật bởi extraction (category relationship) hoặc UI |
| updated_at | timestamptz | |

### 4.6 `hana.memory_extraction_cursors`

| user_id PK | last_processed_message_id uuid | last_run_at timestamptz | pending_since timestamptz null |

### 4.7 Private (schema `hana_private`, định nghĩa đầy đủ ở PRIVACY_SPEC §6.2)

`private_memories` có cấu trúc tương tự `memories` nhưng `content_ciphertext bytea`, `content_nonce bytea`, `key_version smallint` thay cho `content`/`normalized`; không có `embedding`. `private_summaries` tương tự `conversation_summaries` với `summary_ciphertext`.

---

## 5. Đường ghi memory

| # | Đường | Khi nào | Kết quả |
|---|---|---|---|
| W1 | Action `memory.remember` | Người dùng yêu cầu rõ | insert `source=explicit`, `confidence=1`, `importance` = 4 mặc định (LLM không chọn importance); dedupe §6.4 |
| W2 | Extraction job | Sau hội thoại (debounce) | add/update/supersede theo §6 |
| W3 | UI | Màn hình Ký ức | CRUD, `source=ui` |
| W4 | Hệ thống | Tin nhắn đầu tiên, milestone | `relationship_state` |
| W5 | Action `memory.forget` | Người dùng yêu cầu quên | status `deleted` ngay (ẩn khỏi prompt), hard delete sau `undo_until` |

Private: W1, W2 (private extraction), W3 (UI trong private), W5 — đều chỉ ghi `hana_private`.

---

## 6. Extraction job

### 6.1 Kích hoạt (debounce)

- Sau mỗi `turn.completed` (normal): `SET memx:pending:{user_id} <now> NX`; enqueue `memory_extract` với `_defer_by = 180 s`, `_job_id = memx:{user_id}:{floor(now/180s)}`.
- Job chạy khi: không có tin người dùng mới trong 180 s **hoặc** ≥ 20 message chưa xử lý (kiểm tra bằng cursor). Nếu có tin mới trong 180 s và < 20 tin → tự defer thêm 180 s (tối đa 3 lần).
- Private: tương tự với `pmemx:` trên Redis db1, queue `hana:private`.

### 6.2 Input

- Message sau `last_processed_message_id` (tối đa 40, cũ → mới), mỗi message có alias `U1`, `A1`… (không UUID).
- Memory hiện có liên quan: top 30 theo trigram với nội dung các message + toàn bộ pinned, dạng `M1…`.
- Followups open (`F1…`).
- `now`, `business_today`.

### 6.3 Output schema (`memory_extract` v1)

```json
{
  "v": 1,
  "ops": [
    { "op": "add", "category": "work", "content": "Anh đang làm dự án app đặt lịch cho phòng khám.", "importance": 3,
      "confidence": 0.8, "evidence": ["U3"], "valid_until_local_date": null },
    { "op": "update", "ref": "M4", "content": "Anh chuyển sang uống trà thay cà phê.", "evidence": ["U7"] },
    { "op": "supersede", "ref": "M2", "content": "Anh đã chuyển nhà ra Đà Nẵng.", "category": "profile", "importance": 4, "evidence": ["U9"] },
    { "op": "followup", "content": "Hỏi thăm buổi phỏng vấn của anh", "about_local_date": "2026-09-17", "check_local_date": "2026-09-17", "evidence": ["U5"] },
    { "op": "resolve_followup", "ref": "F1", "status": "done", "evidence": ["U6"] },
    { "op": "relationship", "field": "tone_notes" | "user_preferred_name", "value": "…", "evidence": ["U2"] }
  ]
}
```

`ops` tối đa 15. Không có op `delete` (chỉ người dùng xóa).

Private output: chỉ `add`, `update`, `supersede` với category private cho phép (§3).

### 6.4 Áp dụng ops (backend, transaction mỗi op)

1. **Evidence bắt buộc**: mọi op phải có `evidence` trỏ tới alias `U*` (tin của người dùng) tồn tại. Chỉ `A*` (lời Hana) → bỏ (Hana không được tự tạo ký ức từ lời mình).
2. **Category policy** §3: category `health|finance|sensitive_other` từ extraction → bỏ. Category ngoài enum → bỏ.
3. **Ngưỡng**: `confidence < 0.6` → bỏ.
4. **Dedupe `add`**: tìm memory active cùng category có `similarity(normalized, new_normalized) ≥ 0.55` (pg_trgm) → chuyển thành `update` memory đó nếu nội dung mới dài hơn/khác, hoặc bỏ nếu gần như trùng (`≥ 0.85`).
5. **`update`**: chỉ memory `source ∈ {extracted}` được sửa nội dung bởi extraction; memory `explicit|ui` → chuyển thành `supersede` chỉ khi có evidence mâu thuẫn rõ, else bỏ.
6. **`supersede`**: memory cũ `status=superseded`, `superseded_by` = mới.
7. **importance** từ extraction bị kẹp 1..4 (5 chỉ do người dùng/ghim).
8. **followup**: `check_local_date` ≥ `business_today` và ≤ `business_today + 60`; trùng nội dung (similarity ≥ 0.6) với followup open → bỏ.
9. **relationship**: chỉ `tone_notes` (≤ 500, ghi đè) và `user_preferred_name` (≤ 50).
10. Cập nhật cursor = message cuối cùng trong input **sau khi** mọi op xử lý xong (kể cả bỏ qua).

Output invalid → retry theo job policy; hết retry → cursor vẫn tiến (tránh kẹt), log `memory_extract_dropped`.

### 6.5 Day summary (`day_summary` v1)

Chạy 03:30 local cho `business_today − 1` nếu ngày đó có ≥ 1 tin người dùng.

```json
{ "v": 1, "summary": "string ≤ 1200", "mood": "good|neutral|low" }
```

Hướng dẫn: tóm tắt chuyện người dùng kể, cảm xúc, việc dang dở; không liệt kê lại reminder/journal chi tiết; ngôi thứ ba ("Anh…").

Private: `private_summary` cùng schema, lưu ciphertext.

---

## 7. Retrieval

### 7.1 Profile (luôn có)

`memories WHERE status='active' AND (pinned OR importance=5 OR category IN ('profile','relationship') AND importance>=4)` → sắp theo `pinned DESC, importance DESC, updated_at DESC` → tối đa 15.

### 7.2 Relevant (theo tin nhắn hiện tại)

```
q = lower(unaccent(user_message))  (cắt 500 ký tự)
candidates = top 40 memories active (không thuộc profile set)
             ORDER BY word_similarity(q, normalized) DESC
             WHERE word_similarity(q, normalized) > 0.15  (hoặc similarity trên từng từ khóa)
             ∪ memories category ∈ intent_categories(q)   (tối đa 10, updated_at DESC)

score = 0.50 * lexical            (word_similarity, 0..1)
      + 0.20 * importance / 5
      + 0.15 * recency              (exp(−Δngày / 30) theo max(updated_at, last_referenced_at))
      + 0.15 * category_boost       (1 nếu category ∈ intent_categories, else 0)

chọn top 8 với score ≥ 0.25
```

`intent_categories` là bảng từ khóa đơn giản (không LLM): chứa "làm", "dự án", "công việc", "sếp" → `work`, `people`; "ăn", "uống", "thích" → `preference`; "mẹ", "bạn", "vợ", "người yêu" → `people`, `relationship`; "sức khỏe", "bệnh", "khám" → `health`; "tiền", "lương" → `finance`. File `domain/memory/intent_keywords.yaml`.

### 7.3 Sau khi chọn

- Cập nhật `last_referenced_at`, `reference_count += 1` cho memory được đưa vào prompt (batch, không chặn turn).
- Memory `valid_until_local_date < business_today` → không chọn; job hằng ngày chuyển `superseded` với lý do hết hạn.

### 7.4 Semantic (tùy chọn)

- Bật khi `EMBEDDING_MODEL` được cấu hình và 9Router hỗ trợ `/embeddings`; cần extension `pgvector`.
- Embed `content` khi insert/update (job `memory_embed`), `lexical = max(word_similarity, cosine_similarity)`.
- Tắt → chỉ lexical. Chất lượng tối thiểu v1 dựa trên lexical + profile set.
- Private **không** dùng embedding.

### 7.5 Private retrieval

- Giải mã tối đa 500 private memory active (cache trong RAM worker theo `user_id`, TTL 5 phút, xóa khi private wipe).
- Chấm điểm bằng `rapidfuzz.fuzz.token_set_ratio` trên chuỗi không dấu (thay `lexical`), cùng công thức §7.2.
- Profile set private: `pinned OR importance=5` tối đa 8.
- Cộng thêm `v_profile_memories` (normal, read-only) tối đa 10 theo AI_PROTOCOL §11.

---

## 8. Relationship continuity

### 8.1 Cập nhật tự động (hệ thống, không LLM)

| Sự kiện | Cập nhật |
|---|---|
| Tin người dùng đầu tiên từ trước tới nay | `first_interaction_local_date = business_today` |
| Mỗi tin người dùng (normal) | `last_user_message_at`; nếu ngày local mới: `active_days_count += 1`, streak: hôm qua có → +1, else = 1 |
| Milestone `days_together ∈ {7, 30, 100, 365, mỗi 365}` | Job 00:20 local (trước mọi giờ morning brief cấu hình được): nếu chưa có trong `milestones_celebrated` → thêm, và cho phép proactive `morning_brief` nhắc nhẹ (context `<milestone>`) |

Private message **không** cập nhật `relationship_state` (tránh lộ nhịp sử dụng private qua dữ liệu normal).

### 8.2 Đưa vào prompt

`<relationship>` gồm: `days_together`, `last_user_message_at` hiển thị giờ Việt Nam, khoảng cách từ lần nói chuyện trước (`gap_hours`), `user_preferred_name`, `tone_notes`, milestone hôm nay nếu có.

### 8.3 Quy tắc hành vi (trong persona)

- `gap_hours ≥ 48`: được hỏi thăm nhẹ nhàng, **không** trách móc hay thể hiện buồn vì bị bỏ rơi.
- Nhắc lại ký ức chỉ khi liên quan; không liệt kê ký ức để "chứng minh" nhớ.
- Không bịa kỷ niệm không có trong context.
- Sai ký ức bị người dùng đính chính → xin lỗi ngắn, phát `memory.forget` hoặc `memory.remember` bản đúng.

---

## 9. Daily companion — dữ liệu đầu vào

Daily companion (ARCHITECTURE §8.5, STANDING_INSTRUCTIONS_SPEC §6.4) dùng:

| Kind | Dữ liệu memory |
|---|---|
| `morning_brief` | profile, `recent_days` (1), followups `check_local_date = today`, milestone, reminders/tasks hôm nay |
| `evening_checkin` | profile, tin nhắn hôm nay (10), followups hôm nay chưa đóng, trạng thái journal hôm nay |
| `followup_checkin` (mặc định 14:00 local, cấu hình được qua `user_settings.followup_checkin_time_local`; chỉ chạy khi có followup `check_local_date = today` chưa hỏi) | followup đó + memory liên quan |

Sau khi proactive message gửi có nhắc followup → followup giữ `open` (người dùng trả lời → extraction `resolve_followup`); cập nhật `followups.last_asked_at` để không hỏi lại trong cùng ngày local.

---

## 10. API

| Method | Path | Mô tả |
|---|---|---|
| GET | `/v1/memories?category=&q=&status=active&cursor=` | danh sách; `q` tìm trigram |
| POST | `/v1/memories` | `{client_id, category, content, importance?, pinned?}` |
| PATCH | `/v1/memories/{id}` | `content`, `category`, `importance`, `pinned`, `valid_until_local_date` |
| DELETE | `/v1/memories/{id}` | hard delete ngay (UI có xác nhận) |
| GET | `/v1/followups?status=open` | |
| PATCH | `/v1/followups/{id}` | `{status}` |
| GET | `/v1/relationship` | relationship_state |
| PATCH | `/v1/relationship` | `address_user`, `address_hana`, `user_preferred_name`, `tone_notes` |
| GET | `/v1/private/memories` | private session |
| POST / PATCH / DELETE | `/v1/private/memories[/{id}]` | private session |

Mọi memory hiển thị trong UI có "Nguồn": `Anh dặn`, `Em tự ghi nhớ từ trò chuyện ngày …`, `Anh thêm`.

---

## 11. Lifecycle tổng

```
[tin nhắn người dùng]
   ├─(explicit)──► memory.remember ──► memories(active, explicit) ──► retrieval
   └─(debounce 180s)──► memory_extract ──► ops ──► add/update/supersede/followup
                                                     │
memories(active) ──UI sửa──► active (source giữ nguyên, updated_at)
memories(active) ──supersede──► superseded (không vào prompt, vẫn xem được trong UI mục "Cũ")
memories(active) ──forget/UI xóa──► deleted ──(undo 30s hết)──► HARD DELETE
memories(active) ──valid_until qua──► superseded(expired)
superseded ──sau 180 ngày──► HARD DELETE (job hằng tuần)
```

---

## 12. Failure modes

| Sự cố | Hành vi |
|---|---|
| Extraction bịa ký ức không có trong tin nhắn | Evidence rule §6.4.1 giảm thiểu; người dùng xóa được; không có tự động kiểm chứng ngữ nghĩa ở v1 |
| Extraction trùng lặp | Dedupe trigram |
| Retrieval chậm (> 1 s) | `context_building` timeout 3 s → context tối thiểu |
| pg_trgm/unaccent chưa cài | Migration fail → deploy dừng |
| Embedding service lỗi | Bỏ semantic cho turn đó, lexical only |
| Người dùng xóa memory trong khi extraction đang chạy có `update` memory đó | `update` trên memory `deleted` → bỏ |
| Private key sai/mất | Private memory không giải mã được → private context không có memory, log `PRIVATE_DECRYPT_FAILED`, không crash |
| Job day_summary lỡ (downtime) | Scheduler chạy bù cho tối đa 7 ngày gần nhất chưa có summary |

---

## 13. Invariants

INV-04, INV-08, INV-15 (ARCHITECTURE §13), cộng:

| ID | Invariant |
|---|---|
| MEM-01 | Không memory nào được tạo từ extraction mà không có evidence là tin của người dùng. |
| MEM-02 | `health`, `finance`, `sensitive_other` chỉ tồn tại với `source ∈ {explicit, ui}`. |
| MEM-03 | Normal retrieval không bao giờ truy vấn `hana_private`. Private retrieval chỉ đọc normal qua `v_profile_memories` và `relationship_state`. |
| MEM-04 | Private activity không cập nhật bất kỳ bảng nào trong schema `hana`. |
| MEM-05 | Memory `deleted` không bao giờ xuất hiện trong prompt. |
| MEM-06 | LLM chat không đặt `importance`; chỉ extraction (kẹp ≤ 4) và người dùng. |

---

## 14. Kiểm thử bắt buộc

- Extraction golden test: hội thoại mẫu → ops kỳ vọng với `FakeChatGateway`; op có evidence `A*` bị bỏ; category `health` bị bỏ.
- Dedupe: "Anh thích cà phê đen" vs "Anh thích uống cà phê đen không đường" → update, không add.
- Retrieval: bộ 50 memory + 20 truy vấn → memory kỳ vọng nằm trong top 8 (≥ 80% case).
- Debounce: 5 turn trong 2 phút → 1 lần chạy extraction.
- Isolation: role `hana_app` `SELECT` bảng `hana_private.private_memories` → permission denied; role `hana_private_rw` `SELECT hana.memories` → denied, `SELECT hana.v_profile_memories` → OK.
- Private turn không làm thay đổi `relationship_state.last_user_message_at`.
- Forget + undo trong 30 s → memory active lại; sau 30 s → không còn row.
