# HANA PHASE 5 RE-AUDIT — XÁC MINH REMEDIATION PHASE 5.1

Ngày review: 2026-09-16 · Vai trò: senior reviewer · Phạm vi: chỉ xác minh các finding S1/S2 của `PHASE_5_AUDIT.md` sau Phase 5.1 (`PHASE_5_1_FIX_REPORT.md`) và đánh giá mức sẵn sàng cho Phase 6. Không sửa code, không làm Phase 6.

**KẾT LUẬN: PHASE 5 RE-AUDIT — FAIL** (0 S1, 3 S2, 8 S3)

---

## 1. Tóm tắt

Phase 5.1 đã sửa **thật** phần lớn các lỗi cũ. Tôi xác minh độc lập như sau:

- **S1 đã đóng.** APK release không còn route `/private`, không còn harness private, mock unlock hay Character Lab. Tôi đã quét chuỗi trên APK build mới, có đối chứng dương. Không có đường nào tạo private engine khi chưa có `PrivateSessionAuthorization`. Build production **fail closed** khi chưa có keystore, ở cả APK lẫn AAB và cả khi build không chỉ định flavor.
- **Manifest** (S2-04, S2-05) đạt. Runtime dùng đúng dữ liệu của master Phase 4: 0 khác biệt trên 43 asset × 29 field runtime. Validator chặn đầy đủ các ràng buộc chéo. Manifest lỗi fail closed về silhouette.
- **VideoStage** (S2-06) đạt. Stress 2 × 300 Play, có init hoàn tất thật và có crossfade, cho tối đa 2 controller sống, không dispose trùng, và 0 controller còn lại sau unmount. Init chậm chỉ bị coi là lỗi tạm thời.
- **Release/packaging** (S2-08) đạt. ELF đã strip, không có media, không có tên file nguồn, không có secret. Bản staging ký bằng debug key đúng như đã công bố.
- **Clip oneshot trong activity** (S2-03) đạt. Qua 200 seed, không lần nào `thinking`/`talking` bị thoát sai.

Tuy vậy, re-audit tìm ra **3 lỗi S2** trong đúng các nhóm mà Phase 5.1 báo là đã sửa. Cả ba đều tái hiện được bằng probe:

1. **S2-R1 (timer stale theo turn):** `tts_wait_timeout` của một turn đã đóng (do `TurnCancelled`, `TtsFailed` hoặc `TurnFailed`) không bị huỷ hay vô hiệu hoá. Khi tới hạn, timer này **huỷ luôn turn kế tiếp**. `ReplyReady` của turn mới bị bỏ: engine không phát `ReleaseTtsGate`, và các event `TtsStarted`/`TtsFinished` của turn đó đều bị bỏ qua.
2. **S2-R2 (TTS/turn deadlock qua background):** reducer bỏ **mọi** event khi `paused`. Theo VOICE_SPEC §8.2, TTS normal vẫn phát tiếp khi app ở nền, nên `TtsFinished` bị mất. Sau khi resume, engine kẹt ở `talking` (hoặc `thinking`) **vĩnh viễn**. Turn tiếp theo bị từ chối và engine không bao giờ mở TTS gate cho nó.
3. **S2-R3 (auto-lock 15 phút không tin cậy):** timer inactivity có thể fire sớm hơn đồng hồ dùng để kiểm tra lại. Khi đó callback không khóa và **không đặt lại timer**. Tỷ lệ fire sớm đo được là 96/300 và 105/300 lần. Private session có thể mở tới 1 giờ (khi authorization hết hạn) thay vì 15 phút.

Hiện chưa lỗi nào làm lộ dữ liệu trong release, vì route private không tồn tại trong release. Nhưng S2-R1 và S2-R2 sẽ lộ ngay khi Phase 6 nối TTS/turn thật. S2-R3 nằm đúng trong lifecycle mà Phase 6 sẽ gắn PIN/session thật vào. Theo tiêu chí, đây là S2 chặn Phase 6.

---

## 2. Tài liệu và mã đã đọc

| Nhóm | Nội dung |
|---|---|
| Docs | PHASE_5_AUDIT, PHASE_5_1_FIX_REPORT, PHASE_5_REPORT, ARCHITECTURE, CHARACTER_SYSTEM (§7, §8.1–§8.5, §13, §14), PRIVACY_SPEC (§5.3–§5.5), ACCEPTANCE_CRITERIA, VOICE_SPEC §8.1–§8.2, PHASE_3_2 patch (delivery) |
| Engine | `character_engine.dart`, `engine_event.dart`, `engine_effect.dart`, `engine_config.dart`, `effect_executor.dart`, `timer_driver.dart`, `clock.dart`, `session_manager.dart` |
| App | `main.dart`, `hana_app.dart`, `build_capabilities.dart`, `providers.dart`, `character_runtime_controller.dart`, `home_screen.dart`, `settings_screen.dart` |
| Private | `private_session.dart`, `private_mode_screen.dart`, `secure_window_coordinator.dart`, `secure_window_service.dart`, `MainActivity.kt` |
| Manifest | `manifest_loader.dart`, `manifest_models.dart`, `manifest_repository.dart`, `assets/character/character_manifest.json`, `tool/sanitize_phase4_manifest.dart` |
| Stage | `video_stage.dart`, `video_controller_port.dart`, `asset_repository.dart` |
| Build | `android/app/build.gradle.kts`, `android/build.gradle.kts`, `gradle.properties`, `proguard-rules.pro`, `key.properties.example`, `.gitignore`, `AndroidManifest.xml`, `tool/build_staging_release.ps1`, `tool/audit_apk.ps1` |
| Tests | 7 file, 89 test |

