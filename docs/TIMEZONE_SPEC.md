# HANA — TIMEZONE SPEC

Phiên bản: 1.1 (Phase 1 + Final Decision Patch) · Vị trí canonical: `repo/docs/` · Quyết định chốt: ARCHITECTURE §0.1
Phụ thuộc: `ARCHITECTURE.md` §6.1, §7.1, INV-01, INV-19, INV-20.

---

## 1. Quy tắc chốt

| # | Quy tắc |
|---|---|
| TZ-1 | **Business timezone = `Asia/Ho_Chi_Minh`**, là hằng số trong code, không cấu hình theo môi trường, không theo timezone thiết bị. |
| TZ-2 | **Mọi thời điểm (instant) lưu bền là UTC**: Postgres `timestamptz`, session `timezone='UTC'`; API xuất ISO-8601 có `Z`. |
| TZ-3 | **Mọi phép tính nghiệp vụ** (hôm nay/hôm qua, ngày journal, kỳ report, giờ nhắc, recurrence, quiet hours, giờ proactive, số ngày quen nhau) thực hiện trong Asia/Ho_Chi_Minh bằng tz database (`zoneinfo`), **không** cộng trừ cố định 7 giờ. |
| TZ-4 | Ngày nghiệp vụ lưu kiểu `date` (`*_local_date`). Giờ tường lưu `timestamp without time zone` (`*_local`) + cột `tz`. |
| TZ-5 | LLM chỉ nhận và trả giờ tường Việt Nam (`YYYY-MM-DDTHH:MM`), không bao giờ UTC. |
| TZ-6 | Container, OS server, Postgres, Redis chạy `TZ=UTC`. Code không đọc timezone hệ điều hành. |
| TZ-7 | "Bây giờ" luôn lấy từ `Clock` inject (backend) hoặc `BusinessClock` (Flutter, đã hiệu chỉnh offset server). |
| TZ-8 | UI hiển thị giờ Việt Nam bất kể timezone thiết bị. |

Việt Nam hiện không có DST, nhưng code **vẫn** phải dùng API tz-aware (fold/gap-safe) để đúng về mặt tổng quát và đúng cho dữ liệu lịch sử.

---

## 2. Định nghĩa

| Thuật ngữ | Kiểu Python | Kiểu Dart | Ví dụ |
|---|---|---|---|
| Instant (UTC) | `datetime` aware, `tzinfo=UTC` | `DateTime` isUtc | `2026-09-15T02:30:00Z` |
| Business datetime | `datetime` aware, `tzinfo=BUSINESS_TZ` | `tz.TZDateTime(vn, …)` | `2026-09-15T09:30+07:00` |
| Local wall time | `datetime` naive (chỉ ở biên API/DB/LLM) | `String` `YYYY-MM-DDTHH:MM` | `2026-09-15T09:30` |
| Local date | `date` | `String` `YYYY-MM-DD` hoặc class `LocalDate` | `2026-09-15` |
| Local time of day | `time` | `String` `HH:MM` | `23:00` |

Datetime naive **chỉ** được tồn tại ở: parse input LLM/API, cột DB `*_local`, và ngay trước khi gọi `local_to_utc`. Mọi chỗ khác dùng aware.

---

## 3. Thư viện và dữ liệu tz

| Tầng | Thư viện | Ghi chú |
|---|---|---|
| Backend | `zoneinfo` (stdlib) + package `tzdata` pin trong `pyproject.toml` | Không dùng `pytz` |
| Flutter | `timezone` (`package:timezone/data/latest_10y.dart`) + `flutter_local_notifications` `zonedSchedule` | Khởi tạo trong `bootstrap.dart` |
| Postgres | `timestamptz`; không dùng `AT TIME ZONE` trong query ứng dụng (§5.3) | |

`app/core/tz.py`:

```python
BUSINESS_TZ_NAME = "Asia/Ho_Chi_Minh"
BUSINESS_TZ = ZoneInfo(BUSINESS_TZ_NAME)
```

Khi khởi động, app kiểm tra `BUSINESS_TZ.utcoffset(datetime(2026,1,1)) == timedelta(hours=7)` (sanity check dữ liệu tzdata), sai → không khởi động.

