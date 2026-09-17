# HANA PHASE 5 FINAL RE-AUDIT — XÁC MINH PHASE 5.2

Ngày review: 2026-09-16 · Vai trò: senior reviewer · Phạm vi: **chỉ** xác minh 3 S2 còn lại của `PHASE_5_REAUDIT.md` (S2-R1, S2-R2, S2-R3) sau Phase 5.2 (`PHASE_5_2_FIX_REPORT.md`), regression/stress, emulator staging, production safety và Phase 6 readiness. Không sửa code, không làm Phase 6.

**KẾT LUẬN: PHASE 5 FINAL RE-AUDIT — PASS** (0 S1, 0 S2, S3 còn lại ở §8)

**READY FOR PHASE 6**

---

## 1. Tóm tắt

| Finding | Kết quả | Bằng chứng chính |
|---|---|---|
| S2-R1 — timer stale của turn A tác động turn B | **ĐÃ SỬA** | Tick mang `token` + `turnId`; reducer bỏ tick khi sai token **hoặc** sai owner. Probe với driver **bỏ qua `cancel()`** (mọi timer cũ đều sống): 6 cách đóng turn, chuỗi A/B/A/C/B/D tái dùng ID, 10.000 sự kiện ngẫu nhiên — 0 lần turn mới bị mutate. |
| S2-R2 — reducer bỏ event khi `paused` → kẹt talking/thinking | **ĐÃ SỬA** | Khi `paused` chỉ chặn input foreground và callback visual; turn/TTS/job/terminal tick vẫn cập nhật state. Watchdog `tts_playback_max` 10 phút. Probe: 3 terminal event ở nền + resume sau 3 giờ, 10.000 pause/resume ngẫu nhiên có phát timer thật — 0 lần kẹt. Emulator: resume sau TTS ở nền → `idle`. |
| S2-R3 — inactivity timer fire sớm rồi không reschedule | **ĐÃ SỬA** | Callback kiểm lại bằng clock rồi **đặt lại timer cho phần còn thiếu, giữ nguyên deadline**. Probe với `SystemTimerDriver` + `SystemClock` thật: 80–82/300 lần fire sớm (đúng như re-audit đo 96/300) nhưng **300/300 khóa tại/sau deadline**. 300 phiên widget ngẫu nhiên (767 wake sớm, 151 wake trễ, 586 reset activity): 0 khóa sớm, 0 bỏ sót. Emulator: 15 phút thật → khóa (§6). |

`flutter analyze`: No issues. `flutter test`: **115/115 PASS**. Regression trong repo cover đúng 3 finding; không test nào encode lại hành vi sai (test "paused ignores events" cũ đã được thu hẹp đúng về foreground input).

---

## 2. Tài liệu và mã đã đọc

| Nhóm | Nội dung |
|---|---|
| Docs | PHASE_5_REAUDIT, PHASE_5_2_FIX_REPORT, PHASE_5_1_FIX_REPORT, PHASE_5_AUDIT, CHARACTER_SYSTEM (§8.2–§8.4, §14), PRIVACY_SPEC (§5.4), VOICE_SPEC §8.2, ARCHITECTURE §0.1, ACCEPTANCE_CRITERIA (AC-PRV-05/06) |
| Engine | `character_engine.dart` (toàn bộ 670 dòng), `engine_event.dart`, `engine_effect.dart`, `engine_state.dart`, `effect_executor.dart`, `timer_driver.dart`, `clock.dart`, `engine_config.dart`, `session_manager.dart` |
| App/Private | `character_runtime_controller.dart`, `private_mode_screen.dart`, `private_session.dart`, `home_screen.dart`, `settings_screen.dart` |
| Tests | 11 file / 115 test; đọc kỹ `phase5_2_event_timer_test.dart` (657 dòng), `phase5_2_stress_test.dart`, `phase5_2_related_s3_test.dart`, phần paused của `phase5_1_regression_test.dart` |
| Tham chiếu ngoài | `dart-lang/sdk` `runtime/vm/os_android.cc`: `OS::GetCurrentMonotonicTicks` dùng `CLOCK_MONOTONIC` (liên quan S3-F3) |

---

## 3. Lệnh, test và probe đã chạy