---

## 3. Lệnh đã chạy

| Lệnh | Kết quả |
|---|---|
| `flutter analyze --no-pub` | **No issues found** |
| `flutter test --no-pub --reporter expanded` | **89/89 PASS** (6+3+16+14+20+21+9 test theo file) |
| `tool/build_staging_release.ps1` (build lại từ đầu, 18:21) | PASS. Kích thước theo ABI: armeabi-v7a 15.199.350 B, arm64-v8a 18.095.640 B, x86_64 19.574.935 B, trùng từng byte với fix report. `subst H:` đã được gỡ sau build. |
| `tool/audit_apk.ps1` × 3 ABI | **APK AUDIT PASS** × 3 (0 video, đã kiểm 43 tên file nguồn, 0 failure) |
| Quét độc lập bằng Python (entry, `.so`, dex, resources, flutter_assets; UTF-8 và UTF-16) + parse section ELF | Xem §7 |
| `apksigner verify --print-certs` (JBR của Android Studio) × 3 | Verifies; v2; `CN=Android Debug`; SHA-256 `67dcdbea…803c1` |
| `aapt2 dump badging` × 3 | `com.hana.hana_app.staging`, `1.0.0-staging`, mỗi APK một ABI, không `debuggable` |
| `flutter build apk --release --flavor production` | **FAIL (đúng kỳ vọng)**: "Production release signing is not configured…" |
| `flutter build appbundle --release --flavor production` | **FAIL (đúng kỳ vọng)**, cùng thông báo |
| `flutter build apk --release` (không flavor) | **FAIL (đúng kỳ vọng)**, cùng thông báo; không sinh artifact mới |
| Probe đối kháng: `reaudit_probe_test.dart`, `reaudit_probe2_test.dart`, `reaudit_widget_probe_test.dart` (16 test) | Chạy trên **bản sao** app trong scratchpad của phiên, **không ghi vào repo**. Mỗi probe PASS khi hành vi được mô tả xuất hiện. Kết quả ở §4–§6. |

Không có file nào trong `repo/` bị sửa, ngoài việc tạo tài liệu này và các artifact staging được build lại trong `build/` (thư mục đã gitignore).

---

## 4. Xác minh từng finding cũ

### 4.1 S1-01 — Cổng private bị bypass trong production

| Hạng mục | Kết quả | Bằng chứng |
|---|---|---|
| Mock private trong production | **ĐÃ SỬA** | `hana_app.dart:29-35`: `/private` và `/character-lab` chỉ được đăng ký khi `developerEnabled`. `build_capabilities.dart:4-6`: `kDebugMode && bool.fromEnvironment(...)` là hằng compile-time. APK release (arm64) **không có**: `Private engine đang hoạt động`, `Demo private reaction`, `Private developer harness`, `debug-session`, `Demo PTT → phản hồi`, `PRIVATE_SESSION_REQUIRED`. Đối chứng dương **có**: `Chat placeholder` (UTF-8), `Tính năng này chưa khả dụng…` và `Chế độ riêng tư chưa khả dụng` (UTF-16). |
| Bypass bằng direct route | **ĐÃ SỬA** | Release có `onUnknownRoute` → `_UnavailableRouteScreen`. Widget test `release-like routes cannot bypass…` đẩy `/private` và `/character-lab` và không mở được. Settings chỉ hiện `private-mode-unavailable`. |
| Chỉ tạo engine sau abstraction unlock | **ĐÃ SỬA** | `CharacterEngineSessionManager.openPrivate` bắt buộc `PrivateSessionAuthorization.isValidAt(now)` (`session_manager.dart:58-66`). Constructor `_` là private của library, nên chỉ unlock service tạo được. `UnavailablePrivateUnlockService` trả `null`. `DevelopmentPrivateUnlockService` trả `null` khi `!kDebugMode`. Mở trùng thì throw. Reference cũ sau khi lock không còn dispatch được (test). |
| Auto-lock private | **MỘT PHẦN** | Background ≥ 60 s → khóa khi resume: đạt (monotonic `SystemClock` = origin + `Stopwatch`; test biên 59/60 s). Overlay khi `inactive`: đạt. Hết hạn authorization: khóa vô điều kiện, đạt. **Inactivity 15 phút: không tin cậy → S2-R3.** |
| Release gating | **ĐÃ SỬA** | Như trên. Chuỗi dev bị tree-shake. Production signing fail closed (§8). |
| Dispose engine khi khóa; normal về idle | **ĐÃ SỬA** | `lockPrivate` dispose private session, xoá `prv_rt` (native), pop route, set normal `idle`/`daily`, rồi khôi phục FLAG_SECURE theo Home. Probe P3 với channel chậm 2 s: `clearPrivateRuntime` rồi `setSecure{enabled: true}` (policy `auto`), không có exception. Chưa có `VideoPlayerController` private nào để dispose. |