Lint CI (grep) cấm ngoài `core/tz.py` và test: `timedelta(hours=7)`, `"+07:00"`, `UTC+7`, `datetime.now(`, `datetime.utcnow(`, `date.today(`, `time.time(` trong code nghiệp vụ. Flutter cấm `DateTime.now()` ngoài `core/time/`.

---

## 4. Backend helper API (`app/core/tz.py`)

| Hàm | Chữ ký | Hành vi |
|---|---|---|
| `now_utc` | `(clock: Clock) -> datetime` | aware UTC |
| `to_business` | `(instant: datetime) -> datetime` | ném lỗi nếu naive |
| `business_now` | `(clock) -> datetime` | |
| `business_today` | `(clock) -> date` | |
| `local_to_utc` | `(wall: datetime, tz_name: str = BUSINESS_TZ_NAME) -> datetime` | ném lỗi nếu wall aware; gắn tz với `fold=0`; nếu thời điểm rơi vào gap (không tồn tại) → dịch lên sau gap; chuyển UTC |
| `utc_to_local_wall` | `(instant, tz_name=...) -> datetime (naive)` | |
| `local_day_bounds_utc` | `(d: date) -> tuple[datetime, datetime]` | `[d 00:00 local, d+1 00:00 local)` dạng UTC |
| `local_range_bounds_utc` | `(start: date, end_exclusive: date) -> tuple[datetime, datetime]` | |
| `parse_local_wall` | `(s: str) -> datetime` | chỉ nhận `YYYY-MM-DDTHH:MM` (regex chặt), giây = 0 |
| `parse_local_date` | `(s: str) -> date` | `YYYY-MM-DD` |
| `in_time_window` | `(t: time, start: time, end: time) -> bool` | hỗ trợ cửa sổ qua nửa đêm (§9.3) |
| `clamp_day` | `(year, month, day) -> date` | ngày > số ngày của tháng → ngày cuối tháng |
| `add_months` | `(d: date, n: int, day: int) -> date` | dùng `clamp_day` |
| `weekday_vi` | `(d: date) -> str` | `Thứ Hai`…`Thứ Bảy`, `Chủ Nhật` |
| `format_display_when` | `(wall: datetime, today: date) -> str` | `15:00 Thứ Tư, 16/09` (khác năm: `…, 16/09/2027`) |
| `format_display_date` | `(d: date, today: date) -> str` | `hôm nay (Thứ Ba, 15/09)`, `hôm qua (…)`, `ngày mai (…)`, hoặc `Thứ Sáu, 11/09` |
| `format_speech_when`, `format_speech_date` | | theo VOICE_SPEC §6.4–§6.5 |
| `format_prompt_now` | `(clock) -> str` | `2026-09-15T09:30 Thứ Ba (giờ Việt Nam)` |

---

## 5. Database

### 5.1 Cấu hình

- `postgresql.conf`: `timezone = 'UTC'`, `log_timezone = 'UTC'`.
- SQLAlchemy `connect` event: `SET TIME ZONE 'UTC'`.
- Test khởi động (`readyz` lần đầu): `SHOW timezone` phải là `UTC`.

### 5.2 Kiểu cột

| Mục đích | Kiểu | Tên | Ví dụ |
|---|---|---|---|
| Thời điểm xảy ra | `timestamptz` | `*_at` | `created_at`, `due_at`, `generated_at` |
| Ngày nghiệp vụ | `date` | `*_local_date` | `work_local_date`, `period_start_local_date` |
| Giờ tường theo lịch người dùng | `timestamp` | `*_local` | `first_due_local`, `occurrence_local` |
| Giờ trong ngày cấu hình | `time` | `*_time_local` / `*_local` | `quiet_hours_start_local` |
| Timezone của giờ tường | `text` | `tz` | `'Asia/Ho_Chi_Minh'` |

Ràng buộc `CHECK (tz = 'Asia/Ho_Chi_Minh')` ở v1 cho mọi cột `tz`.

### 5.3 Truy vấn