| Lệnh | Kết quả |
|---|---|
| `flutter analyze --no-pub` (repo) | **No issues found** (5,2 s) |
| `flutter test --no-pub --reporter expanded` (repo) | **115/115 PASS** ("All tests passed!") |
| Probe `final_probe_engine_test.dart` (16 test) — chạy trên **bản sao** app trong scratchpad, không ghi vào repo | **16/16 PASS** (§4, §5) |
| Probe `final_probe_private_test.dart` (5 test) — bản sao scratchpad | **5/5 PASS** (§4.3, §5) |
| `flutter build apk --release --flavor production --no-pub` | **FAIL đúng kỳ vọng**: "Production release signing is not configured. Create android/key.properties from key.properties.example; never use the debug key." Không có `key.properties`/`*.jks`/`*.keystore` trong `android/`. |
| `tool/audit_apk.ps1` × 3 ABI (staging release build 19:55, mới hơn source 19:30) | **APK AUDIT PASS** × 3 |
| Quét chuỗi độc lập bằng Python (UTF-8 + UTF-16LE, toàn bộ entry) × 3 ABI | 0 hit: `Private developer harness`, `Demo private reaction`, `Character Lab`, `debug-session`, `Private engine đang hoạt động`, `per-clip-policy-mock`, `DemoManifestFactory`, `Demo PTT`, `PRIVATE_SESSION_REQUIRED`. Đối chứng dương: `Chế độ riêng tư chưa khả dụng` = 1, `Chat placeholder` = 1. 66 entry, 0 video. |
| Emulator `Television_4K` (API 36, x86_64) | §6 |

Không file nào trong `repo/` bị sửa ngoài việc tạo tài liệu này. Probe nằm ở scratchpad phiên làm việc.

---

## 4. Xác minh từng S2

### 4.1 S2-R1 — Timer stale theo turn

**Cơ chế đã sửa (đọc mã):**

- `engine_event.dart` `Tick(tag, token, {turnId})`; `engine_effect.dart` `ScheduleTick(at, tag, token, {turnId})`.
- `character_engine.dart:516-531` `_schedule` gắn `turnId: result.state.currentTurnId` cho **mọi** timer; `:364-370` `_tick` bỏ tick khi `timerTokens[tag] != token` **hoặc** (`_isTurnTimer(tag)` và `turnId != currentTurnId`).
- `_cancelTurnTimers` (`:533-544`) tăng token 7 tag turn (`tts_wait_timeout`, `tts_playback_max`, `pre_speech_max`, `thinking_min_dwell`, `thinking_variant_rotate`, `overlay_max`, `overlay_min`) và phát `CancelTick`. Được gọi ở **mọi** đường đóng/mở turn: `TurnSubmitted` (`:112`), `PttPressed` (`:94`), `TtsStarted` (`:133`), `TtsFinished` (`:150`), `TtsFailed` (`:179`), `TurnFailed` (`:195`), `TurnCancelled` (`:210`), `ReplyReady(!willSpeak)` (`:276`), tick `tts_wait_timeout` (`:413`). `tts_playback_max` đi qua `TtsFailed`.
- Hệ quả: timer của turn cũ bị vô hiệu hoá **hai lớp** (token + owner). Tái dùng ID cũng an toàn vì token tăng khi đóng và khi mở turn.

**Probe đối kháng (scratchpad, `LeakyTimerDriver`: `cancel()`/`cancelAll()` là no-op, không ghi đè theo tag, phát *mọi* callback đã lên lịch):**