**Kết luận S1: 0 S1 còn lại.**

### 4.2 Các finding S2

| # (yêu cầu) | Finding cũ | Trạng thái | Bằng chứng / ghi chú |
|---|---|---|---|
| 1 | S2-01 event stale/sai thứ tự | **MỘT PHẦN → S2-R1** | Đạt: `ClipEnded`/`ClipError` stale (so `playId` + `assetId`), `ReplyReady` của turn đã huỷ, `TtsFinished` sau barge-in, `JobFinished` không ngắt `talking` (có theo dõi `activeJobIds`), `CueReceived` bị bỏ khi `listening`, tick có token. **Còn lỗi:** token timer chỉ gắn theo *tag*, không theo *turn*. `tts_wait_timeout` của turn đã đóng vẫn hợp lệ và huỷ turn mới. |
| 2 | S2-02 effect runtime + timer | **MỘT PHẦN → S2-R2** | Đạt: `EngineEffectExecutor` thực thi đủ 9 loại effect. `SystemTimerDriver`/`FakeTimerDriver` hoạt động. `sleep` đạt tới qua timer thật (probe E3). `context_hold` trả về `daily` sau 90 s (probe P9). `thinking_min_dwell`, `pre_speech_max`, `overlay_min/max`, `working_max` và `retry_asset` đều có. **Còn lỗi:** event bị bỏ khi `paused`, và timer turn đã huỷ lúc pause không được đặt lại khi resume. |
| 3 | Deadlock reaction/TTS | **Reaction: ĐÃ SỬA. TTS: CHƯA → S2-R2** | Reaction loop luôn thoát nhờ `overlay_max` (0/200 seed bị kẹt qua runtime timer; test 100 seed). Timeout reaction tất định: `clamp(duration, 1500, 4000)`. Pre-speech mở gate qua `ClipEnded`+`overlay_min` hoặc `overlay_max`. Deadlock `talking`/`thinking` qua background vẫn còn. |
| 4 | S2-04 validator ràng buộc chéo | **ĐÃ SỬA** | `manifest_loader.dart`: whitelist field (root/asset/cue), denylist field cấm, `schema_version==2`, kind ∈ allowedKinds, `path/poster/poster_blur == '<prefix>/<asset_id><suffix>'` với prefix suy từ `delivery`, `audio_streams==0` (cùng subtitle/data/attached_picture), `delivery_class==delivery`, bảng kind↔delivery↔sensitivity↔modes, enum phân biệt hoa/thường, ID tuần tự, giới hạn kích thước/thời lượng/sha256. Test ma trận: path ngoại lai, sai prefix, sai kind (`master`), bundle+private, private_vault ngoài `[private]`, streams ≠ 0, field cấm hoặc lạ, `PRIVATE`, `delivery_class`, đổi đuôi. Resolver cũng tự loại asset có `audio_streams≠0` (test). |
| 5 | S2-05 runtime dùng manifest Phase 4 thật | **ĐÃ SỬA** | `main.dart` → `BundledPhase4ManifestRepository.load()` (không throw). So sánh độc lập bằng Python giữa `assets/character/character_manifest.json` (44.053 B) và `assets_processed/hana/character_manifest.json`: **0 khác biệt** trên 43 asset × 29 field runtime. Sanitizer bỏ 9 field không dùng (`semantic_tags`, `fps`, …) và đổi `manifest_kind` `master`→`vault`, kèm guard "43 asset, tất cả `delivery=vault`". Thành phần: 17 suggestive `[daily, assistant, relationship, private]` và 26 private `[relationship, private]`, đều `vault`, đúng bảng suy delivery của patch 3.2. Manifest invalid → `CharacterManifest.empty()` → silhouette, chat vẫn chạy (widget test). `DemoManifestFactory` không còn được tham chiếu (tree-shaken). |
| 6 | S2-06 giới hạn controller / init chậm | **ĐÃ SỬA** | `video_stage.dart:91-265`: huỷ controller in-flight khi generation đổi, đuổi slot inactive trước khi cấp controller mới, cắt clip cũ khi asset đổi, set `_disposed` chống dispose trùng, chỉ phát `ClipError` khi generation còn hiện hành và widget còn mounted. Probe V1 (4 asset) và V1b (1 asset, crossfade 250 ms, init 0–600 ms, timeout 400 ms, 300 Play mỗi probe): **maxLive = 2, doubleDispose = 0, live = 0 sau unmount**. Timeout → `ClipError(isPermanent:false)` → `transientAssetIds` + `retry_asset` 5 s, không đưa vào `brokenAssetIds`. Lỗi cứng mới vào quarantine. |
| 7 | S2-07 FLAG_SECURE / private lifecycle | **FLAG_SECURE: ĐÃ SỬA. Lifecycle: xem S2-R3, S3-R1, S3-R2** | `SecureWindowCoordinator`: Home theo `auto|always|off` (`auto` = có asset không phải `normal` đang bật). Private luôn bật, không phụ thuộc owner. Khi khóa thì khôi phục đúng policy Home (test `[true,false]`/`[true,true]`). `MainActivity` mặc định `enabled=true` khi thiếu tham số và xoá `prv_rt` trong `onCreate` và khi khóa. Overlay khi `inactive` có ở cả Home (khi asset nhạy cảm) và private. |
| 8 | S2-08 packaging/signing | **ĐÃ SỬA** | §7–§8. |