- Lọc dữ liệu `timestamptz` theo ngày/khoảng local: app tính biên UTC bằng `local_day_bounds_utc` / `local_range_bounds_utc`, query `WHERE created_at >= :start AND created_at < :end`. **Không** dùng `(created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date = …` trong code ứng dụng (sai index, dễ lẫn session tz).
- Lọc dữ liệu có cột `*_local_date`: so sánh `date` trực tiếp.
- Cặp `(occurrence_local, due_at)` luôn được ghi cùng nhau trong một câu lệnh; `due_at` là giá trị dẫn xuất từ `local_to_utc(occurrence_local, tz)`.

---

## 6. API

- Instant: `"2026-09-15T02:30:00.000Z"`.
- Local wall: `"2026-09-16T15:00"` (không giây, không offset).
- Local date: `"2026-09-15"`.
- Local time: `"23:00"`.
- Response có header `X-Server-Time`.
- Request chứa instant có offset khác `Z` → server chấp nhận, chuẩn hóa về UTC. Request chứa local wall có offset → 422.
- Không API nào nhận timezone từ client ở v1.

---

## 7. Recurrence (reminder)

### 7.1 Schema

```json
{
  "freq": "daily | weekly | monthly | yearly",
  "interval": 1,
  "by_weekday": ["MO","TU","WE","TH","FR","SA","SU"],
  "by_month_day": [14],
  "until_local_date": "2027-12-31",
  "count": null
}
```

| Field | Ràng buộc |
|---|---|
| `freq` | bắt buộc |
| `interval` | 1..365, mặc định 1 |
| `by_weekday` | chỉ khi `weekly`; ≥ 1 phần tử; mặc định = weekday của `first_due_local` |
| `by_month_day` | chỉ khi `monthly`; 1..31 hoặc `-1` (ngày cuối tháng); mặc định = ngày của `first_due_local` |
| `until_local_date` | tùy chọn, ≥ ngày của `first_due_local` |
| `count` | tùy chọn 1..1000; không đồng thời với `until_local_date` |

Giờ trong ngày của mọi occurrence = giờ của `first_due_local`.

### 7.2 Mở rộng occurrence (thuần local, rồi mới đổi UTC)

```
expand(first_due_local, recurrence, window_start_local_date, window_end_local_date):
  sinh dãy ngày local theo freq/interval bắt đầu từ first_due_local.date:
    daily   : d = start + k*interval ngày
    weekly  : với mỗi tuần (tuần bắt đầu Thứ Hai) cách tuần đầu k*interval tuần, mọi ngày trong by_weekday
    monthly : với mỗi tháng cách k*interval tháng, ngày = clamp_day(y, m, by_month_day) (‑1 → ngày cuối tháng)
    yearly  : clamp_day(y, month_of_first, day_of_first)
  loại ngày < first_due_local.date, ngày > until_local_date, vượt count
  giữ ngày trong [window_start, window_end]
  occurrence_local = datetime.combine(d, first_due_local.time())
  due_at = local_to_utc(occurrence_local)
```

- **Khác RFC 5545 có chủ đích:** `by_month_day` lớn hơn số ngày của tháng → dùng ngày cuối tháng (không bỏ tháng). Cùng quy tắc với kỳ report (§9.2), để "ngày 31 hằng tháng" không mất tháng 2.
- `count` đếm từ occurrence đầu tiên (kể cả đã qua).

---

## 8. Thời gian với LLM

### 8.1 Input

Context luôn có `<now>` theo `format_prompt_now` và, cho chat normal, dòng phụ `<journal_default_date>YYYY-MM-DD</journal_default_date>` (§9.1).

### 8.2 Output

LLM trả `due_local` dạng `YYYY-MM-DDTHH:MM` và `*_local_date` dạng `YYYY-MM-DD`, đều hiểu là giờ Việt Nam.

### 8.3 Hướng dẫn phân giải (đặt trong `output_contract.vi.md`)