| Probe | Kết quả |
|---|---|
| A (`ReplyReady surprised`, có `pre_speech_max` + `tts_wait_timeout` + `overlay_max`) đóng bằng `TurnCancelled` / `TtsFailed` / `TtsFailed` sau `TtsStarted` / `TtsFinished` / tick `tts_wait_timeout` / `PttPressed`; rồi `TurnSubmitted(B)`; phát toàn bộ timer rò rỉ của A; chờ 20 s | 6/6: B vẫn `thinking`, không `ReleaseTtsGate` thừa; `ReplyReady(B)` mở gate đúng 1 lần; `TtsStarted(B)` → `talking`; các `tts_wait_timeout` rò rỉ (A và B) không đụng B khi đang `talking`; `TtsFinished(B)` → `idle` |
| Chuỗi nhanh A/B/A/C/B/D (tái dùng ID, 100 ms/turn) rồi A thật `talking` 30 s, phát mọi timer rò rỉ | A vẫn `talking`, `turn=A` |
| 10.000 sự kiện ngẫu nhiên (seed 9161) gồm pause/resume, PTT, job, mọi terminal event, phát timer rò rỉ theo bước thời gian ngẫu nhiên ≤ 12 s; invariant: timer không thay turn, không tạo turn, chỉ được đóng turn từ `thinking`/`talking`/`surprised` (timeout của chính nó); 20 lần kiểm hội tụ | **PASS**, 0 vi phạm |

**Regression trong repo** (`phase5_2_event_timer_test.dart`): cancel/TtsFailed/TurnFailed A → B → timeout A; owner + generation; stale `pre_speech_max`; A/B/C; reused ID. `phase5_2_stress_test.dart`: 10.000 event với tick stale token và tick foreign owner (`expect(same(before))`).

**Kết luận S2-R1: PASS** — timer cũ không thể mutate turn mới, kể cả khi lớp cancel của driver hỏng hoàn toàn.

### 4.2 S2-R2 — Event bị bỏ khi `paused`

**Cơ chế đã sửa (đọc mã):**

- `character_engine.dart:61-75`: khi `paused` chỉ bỏ event **không** thuộc {`TurnSubmitted`, `ReplyReady`, `TtsStarted`, `TtsFinished`, `TtsFailed`, `TurnFailed`, `TurnCancelled`, `JobStarted`, `JobFinished`} và tick không thuộc `_runsWhilePaused` = {`tts_wait_timeout`, `tts_playback_max`, `pre_speech_max`, `thinking_min_dwell`} (`:567-572`). `AppPaused` (`:19-29`) không còn huỷ `tts_wait_timeout`.
- `TtsStarted` đặt `tts_playback_max` 10 phút (`:139-143`, `engine_config.dart:17`) → `TtsFailed` (`:418-422`). Barge-in/`TtsFinished` huỷ.
- `AppResumed` (`:30-60`): reaction đang dở được `_overlay` lại (đặt lại `overlay_max`), `working` đặt lại `working_max`, `thinking` đặt lại rotate. Timer turn (wait/playback) không bị huỷ ở pause nên vẫn chạy.
- `home_screen.dart:57-61` vẫn phát `AppPaused`/`AppResumed` theo lifecycle.

**Probe đối kháng (scratchpad):**

| Probe | Kết quả |
|---|---|
| `talking` → pause → `TtsFinished` / `TtsFailed` / `TurnCancelled` (không hợp lệ từ talking) → 11 phút thời gian chảy + 3 giờ → resume → turn B đầy đủ | 3/3: `turn=null`, không talking/thinking sau resume; B mở gate (2 gate tổng), talking → idle |
| `thinking` → pause → `TurnFailed` / `TurnCancelled` / `TtsFailed` → 1 giờ → resume | 3/3: idle, nhận B |
| `thinking` → pause → `ReplyReady(surprised)` ở nền → `pre_speech_max` (chạy khi paused) mở gate → `TtsStarted`/`TtsFinished` ở nền → resume | PASS |
| 10.000 pause/resume + terminal event ngẫu nhiên (seed 20260916) **có phát timer đến hạn**; mỗi 250 bước: resume, im lặng 10 phút 9 giây (thời gian chảy 1 s/bước) → không được `talking`, không `thinking` có cue | PASS, 0 lần kẹt |

**Regression trong repo:** background `TtsFinished` (trước/sau pause), afterglow sau resume, `thinking`→pause→`TurnFailed`, pause 2 giờ, `TurnCancelled` ở nền, stale event ở nền, watchdog 10 phút, `tts_wait_timeout` chạy khi paused. Test cũ dòng 231 đã đổi thành "ignores foreground input" và chỉ assert `PttPressed` bị bỏ khi paused — đúng với §8.3 (giữ state, không có input UI khi ở nền).