---

## 5. Findings còn mở

### S2-R1 — Timer `tts_wait_timeout` của turn đã đóng huỷ turn tiếp theo

- **Vi phạm:** CHARACTER_SYSTEM §8.3 ("`TtsStarted/Finished` với `turn_id` khác turn hiện tại → bỏ qua"; timer phải gắn với turn đã đặt nó); §14 (`tts_wait_timeout` "coi như `TtsFailed`" **của turn đó**). Đây là yêu cầu "stale timer ignored" và "cancelled turn" của re-audit.
- **Bằng chứng** (`lib/character/engine/character_engine.dart`)
  - `:236-237`: `ReplyReady(will_speak)` đặt `tts_wait_timeout` (8 s).
  - `:129-137` (`TtsFailed`), `:138-147` (`TurnFailed`), `:148-154` (`TurnCancelled`): đóng turn nhưng **không** phát `CancelTick('tts_wait_timeout')` và không tăng token. `TurnSubmitted` → `_thinking` (`:362-369`) cũng không làm việc đó.
  - `:337-342`: khi tick tới, chỉ kiểm `currentTurnId != null && activity != talking`, không kiểm turn nào đã đặt timer. Token (`:436-443`) tính theo tag, và turn mới không đặt lại tag này trước `ReplyReady`.
- **Tái hiện** (probe E1, qua `CharacterRuntimeController` + `FakeTimerDriver`, tức cả executor lẫn timer thật):
  - `TurnSubmitted(A)` → +600 ms → `ReplyReady(A, neutral, will_speak)` (gate mở, deadline 8,6 s) → `TurnCancelled(A)` → `TurnSubmitted(B)` → +8 s.
  - Kết quả: `activity=idle turn=null`, tức **B bị huỷ**. Sau đó `ReplyReady(B)` bị bỏ và **không có `ReleaseTtsGate`**. Audio của B chỉ phát được nhờ timeout gate 1.500 ms phía player (VOICE_SPEC §8.1 bước 3). Khi đó engine bỏ qua `TtsStarted(B)`/`TtsFinished(B)`, nên stage đứng `idle` trong lúc Hana nói và reaction/afterglow của B bị mất.
  - Kết quả giống hệt khi A đóng bằng `TtsFailed(A)` hoặc `TurnFailed(A)` (sau khi overlay concerned thoát).
- **Tác động:** trong tình huống bình thường (người dùng huỷ rồi hỏi lại, hoặc TTS lỗi rồi gửi tiếp trong vòng 8 s), turn mới bị huỷ ở phía engine. Stage và audio lệch nhau, cue của câu trả lời bị mất, và pre-speech reaction không chạy. Lỗi sẽ lộ ngay khi Phase 6 nối SSE/TTS thật.
- **Hướng sửa:** gắn timer theo turn (lưu `turnId` kèm token, hoặc tăng token mọi tag thuộc turn khi turn đóng hoặc mở). Mọi nhánh đóng turn (`TtsFailed`, `TurnFailed`, `TurnCancelled`, `TtsFinished`, `tts_wait_timeout`) và `TurnSubmitted` phải huỷ `tts_wait_timeout`, `pre_speech_max`, `thinking_min_dwell` và `thinking_variant_rotate` cũ. Thêm test hồi quy theo đúng chuỗi E1 cho cả 3 cách đóng turn.

### S2-R2 — Event bị bỏ khi `paused` → deadlock `talking`/`thinking`, engine không nhận turn sau