| Cách nói | Phân giải |
|---|---|
| `mai` | ngày local + 1 |
| `mốt`, `ngày kia` | + 2 |
| `hôm qua` | − 1 |
| `thứ N` (không kèm tuần) | ngày thứ N gần nhất **từ hôm nay trở đi**; nếu là hôm nay mà giờ đã qua → tuần sau |
| `thứ N tuần sau` | thứ N của tuần kế tiếp (tuần bắt đầu Thứ Hai) |
| `cuối tuần` | Thứ Bảy gần nhất từ hôm nay trở đi |
| `đầu tháng sau` | ngày 1 tháng sau |
| `cuối tháng` | ngày cuối tháng hiện tại |
| `X phút nữa`, `X tiếng nữa` | now + X, làm tròn **lên** phút |
| `sáng` (không giờ) | 08:00 |
| `trưa` | 12:00 |
| `chiều` | 15:00 |
| `tối` | 20:00 |
| `đêm` | 22:00 |
| `H giờ` / `Hh` không buổi, H ≤ 12 | chọn thời điểm **tương lai gần nhất** giữa `H:00` và `(H+12):00` |
| `H giờ` với H ≥ 13 | dùng nguyên |
| `H giờ sáng/chiều/tối` | `sáng`: H; `trưa`: H (11–12) hoặc H+12 (1–2); `chiều`/`tối`: H+12 nếu H < 12; `đêm`: H+12 nếu 7 ≤ H ≤ 11, H nếu H ≤ 4 |
| Ngày âm lịch (`rằm`, `mùng 1 âm`) | **Không hỗ trợ v1**: hỏi người dùng ngày dương lịch |
| Mơ hồ không phân giải được | không phát action, hỏi lại |

### 8.4 Backend validate

| Kiểm tra | Lỗi |
|---|---|
| Format sai | `ACTION_INVALID` |
| `due_local` < business_now + 30 s | `DUE_IN_PAST` (needs_clarification) |
| `due_local` > business_now + 5 năm | `DUE_TOO_FAR` |
| `work_local_date` > `journal_default_date` hoặc < hôm nay − 60 ngày | `JOURNAL_DATE_OUT_OF_RANGE` |
| Recurrence không hợp lệ §7.1 | `RECURRENCE_INVALID` |

Backend **không** tự "sửa" thời gian LLM đưa ra (không tự cộng 12 giờ, không tự dời sang mai).

---

## 9. Danh mục phép tính nghiệp vụ

### 9.1 Ngày mặc định của journal

```
journal_default_date(instant, cutoff = user_settings.journal_day_cutoff_local (mặc định 04:00)):
  L = to_business(instant)
  return L.date() - 1 day  nếu L.time() < cutoff
         L.date()          ngược lại
```

Áp dụng khi `work_local_date = null` (AI_PROTOCOL `date_basis=default`) và cho entry tạo từ UI không chọn ngày.

### 9.2 Kỳ báo cáo công việc — canonical half-open (QUYẾT ĐỊNH CHỐT)

**Định nghĩa canonical (backend):** mỗi kỳ là khoảng **nửa mở**

```
[ ngày B tháng trước 00:00:00 ,  ngày B tháng hiện tại 00:00:00 )   theo Asia/Ho_Chi_Minh
```

với `boundary_day` B. **Giá trị chốt cho workflow báo cáo tháng của người dùng: B = 15**, tức kỳ `[15 tháng trước 00:00:00, 15 tháng này 00:00:00)`.

Tham số (STANDING_INSTRUCTIONS_SPEC §4.2): `boundary_day` B ∈ 1..31 (mặc định 15), `run_time_local` (mặc định `09:00`, phải ≥ `journal_day_cutoff_local`).

```
boundary(y, m) = clamp_day(y, m, B)            # B > số ngày của tháng → ngày cuối tháng

Kỳ đóng tại tháng (y, m):
  start_local_date         = boundary(prev(y, m))
  end_exclusive_local_date = boundary(y, m)
  last_local_date          = end_exclusive_local_date − 1 ngày      # CHỈ dùng để hiển thị
  local interval           = [combine(start, 00:00:00), combine(end_exclusive, 00:00:00))
  utc interval             = local_range_bounds_utc(start, end_exclusive)
  run_at (UTC)             = local_to_utc(combine(end_exclusive_local_date, run_time_local))
  period_key               = f"{start_local_date}--{end_exclusive_local_date}"
```

Quy tắc bắt buộc:

1. **Chỉ tồn tại một kiểu kỳ: half-open.** Không có chế độ inclusive hay overlap. Mọi code, DB, API lưu và truyền kỳ dưới dạng `(start_local_date, end_exclusive_local_date)`.
2. **Mỗi ngày thuộc đúng một kỳ.** Kỳ liên tiếp liền nhau: `end_exclusive` của kỳ k = `start` của kỳ k+1. Không chồng, không hở.
3. Thành viên của kỳ:
   - dữ liệu có `*_local_date`: `start_local_date <= d < end_exclusive_local_date`;
   - dữ liệu `timestamptz`: `start_utc <= t < end_utc`.
   Không dùng `BETWEEN` với ngày cuối.
4. **Report được tạo sau khi kỳ đã đóng**: vào ngày `end_exclusive_local_date` (ngày 15) lúc `run_time_local`, hoặc muộn hơn nếu catch-up. Scheduler từ chối `run_at < local_to_utc(combine(end_exclusive, journal_day_cutoff_local))` (đảm bảo nhật ký gửi sau nửa đêm cho ngày cuối kỳ đã được tính).
5. **Diễn đạt UI (bắt buộc):** "Từ ngày {start.day} tháng trước đến hết ngày {last.day} tháng này" — với B = 15: **"Từ ngày 15 tháng trước đến hết ngày 14 tháng này"**. Khoảng cụ thể hiển thị `15/08 – 14/09` (ngày cuối là `last_local_date`).
6. **Wording "báo cáo ngày 14":** nếu product copy gọi kỳ theo ngày cuối (vd "báo cáo ngày 14", "kỳ chốt ngày 14") thì đó **chỉ là wording UI**, không thay đổi interval backend `[15, 15)` và không thay đổi ngày chạy (ngày 15).
7. B = 1 ⇒ kỳ là trọn tháng dương lịch trước.

Phân giải lời người dùng → B (hướng dẫn cho LLM, STANDING_INSTRUCTIONS_SPEC §4.2):

| Người dùng nói | B |
|---|---|
| "từ ngày N tháng trước đến ngày N tháng này" (vd 14 → 14) | N + 1 (ngày N là ngày cuối được tính) → "14 → 14" = **15** |
| "đến hết ngày E" / "chốt ngày E" | E + 1 |
| "từ ngày S tháng trước đến hết ngày S−1 tháng này" | S |
| "theo tháng", "đến cuối tháng" | 1 |

Kỳ "hiện hành" tại ngày D: kỳ có `start ≤ D < end_exclusive`.
`latest_completed` tại ngày D (= `business_today`): kỳ đã đóng gần nhất, tức kỳ có `end_exclusive_local_date ≤ D` lớn nhất (không phụ thuộc report đã được tạo hay chưa).

### 9.3 Quiet hours

```
in_time_window(t, start, end):
  if start == end: return False
  if start < end : return start <= t < end
  else           : return t >= start or t < end      # qua nửa đêm, vd 23:00–07:00
```

Dùng `to_business(now).time()`.

### 9.4 Giờ chạy routine hằng ngày

`next_run_at` cho `time_local` hằng ngày: `candidate = combine(business_today, time_local)`; nếu `local_to_utc(candidate) <= now` → ngày mai. Lưu `routine_schedules.next_run_at` (UTC).

### 9.5 Cửa sổ materialize reminder

`[business_today, business_today + 14 ngày]`, job `extend_recurrences` lúc 00:10 local mỗi ngày.

### 9.6 Quan hệ

- `days_together = (business_today − relationship_state.first_interaction_local_date).days + 1`.
- Milestone (100, 365 ngày…) so theo `business_today`.

### 9.7 Day summary

Job `day_summary(local_date = business_today − 1)` chạy 03:30 local; lấy message trong `local_day_bounds_utc(local_date)`.

### 9.8 Task quá hạn

`due_local_date < business_today` và `status=open`.

### 9.9 Proactive message caps

"Trong ngày" = `local_day_bounds_utc(business_today)`.

---

## 10. Flutter

### 10.1 BusinessClock