**Lưu ý thiết kế (không phải lỗi):** `CueReceived` và tick `overlay_max`/`overlay_min`/`working_max` bị bỏ khi paused; `AppResumed` đặt lại chúng nên state hội tụ khi quay lại. Visual effect (`Play`) khi paused vẫn phát tới runtime nhưng stage đang `PauseStage` — đúng "logical state convergent, visual suppressed".

**Kết luận S2-R2: PASS** — engine không thể kẹt vĩnh viễn do pause/resume; xác nhận thêm trên emulator (§6).

### 4.3 S2-R3 — Auto-lock 15 phút

**Cơ chế đã sửa (đọc mã):**

- `private_mode_screen.dart:71-83` `_scheduleInactivity`: đặt timer tại `inactivityDeadline` (= `lastActivity + 15 phút`); callback: nếu `inactivityReason() != null` → `_lock()`, ngược lại **gọi lại `_scheduleInactivity()`** với cùng deadline (phần còn thiếu). `_activity()` (`:85-89`) cập nhật `lastActivity`, huỷ và đặt lại. `_lock()` `cancelAll` + `onPrivateLocked`. `didChangeAppLifecycleState` giữ 60 s background + kiểm inactivity khi resume.
- `PrivateModeScreen` nhận `clock`, `timerDriver`, `unlockService` inject được (`:15-25`).
- `SystemTimerDriver.schedule` (`timer_driver.dart:18-25`): `Timer(at - now)`; delay < 1 ms bị Dart cắt về 0 ms → callback lặp qua event loop cho tới khi clock µs vượt deadline (đo được tối đa 13–19 vòng, §5).

**Probe đối kháng (scratchpad):**

| Probe | Kết quả |
|---|---|
| Pattern reschedule y hệt màn hình, chạy với `SystemTimerDriver` + `SystemClock` **thật**, 300 lần (limit 5–11 ms) | **Fire sớm 80/300 và 82/300** (hai lần chạy — cùng cỡ với 96/300, 105/300 của re-audit) nhưng **300/300 khóa tại/sau deadline**; tổng 494–544 vòng, tối đa 13–19 vòng/lần, khóa trễ tối đa 10,8–14,9 ms. Mã cũ sẽ để 80 phiên này mở vô hạn. |
| 300 phiên widget `PrivateModeScreen` ngẫu nhiên (seed 777): 0–4 lần reset activity ở thời điểm ngẫu nhiên < 15 phút, 0–5 lần wake sớm (1 µs – 5 s trước deadline), rồi tới deadline đúng hoặc trễ 0–10 s | **767 wake sớm, 151 wake trễ, 586 reset**: 0 lần khóa sớm, deadline không trôi, 300/300 khóa tại deadline, về Home, `timer.tags` rỗng sau khóa |
| 14:59.999 → mở; +1 ms → khóa; mở lại, 1 giờ không activity → khóa, không timer sót | PASS |
| Hết hạn authorization 1 giờ dù có activity mỗi 9 phút | Khóa ở 63 phút (expiry) — PASS |
| `PrivateAutoLockPolicy` biên 14:59.999999 / +1 µs | PASS |

**Regression trong repo:** wake sớm 1 ms và 5 s; 300 wake sớm seeded; activity 14:59 reset; 1 giờ; 59/60 s background; stress 300 phiên jitter ±5 s ở mức policy.

**Kết luận S2-R3: PASS** — private session chắc chắn khóa khi đủ deadline inactivity (theo clock đã inject). Xem S3-F3 về nguồn clock trên Android.

---

## 5. Stress

| Stress | Nguồn | Kết quả |
|---|---|---|
| 10.000 turn/timer/lifecycle events, seed 5202026 (stale token, foreign owner, pause/resume) | repo `phase5_2_stress_test.dart` | PASS |
| 10.000 events + **driver rò rỉ timer** (không cancel), seed 9161, 20 điểm kiểm hội tụ | probe | PASS: không crash, không wrong-turn mutation, không stuck |
| 10.000 pause/resume + phát timer đến hạn, seed 20260916, 40 điểm kiểm im lặng 10 phút | probe | PASS |
| 300 phiên private jitter ±5 s ở mức policy, seed 152026 | repo | PASS |
| 300 lần timer Dart thật (fire sớm 80–82/300) | probe | 300/300 khóa đúng |
| 300 phiên widget jitter ngẫu nhiên (767 wake sớm) | probe | 300/300 khóa đúng, 0 khóa sớm |