- **Vi phạm:** CHARACTER_SYSTEM §8.3 (`AppPaused`: "giữ state; pause controllers; huỷ tick trừ `idle_to_sleep`", **không** nói bỏ event); VOICE_SPEC §8.2 ("App background → tiếp tục phát normal (như app nghe)"); §14 (`tts_wait_timeout`); yêu cầu "reaction/TTS deadlock" của audit trước.
- **Bằng chứng**
  - `character_engine.dart:58`: `if (state.paused) return EngineResult(state, const [])`. Mọi event (`TtsStarted`, `TtsFinished`, `TtsFailed`, `ReplyReady`, `TurnFailed`, `JobFinished`, …) đến trong lúc pause đều bị bỏ, không được xếp hàng.
  - `:19-25`: `AppPaused` huỷ `tts_wait_timeout` (qua `_cancelActivityTimers`). `:27-57`: `AppResumed` với `talking` chỉ `_show(talking)`, còn với `thinking` chỉ đặt lại `thinking_variant_rotate`. **Không** đặt lại `tts_wait_timeout` và không có watchdog nào cho `talking`.
  - `:89-96`: `TurnSubmitted` không được nhận khi `talking`, hoặc khi `thinking` mà `currentTurnId != null`.
  - `home_screen.dart:57-61` phát `AppPaused` ngay khi app vào `paused`.
  - Test `phase5_1_regression_test.dart:231` ("paused normal engine ignores events") **khẳng định** hành vi này là đúng.
- **Tái hiện** (probe E2, runtime + timer)
  - E2a: turn A → `TtsStarted(A)` (talking) → `AppPaused` → `TtsFinished(A)` (TTS phát hết ở nền) → `AppResumed` → +2 giờ ⇒ `activity=talking turn=A`. Sau đó `TurnSubmitted(B)` + `ReplyReady(B)` ⇒ vẫn `talking`, **`gate=false`**.
  - E2b: `ReplyReady(A)` (gate đã mở) → `AppPaused` → `TtsStarted(A)`, `TtsFinished(A)` → `AppResumed` → +2 giờ ⇒ `activity=thinking turn=A`, timer chỉ còn `{thinking_variant_rotate}`. `TurnSubmitted(B)` bị từ chối.
  - Lối thoát duy nhất là người dùng nhấn PTT. Với chat bằng text, nhân vật kẹt vĩnh viễn: mọi câu trả lời sau đó bị engine bỏ qua (không cue, không reaction, không mở gate). Audio chỉ phát nhờ timeout gate 1.500 ms của player, trong khi stage vẫn đứng `talking` hoặc `thinking`.
- **Tác động:** kịch bản phổ biến nhất của app nghe nói (chuyển app khi Hana đang nói, hoặc gửi tin rồi rời app) làm state machine hỏng vĩnh viễn trong cả phiên, và stage lệch hẳn khỏi audio. Lỗi chặn Phase 6.
- **Hướng sửa:** khi `paused`, vẫn xử lý event turn/TTS/job cho state logic, chỉ hoãn `Play` hoặc để stage tự bỏ qua khi đang pause. Hoặc xếp hàng rồi replay khi resume. Khi resume, đặt lại các timer turn còn hiệu lực (`tts_wait_timeout`) và thêm watchdog cho `talking` (ví dụ đối chiếu trạng thái `TtsQueue` hoặc giới hạn tối đa). Sửa test dòng 231 để kiểm đúng hành vi mới. Thêm test E2a/E2b.

### S2-R3 — Auto-lock khi không tương tác 15 phút có thể không bao giờ kích hoạt

- **Vi phạm:** PRIVACY_SPEC §5.4 ("Không tương tác 15 phút → khóa"); yêu cầu "15m inactivity auto-lock" của re-audit.
- **Bằng chứng**
  - `private_mode_screen.dart:59-67`: timer `private_inactivity` được đặt tại `now + 15 phút`. Callback chỉ khóa khi `_autoLock.inactivityReason() != null`, tức `clock.now() - last >= 15 phút` đo bằng µs qua `Stopwatch`. Nếu điều kiện chưa đạt thì **không làm gì và không đặt lại timer**.
  - `timer_driver.dart:90-96`: `Timer(at - now)`. Dart `Timer` làm tròn xuống theo mili-giây và lập lịch trên đồng hồ ms của VM, nên callback có thể chạy sớm hơn `at` tới dưới 1 ms theo đồng hồ µs.
  - Test hiện có chỉ kiểm `PrivateAutoLockPolicy` với `FakeClock` (biên 14:59/15:00). `PrivateModeScreen` hard-code `SystemClock`, `SystemTimerDriver` và `DevelopmentPrivateUnlockService`, nên không inject được để test ở mức widget.