```
offset = median(5 mẫu gần nhất của (X-Server-Time − thời điểm nhận response theo DateTime.now().toUtc()))
businessNowUtc() = DateTime.now().toUtc().add(offset)
businessNow()    = tz.TZDateTime.from(businessNowUtc(), vn)
businessToday()  = LocalDate(businessNow().year, .month, .day)
```

- `|offset| > 5 phút` → banner nhẹ "Đồng hồ điện thoại đang lệch".
- Mọi hiển thị ngày/giờ: `DateFormat(pattern, 'vi')` áp lên `TZDateTime` của `vn`.
- Timezone thiết bị khác Việt Nam (offset hiện tại ≠ +7) → hiển thị nhãn nhỏ "giờ Việt Nam" cạnh giờ trong màn hình reminder/journal.

### 10.2 Local notifications

```
zonedSchedule(
  id: stableId(occurrence_id),
  scheduledDate: tz.TZDateTime.from(dueAtUtc.subtract(offset), vn),   // bù lệch đồng hồ thiết bị
  androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
  …)
```

- `due_at` lấy từ server (UTC). Client **không** tự tính recurrence.
- Offset thay đổi > 60 s so với lúc đặt → đặt lại toàn bộ lịch 7 ngày.

### 10.3 Nhập liệu

- Date/time picker trả giờ tường Việt Nam → gửi API dạng `*_local`.
- Không bao giờ gửi `DateTime.toIso8601String()` của giờ local thiết bị.

---

## 11. Edge cases & failure modes

| Tình huống | Xử lý đúng |
|---|---|
| Tin nhắn lúc 23:59:59 local (16:59:59Z) | thuộc ngày local đó |
| Tin nhắn lúc 00:00 local (17:00:00Z ngày UTC trước) | thuộc ngày local mới; ngày UTC vẫn là hôm trước → không được dùng ngày UTC |
| Tin nhắn journal 03:30 local | ngày mặc định = hôm trước (cutoff 04:00) |
| `boundary_day` 29/30/31 tháng 2 | `clamp_day` → 28 (29 năm nhuận) |
| Nhật ký gửi 01:00 ngày 15 cho công việc ngày 14 | `work_local_date = 14` (cutoff) → thuộc kỳ vừa đóng; report chạy ≥ 04:00 ngày 15 nên đã bao gồm |
| Kỳ qua năm (tháng 1) | prev(2027,1) = (2026,12) |
| Thiết bị đặt timezone New York | UI vẫn hiện giờ Việt Nam; notification nổ đúng instant |
| Đồng hồ thiết bị sai 10 phút | hiển thị dùng offset; local notification bù offset |
| Server downtime qua giờ chạy routine | catch-up theo STANDING_INSTRUCTIONS_SPEC §6.3 |
| tzdata cập nhật | pin version; nâng cấp có test hồi quy §12 |
| Postgres session tz bị đổi | `readyz` phát hiện, fail |
| Dữ liệu `*_local` bị ghi kèm offset | 422 ở API; `CHECK` ở DB không áp dụng (kiểu timestamp) → test schema |

---

## 12. Test matrix bắt buộc (dùng `time-machine` / FakeClock)