---

## 6. Emulator (AVD `Television_4K`, Android 16 / API 36, x86_64)

| Bước | Kết quả |
|---|---|
| Gỡ cài đặt sạch, cài `app-x86_64-staging-release.apk` (19.574.935 B, build 19:55) | Success |
| Cold launch `com.hana.hana_app.staging/com.hana.hana_app.MainActivity` | `LaunchState: COLD`, `TotalTime: 2677 ms`; `logcat *:E` không có lỗi hana/flutter/AndroidRuntime/FATAL |
| Home release | Semantics: `Hana`, `Cài đặt`, `Đang chờ thư viện vault`; **không** có Character Lab / Mic placeholder. `screencap` trả ảnh đen → FLAG_SECURE `auto` đang bật (thư viện có asset ≥ suggestive) — đúng PRIVACY_SPEC §4.1 |
| Settings release | Chỉ `Chế độ riêng tư chưa khả dụng`; không có harness, không per-clip mock |
| Cài `app-staging-debug.apk` (build 20:35) để dùng harness; đặt `wm size 1080x2340`, `wm density 420` để card trạng thái vào khung hình; đặt "Bảo vệ ảnh chụp màn hình" = `off` để `screencap` đọc được `Trạng thái:` | Cold launch OK |
| **Background/resume sau TTS** (demo: PTT → ReplyReady → TtsStarted +0,9 s → TtsFinished +1,4 s → cue happy). Đo bằng `wm_on_paused_called`/`wm_on_stop_called` trong event log: | |
| · lần 4: `onStop` (Flutter `paused`) tại **+0,41 s** sau tap → `TtsStarted` và `TtsFinished` đều xảy ra ở nền; resume sau 8 s | `Trạng thái: idle` ngay khi resume |
| · lần 5: `onPause` +0,79 s, `onStop` **+1,44 s** (≈ biên `TtsFinished`) | `idle` khi resume |
| · lần 1–3 (`HOME` ~0,15–0,5 s sau tap) | 3/3 `idle` khi resume |
| · lần 0 (`HOME` tới sau khi demo xong) | `happy` khi resume (afterglow được phát lại theo `AppResumed`) → `idle` sau ≤ 4 s |
| Không lần nào kẹt `talking`/`thinking`; `logcat *:E` sạch | ✔ |
| **Private auto-lock — background**: mở harness (`Private session`, `Context: private`) → HOME 65 s → resume | Về Settings (đã khóa), không lỗi |
| **Private auto-lock — 15 phút inactivity, timer thật, foreground** (`svc power stayon true`, poll semantics mỗi 30 s) | Mở 22:19:05 → poll 22:33:48 (14 phút 43 s) **vẫn mở** → poll 22:34:21 **đã khóa**, về Settings (khoảng khóa 15:00–15:16 do bước poll 30 s). `logcat *:E` không có lỗi. Đây là timer `SystemTimerDriver` + `SystemClock` thật, không mock. |

Cửa sổ 500 ms "đang nói" của demo khó bắn trúng tất định qua adb; các biến thể trước/giữa/sau `TtsStarted` đều được quan sát và mọi biến thể hội tụ về `idle`. Trường hợp chính xác được chốt bằng test tất định (§4.2).

---

## 7. Production safety (không regression)

| Kiểm tra | Kết quả |
|---|---|
| `flutter build apk --release --flavor production` không có `key.properties` | **FAIL closed** với thông báo đúng; không sinh artifact |
| Không có keystore/secret trong `android/` | ✔ (`key.properties` không tồn tại; không `*.jks`/`*.keystore`) |
| Mock private bypass trong staging release | ✔ 0 chuỗi harness/mock/`debug-session`; Settings chỉ hiện "chưa khả dụng"; probe re-audit trước về `onUnknownRoute` vẫn còn (widget test `release-like routes cannot bypass…` PASS trong 115) |
| Character Lab trong release | ✔ 0 chuỗi; Home release không có nút |
| Video production trong APK | ✔ 0 entry video ở cả 3 ABI; 66 entry; `audit_apk.ps1` PASS ×3 |
| Kích thước/ hash staging | arm64 18.095.640 B (`7916 51d6…`), x86_64 19.574.935 B (`4f41 898b…`), v7a 15.215.734 B (`4775 1ec2…`) — trùng fix report |