- **Tái hiện** (probe T1, dùng đúng `SystemTimerDriver` + `SystemClock` và đúng pattern "đặt `now+limit`, callback kiểm lại `now-last >= limit`"): callback fire khi điều kiện **chưa** đạt ở **96/300** và **105/300** lần (hai lần chạy). Cơ chế này không phụ thuộc độ dài giới hạn, nên áp dụng nguyên cho 15 phút.
- **Tác động:** khoảng 1/3 phiên private có thể không bao giờ tự khóa vì không tương tác. Lúc đó phiên chỉ khóa khi app vào nền ≥ 60 s, khi người dùng bấm khóa, hoặc khi authorization hết hạn sau **1 giờ**. Hiện **không** khai thác được trong release, vì route private không tồn tại và unlock service không khả dụng, nên đây không phải S1. Nhưng đây là lifecycle mà Phase 6 sẽ gắn PIN/session server vào.
- **Hướng sửa:** khi timer inactivity riêng tới hạn thì khóa vô điều kiện (mọi tương tác đều đặt lại timer), hoặc đặt lại timer cho phần thời gian còn thiếu khi kiểm tra thất bại. Inject `Clock`, `TimerDriver` và `PrivateUnlockService` vào `PrivateModeScreen`, rồi thêm widget test 14:59/15:00 và background 59/60 s qua lifecycle thật.

### S3 (không chặn riêng lẻ; nên sửa trước hoặc trong Phase 6)

| ID | Vấn đề | Bằng chứng | Đề xuất |
|---|---|---|---|
| S3-R1 | Effect của private engine không bao giờ được thực thi (không có executor hay timer). Reaction private kẹt, TTS gate private không bao giờ mở. | `private_mode_screen.dart:172-180` gọi `private.dispatch` rồi bỏ `effects`. Probe P2: `shy` vẫn còn sau 60 s. Hiện chỉ có trong harness debug. | Gắn executor, timer và lifecycle riêng cho private session trước khi nối private vault/TTS. |
| S3-R2 | Normal engine được resume trong lúc private đang mở, trái CHARACTER_SYSTEM §13 bước 4. | `HomeScreen` vẫn là observer lifecycle dưới route private, nên sau pause/resume thì `runtime.state.paused=false` và `PttPressed` đưa normal engine sang `listening` (probe P1). Không có dữ liệu private nào đi sang normal. | Runtime giữ cờ "private đang mở" và bỏ qua `AppResumed`/input của normal cho tới khi khóa. |
| S3-R3 | Thiếu `TtsStoppedByUser` (§7.2, §8.2). "Gửi text mới" khi đang `talking` (VOICE_SPEC §8.2 `stopAll`) không có event nào đưa engine rời `talking`, vì `TurnSubmitted` không nhận ở `talking`. Bảng §8.3 cũng không liệt kê trường hợp này. | `engine_event.dart`, `character_engine.dart:512-516` | Chốt hợp đồng TtsQueue ↔ engine ở Phase 6 (event dừng TTS, `TurnSubmitted` từ `talking`). |
| S3-R4 | Test gap: (a) test `paused…ignores events` khẳng định đúng lỗi S2-R2; (b) không có test cho timer của turn đã đóng; (c) không có widget test cho auto-lock; (d) test `developerSurfacesFor` kiểm một helper chứ không kiểm hằng `BuildCapabilities.developerSurfaces` thực sự dùng (quét APK bù lại); (e) test "50 rapid Play" không bao giờ cho init hoàn tất; (f) S2-03 không có test hồi quy riêng (probe xác nhận đã sửa: 200 lần `thinking` oneshot, 35 lần `talking` oneshot, 0 sai). | `test/*` | Chuyển các probe E1, E2, T1, V1, R1/R2 thành test hồi quy. |
| S3-R5 | Gate release chưa tự động hoá đủ: `audit_apk.ps1` không kiểm section ELF, chứng chỉ ký, ngưỡng kích thước hay `debuggable` (fix report làm tay bằng `llvm-readelf`/`apksigner`; re-audit tự kiểm lại và đạt). `build/app/outputs/flutter-apk/` còn **`app-release.apk` trước bản sửa** (178.184.695 B, chưa strip, ký debug key, chứa mock private) và `app-debug.apk` 455 MB, có nguy cơ bị phát tán nhầm. | §7 | Bổ sung các kiểm tra trên vào auditor/CI. Xoá artifact cũ, vì owner quyết định việc dọn `build/`. |
| S3-R6 | VideoStage: timeout init cố định 1,5 s, nên trên máy yếu sẽ lặp lại chu kỳ poster ↔ thử lại mỗi 5 s. `PlatformException` do cạn codec bị coi là lỗi cứng. Controller mới vẫn `play()` dù stage đang `paused`. `PolicyUpdated` và mọi `AppResumed` luôn chọn lại clip, kể cả khi clip hiện tại vẫn eligible (spec §8.3: chỉ chọn lại khi không còn eligible). | `video_stage.dart:155-225`, `character_engine.dart:42-63` | Backoff hoặc timeout thích ứng; phân loại lỗi codec; tôn trọng `paused` khi init. |
| S3-R7 | Harness private: `_lock` chỉ `Navigator.pop` route trên cùng thay vì pop toàn bộ `/private/**` (§5.4 bước 1). `dispose()` không khôi phục FLAG_SECURE (lệch về phía an toàn). | `private_mode_screen.dart:90-115` | Dùng `popUntil` về route normal khi dựng private thật. |
| S3-R8 | Các S3 còn lại từ audit trước theo fix report (S3-02 đến S3-06, S3-08) chưa đóng. Sink mặc định của `LogEngine` là `debugPrint`, vẫn in trong release, nhưng chỉ có mã lỗi, không có asset id. | `PHASE_5_1_FIX_REPORT.md` | Theo kế hoạch. |