| # | Now (UTC) | Kiểm tra | Kỳ vọng |
|---|---|---|---|
| T01 | `2026-09-14T16:59:59Z` | `business_today` | `2026-09-14` |
| T02 | `2026-09-14T17:00:00Z` | `business_today` | `2026-09-15` |
| T03 | `2026-09-14T20:30:00Z` | `journal_default_date` (cutoff 04:00) | `2026-09-14` |
| T04 | `2026-09-14T21:00:00Z` | `journal_default_date` | `2026-09-15` |
| T05 | — | `local_day_bounds_utc(2026-09-15)` | `[2026-09-14T17:00Z, 2026-09-15T17:00Z)` |
| T06 | — | `local_to_utc(2026-09-16T15:00)` | `2026-09-16T08:00:00Z` |
| T07 | — | Kỳ B=15 đóng tháng 2026-09 | start `2026-08-15`, end_exclusive `2026-09-15`, last `2026-09-14`, UTC `[2026-08-14T17:00:00Z, 2026-09-14T17:00:00Z)`, run `2026-09-15 09:00` local = `2026-09-15T02:00:00Z`, key `2026-08-15--2026-09-15`, nhãn UI `15/08 – 14/09` |
| T08 | — | B=15: ngày `2026-08-15`, `2026-09-14`, `2026-09-15` thuộc kỳ nào | `08-15` và `09-14` ∈ `2026-08-15--2026-09-15`; `09-15` ∈ `2026-09-15--2026-10-15` (không thuộc kỳ trước) |
| T09 | — | B=15: instant `2026-09-14T16:59:59Z` và `2026-09-14T17:00:00Z` | lần lượt ∈ kỳ `08-15--09-15` và ∈ kỳ `09-15--10-15` |
| T10 | — | B=15 đóng tháng 2027-01 | `2026-12-15--2027-01-15`, last `2027-01-14` |
| T11 | — | B=31 đóng tháng 2027-02 và 2027-03 | `2027-01-31--2027-02-28` (last `02-27`); `2027-02-28--2027-03-31` (last `03-30`) — liền nhau |
| T12 | — | B=31 đóng tháng 2028-02 (nhuận) | `2028-01-31--2028-02-29` (last `02-28`), run `2028-02-29` |
| T13 | `2026-09-15T01:59:00Z` | routine report B=15 09:00 đã đến hạn? | chưa |
| T14 | `2026-09-15T02:00:00Z` | như trên | đến hạn |
| T25 | — | Property: B ∈ 1..31, 36 kỳ liên tiếp bắt đầu từ 2026-01 | mỗi ngày trong toàn khoảng thuộc **đúng một** kỳ; `end_exclusive(k) = start(k+1)` |
| T26 | `2026-09-15T00:30:00Z` (07:30 local 15/09) | `latest_completed` B=15 | `2026-08-15--2026-09-15` (dù report chưa chạy lúc 09:00) |
| T27 | — | Tạo routine B=15 với `run_time_local=03:00` (cutoff 04:00) | validate lỗi (run_time phải ≥ cutoff) |
| T15 | `2026-09-14T16:00:00Z` (23:00 local) | quiet hours 23:00–07:00 | true |
| T16 | `2026-09-14T23:59:00Z` (06:59 local) | quiet hours | true |
| T17 | `2026-09-15T00:00:00Z` (07:00 local) | quiet hours | false |
| T18 | — | recurrence monthly `by_month_day=[31]` từ `2026-12-31T08:00`, 3 occurrence | `2026-12-31`, `2027-01-31`, `2027-02-28` lúc 08:00 local |
| T19 | — | recurrence weekly `[TU, TH]` từ `2026-09-15T15:00` (Thứ Ba) trong 7 ngày | `2026-09-15`, `2026-09-17`, `2026-09-22` |
| T20 | `2026-09-15T03:00:00Z` (10:00 local) | validate `due_local=2026-09-15T09:00` | `DUE_IN_PAST` |
| T21 | — | Postgres: insert `timestamptz` rồi đọc qua API | chuỗi kết thúc `Z`, giá trị không đổi |
| T22 | Flutter, device TZ `America/New_York` | hiển thị `due_at=2026-09-16T08:00Z` | `15:00 Thứ Tư, 16/09` |
| T23 | — | `format_prompt_now` tại `2026-09-15T02:30Z` | `2026-09-15T09:30 Thứ Ba (giờ Việt Nam)` |
| T24 | — | CI lint | không có `timedelta(hours=7)`, `datetime.now(`, `DateTime.now()` ngoài module cho phép |

---

## 13. Invariants

INV-01, INV-19, INV-20 (ARCHITECTURE §13), cộng:

| ID | Invariant |
|---|---|
| TZI-01 | Mọi `due_at` = `local_to_utc(occurrence_local, tz)` tại thời điểm ghi. |
| TZI-02 | Kỳ report luôn half-open `[start, end_exclusive)`; các kỳ liên tiếp không chồng, không hở; mỗi ngày thuộc đúng một kỳ. |
| TZI-03 | Không có giá trị datetime naive nào đi qua ranh giới hàm domain (chỉ tồn tại ở parse/serialize). |