---

## 8. S3 còn lại (không chặn Phase 6; không sửa trong review này)

### S3 mới phát hiện trong final re-audit

| ID | Vấn đề | Bằng chứng | Đề xuất |
|---|---|---|---|
| **S3-F1** | `TurnSubmitted` bị bỏ khi đang ở **reaction** (happy/shy/surprised/concerned), trái CHARACTER_SYSTEM §8.3 dòng "idle, sleep, working, **reaction** → thinking". Trong ≤ 4 s afterglow sau `TtsFinished` (hoặc sau `TurnFailed` concerned), câu hỏi kế tiếp bị engine bỏ: không `ReleaseTtsGate` (chỉ phát nhờ gate timeout 1,5 s của player), `TtsStarted/Finished` của turn đó bị bỏ, stage không `talking`. Tự hồi phục khi overlay thoát (≤ 4 s). | `character_engine.dart:637-641` `_canSubmitTurn` = {idle, sleep, working}; probe P-A: `turn=null activity=happy`, gates=1 thay vì 2; turn C sau 5 s OK | Thêm reaction vào `_canSubmitTurn` (hoặc hạ overlay rồi `_thinking`). Cùng nhóm với S3-R3 (`talking` + `TtsStoppedByUser`), chốt ở Phase 6 khi nối chat thật. Không nâng S2 vì: không kẹt, tự hồi phục ≤ 4 s, không có timer sai turn. |
| **S3-F2** | `listening` → `AppPaused` → `PttCancelled`/`PttReleased` bị bỏ (là foreground input) → resume vẫn `listening`; `TurnSubmitted` bị từ chối khi `listening`. Chỉ thoát bằng PTT lần nữa. | probe P-B: `activity=listening` sau resume, `TurnSubmitted` → `turn=null`; PTT lại → idle | Xử lý `PttReleased`/`PttCancelled` khi paused, hoặc `AppPaused` khi `listening` → idle (ghi rõ trong §8.3). Phase 6 phải quy định UI gửi `PttCancelled` **trước** `AppPaused`. |
| **S3-F3** | `SystemClock` = origin + `Stopwatch`; trên Android `Stopwatch` dùng `CLOCK_MONOTONIC` (`os_android.cc`), **không đếm thời gian deep sleep** (tương đương `uptimeMillis`, khác `elapsedRealtime`/`CLOCK_BOOTTIME`). Dart `Timer` cũng theo clock này. Ba trigger khóa client (60 s background, 15 phút inactivity, expiry 1 giờ) đều đo bằng thời gian *awake*, không phải wall/boot time: máy tắt màn hình rồi suspend có thể đi qua 60 s wall-clock mà monotonic chưa tới 60 s. | `clock.dart:6-13`; PRIVACY_SPEC §5.4 "timer đo bằng monotonic clock" (ý định là chống chỉnh giờ, không phải bỏ qua suspend) | Khi dựng private thật ở Phase 6: lấy `SystemClock.elapsedRealtime()` qua platform channel (hoặc `CLOCK_BOOTTIME`) cho auto-lock, và/hoặc so thêm wall-clock có sanity check. Giữ S3 vì: release chưa có route private; kẻ tấn công cần mở khóa được thiết bị; doze maintenance window tích luỹ awake time; server idle TTL 15 phút / absolute 2 giờ (AC-PRV-05) là lớp khóa có thẩm quyền. **Phải sửa trước khi Phase 6 nối PIN/session thật.** |
| **S3-F4** | `build/app/outputs/flutter-apk/app-production-debug.apk` (81 MB, 20:35): applicationId production `com.hana.hana_app`, `application-debuggable`, có chuỗi harness private. Là artifact debug cục bộ (gitignored) nhưng dễ phát tán nhầm. Mở rộng S3-R5. | `aapt2 dump badging`; quét chuỗi | Xoá cùng `app-debug.apk` 455 MB; auditor từ chối APK `debuggable` hoặc package production ký debug key. |
| **S3-F5** | Test gap nhỏ: `phase5_2_stress_test.dart` chỉ dispatch tick stale/foreign, **không phát timer đến hạn** qua driver; `FakeTimerDriver.elapse` nhảy thời gian một lần nên tick trễ lên lịch timer mới từ mốc đã nhảy (thời gian không chảy). Probe của re-audit này đã bổ sung cả hai. | `phase5_2_stress_test.dart:15-120`, `timer_driver.dart:60-76` | Chuyển probe leaky-driver và flowing-time vào repo; thêm `elapse` theo bước cho FakeTimerDriver. |