---

## 6. Ma trận required checks

| # | Kiểm tra | Kết quả |
|---|---|---|
| 1 | `flutter analyze` / `flutter test` | ✔ No issues / 89/89 |
| 2 | 89 test có cover defect cũ không | ✔ phần lớn (§4, §9); ✘ không cover S2-R1/R2/R3 và có một test khẳng định S2-R2 (S3-R4) |
| 3 | Build staging theo ABI | ✔ 3 APK, trùng từng byte với fix report |
| 4 | Audit APK: không video production, không tên/path nguồn, không `source_asset_map`, không mock unlock, không Character Lab, không secret, ELF đã strip, ký staging | ✔ tất cả (§7) |
| 5 | Production fail closed, không fallback sang debug key | ✔ APK, AAB và build không flavor đều fail. Flavor `production` chỉ gán signingConfig khi có `key.properties`; nếu thiếu thì `taskGraph.whenReady` throw. |
| 6 | Private: route guard / tạo engine sau unlock / 60 s background / 15 phút inactivity / dispose khi khóa / normal về idle | ✔ / ✔ / ✔ / **✘ S2-R3** / ✔ (chưa có controller private) / ✔ |
| 7 | Engine: ClipEnded/ClipError stale / turn đã huỷ không `ReplyReady` / `TtsFinished` sau barge-in / `JobFinished` / **timer stale** / sleep / timeout reaction | ✔ / ✔ (cùng turn) / ✔ / ✔ / **✘ S2-R1** (token theo tag đạt, theo turn không đạt) / ✔ / ✔. Thêm **✘ S2-R2** (deadlock qua pause). |
| 8 | Manifest: schema thật / `audio_streams≠0` / path ngoại lai / `manifest_kind` sai / fail closed | ✔ / ✔ / ✔ / ✔ / ✔ |
| 9 | VideoStage: giới hạn cứng khi stress / dispose orphan / init chậm không thành broken | ✔ / ✔ / ✔ |

---

## 7. Audit APK staging (build lại 2026-09-16 18:21)

| Kiểm tra | armeabi-v7a | arm64-v8a | x86_64 |
|---|---|---|---|
| Kích thước | 15.199.350 B | 18.095.640 B | 19.574.935 B |
| Entry | 66 | 66 | 66 |
| Media (mp4/mov/mkv/webm/jpg/gif/webp ngoài `res/`) | 0 | 0 | 0 |
| `flutter_assets` | font, shader, NOTICES, `character_manifest.json` (metadata 44.053 B) | như trên | như trên |
| 43 tên file nguồn (entry + nội dung, UTF-8/UTF-16) | 0 | 0 | 0 |
| `source_asset_map` / `assets_source` / `assets_processed` | 0 | 0 | 0 |
| `Downloads/Hana`, `Users/Administrator`, `HANA_DEV_VAULT_ROOT` | 0 | 0 | 0 |
| URI plugin registrant | `file:///H:/.dart_tool/...` (ổ trung tính, không có đường dẫn người dùng) | như trên | như trên |
| Chuỗi mock private, Character Lab, `debug-session`, `DemoManifestFactory`, `phase5-demo`, `per-clip-policy-mock` | 0 | 0 | 0 |
| `keyPassword`, `storePassword`, `BEGIN PRIVATE KEY`/`RSA`, `Bearer ` | 0 | 0 | 0 |
| Hit vô hại | `source_file`/`hard_block` (denylist của validator), `chr_003` (mẫu Settings), `prv_rt` (dex: MainActivity xoá cache), `/private` (chỉ trong đường dẫn nguồn Skia/libc++ của `libflutter.so`), `sk-` (chuỗi con thư viện) | như trên | như trên |
| Section `.debug*` / `.symtab` / `.strtab` (`libapp`, `libflutter`, `libsqlite3`) | không có | không có | không có |
| ABI | chỉ armeabi-v7a | chỉ arm64-v8a | chỉ x86_64 |
| `debuggable` | không | không | không |
| Ký | v2, `CN=Android Debug` (staging, đúng như công bố) | như trên | như trên |
| Package | `com.hana.hana_app.staging` / `1.0.0-staging` | như trên | như trên |