### S3 chuyển tiếp từ re-audit (trạng thái sau 5.2)

| ID | Trạng thái |
|---|---|
| S3-R1 executor/timer cho private engine | **Đã đóng** trong 5.2 (`phase5_2_related_s3_test.dart`: effect/timer private chạy, lock dispose) |
| S3-R2 normal engine resume khi private mở | **Đã đóng** trong 5.2 (`dispatch` bỏ qua khi `isPrivateOpen`; test PASS) |
| S3-R3 `TtsStoppedByUser`, `TurnSubmitted` từ `talking` | Còn — chốt hợp đồng TtsQueue ↔ engine ở Phase 6 (gộp với S3-F1) |
| S3-R4 test gap | Phần lớn đóng (E1/E2/T1 đã thành regression); còn (d) `developerSurfacesFor` và (e) 50 rapid Play không init |
| S3-R5 auditor ELF/ký/kích thước/debuggable; artifact cũ | Còn một phần: `app-release.apk` cũ đã xoá; `app-debug.apk` 455 MB và `app-production-debug.apk` còn (S3-F4); auditor chưa mở rộng |
| S3-R6 VideoStage timeout cố định, codec, play khi paused, re-select thừa | Còn |
| S3-R7 `popUntil` private, FLAG_SECURE khi dispose | Còn |
| S3-R8 các S3 cũ (S3-02…S3-06, S3-08), `LogEngine` in trong release | Còn |

Không S3 nào ở trên làm mất hiệu lực 3 fix S2 hay tiêu chí PASS. S3-F3 là mục **bắt buộc** trong danh sách việc Phase 6 (private lifecycle) và nên được nâng lên S2 nếu Phase 6 ship auto-lock client trên clock hiện tại.

---

## 9. Phase 6 readiness

**SẴN SÀNG.** Điều kiện của re-audit trước đã đạt:

1. S2-R1 — timer gắn turn + generation; mọi đường đóng/mở turn vô hiệu hoá timer cũ; regression 3 cách đóng + A/B/C + reused ID. ✔
2. S2-R2 — event turn/TTS/job không mất khi paused; timer turn không bị huỷ ở pause; watchdog `tts_playback_max`; test cũ đã sửa; E2a/E2b thành regression. ✔
3. S2-R3 — auto-lock tất định (reschedule phần còn thiếu); `PrivateModeScreen` inject clock/timer/unlock; widget test 15 phút và 60 s. ✔
4. S3-R1/S3-R2 đã đóng cùng lúc. S3-R5 đóng một phần.

Việc phải mang sang Phase 6 (không chặn): S3-F1/S3-R3 (hợp đồng turn/TTS từ reaction/talking), S3-F2 (PTT khi background), **S3-F3 (clock boot-time cho auto-lock)**, S3-F4/S3-R5 (dọn artifact, auditor), S3-F5 (test), S3-R6/R7/R8.

---

**PHASE 5 FINAL RE-AUDIT — PASS**

0 S1, 0 S2. Ba S2 của re-audit (timer stale theo turn; deadlock qua background; auto-lock 15 phút) đã được sửa hoàn toàn và chịu được probe đối kháng (driver rò rỉ timer, 20.000 sự kiện ngẫu nhiên, 300 timer Dart thật, 300 phiên widget jitter) cùng xác minh emulator. Production vẫn fail closed; không mock private, không Character Lab, không video trong APK staging.

**READY FOR PHASE 6.**

STOP. Không sửa code. Không làm Phase 6.