Secret trong repo: chỉ có `key.properties.example` (placeholder), `build.gradle.kts` (tên thuộc tính) và `audit_apk.ps1` (chuỗi cần tìm). Không có `key.properties`, `*.jks` hay `*.keystore`. `local.properties` chỉ chứa đường dẫn SDK và đã được gitignore.

## 8. Signing

- `productionRelease`, `bundleProductionRelease` và `assembleRelease` (không flavor) đều fail với thông báo rõ ràng. Không có bản production nào được ký bằng debug key.
- `staging` ký debug có chủ đích, dùng applicationId và versionName riêng. Không được phát hành như production.
- Nếu có `key.properties` nhưng thiếu field, AGP sẽ fail khi validate signing (vẫn fail closed). Chưa kiểm trên keystore thật vì owner chưa cung cấp.

## 9. Mức cover của 89 test đối với defect cũ

| Defect cũ (probe) | Test hồi quy |
|---|---|
| A1 direct route / mock trong release | `app_widget_test` release-like route + quét APK |
| A2/A3 FLAG_SECURE | `FLAG_SECURE private lifecycle restores exact home policy` |
| A4 paused 20 phút | Chỉ ở mức policy (59/60 s). Không có ở mức widget (S3-R4). |
| A5 reference cũ sau khi lock | `lock destroys private engine…` |
| P1 `ClipEnded` stale, `ClipError` stale | `stale ClipEnded and ClipError…` |
| P2 `TtsFinished` sau barge-in | `TtsFinished after barge-in…` |
| P3 `ReplyReady` sau `TurnCancelled` | `cancelled turn ignores late ReplyReady` |
| P4 `JobFinished` khi `talking` | `JobFinished cannot interrupt talking…` |
| P6 tick stale | `stale timer token is ignored` (theo tag; **không** cover theo turn → S2-R1) |
| P7 `sleep` | `quiet/day sleep deadlines…`; test 10 state |
| P8 RNG thuần | `same state/event replays…` |
| R1/R2 oneshot kết thúc activity | Không có test riêng; probe re-audit xác nhận đã sửa |
| R3 reaction loop kẹt | `reaction loop always exits…` (100 seed) |
| M1–M8 validator | Nhóm `Phase 5.1 cross-field validation` |
| M6 resolver với audio | `audio_streams defense…` |
| M11 manifest invalid → silhouette | `manifest validation failure keeps chat shell…` |
| Demo khác canonical | `canonical Phase 4 master yields the identical…` |
| V1 controller tràn | `50 rapid Play requests…` (init không hoàn tất; probe re-audit cover phần còn lại) |
| V2 timeout → broken | `initialization timeout is reported as transient`, `slow initialization does not permanently corrupt asset` |
| S2-08 symbols/signing | Không có test tự động; kiểm bằng script và thủ công (S3-R5) |

---

## 10. Phase 6 readiness

**CHƯA SẴN SÀNG.** Điều kiện tối thiểu trước khi bắt đầu Phase 6:

1. **S2-R1:** timer gắn theo turn. Mọi nhánh đóng hoặc mở turn đều huỷ hay vô hiệu hoá timer của turn cũ. Có test E1 cho 3 cách đóng turn.
2. **S2-R2:** event turn/TTS/job không bị mất khi `paused`. Timer turn được đặt lại khi resume, và có watchdog cho `talking`. Sửa test "paused…ignores events" và thêm test E2a/E2b.
3. **S2-R3:** auto-lock 15 phút tất định (khóa vô điều kiện khi timer riêng tới hạn, hoặc đặt lại timer). Private screen inject được clock, timer và unlock service. Có widget test cho biên 15 phút và 60 s.
4. Nên làm cùng lúc: S3-R1 và S3-R2 (executor và lifecycle cho private session, normal engine giữ pause trong lúc private mở), S3-R5 (ELF, ký và kích thước trong auditor; xoá `app-release.apk`/`app-debug.apk` cũ).

Giữ nguyên các phần đã đạt: route gating theo hằng compile-time, `PrivateSessionAuthorization`, fail-closed signing, validator manifest, snapshot manifest Phase 4 cùng sanitizer có guard, VideoStage generation/in-flight, `SecureWindowCoordinator`.

---

**PHASE 5 RE-AUDIT — FAIL**

Lý do: 0 S1 nhưng còn **3 S2** (S2-R1 timer stale theo turn huỷ turn kế tiếp; S2-R2 deadlock `talking`/`thinking` qua background, engine từ chối các turn sau; S2-R3 auto-lock 15 phút không tin cậy). Không có media, tên nguồn, mock private hay secret nào trong APK. Production signing fail closed.

Chưa đạt điều kiện "READY FOR PHASE 6".

STOP. Không sửa code. Không làm Phase 6.
