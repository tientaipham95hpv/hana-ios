# HANA PHASE 5 AUDIT — CHARACTER ENGINE / MODE POLICY / FLUTTER

Ngày review: 2026-09-16 · Vai trò: senior architecture/security reviewer · Phạm vi: `repo/app` (Phase 5), đối chiếu với canonical docs v1.2.

**KẾT LUẬN: PHASE 5 REVIEW — FAIL** (1 S1, 8 S2, 9 S3)

---

## 1. Executive summary

Phần lõi chính sách asset của Phase 5 **đúng ở những điểm quan trọng nhất**:

- APK không chứa video, không chứa tên file nguồn và không có `source_asset_map`.
- Normal engine không bao giờ chọn context `private`.
- Relationship bị chặn khi owner tắt.
- Fallback không vượt `allowed_modes`.
- Daily/assistant luôn ở tier sensitivity thấp nhất. Property test 10.000 bước trên manifest Phase 4 thật không tìm ra vi phạm.
- Không có API nào cho LLM/backend gửi `asset_id`/path/filename vào quá trình chọn asset.
- Video luôn `setVolume(0)` trước `play()`.
- Character Lab không có trong bản release.

Tuy vậy, Phase 5 **chưa an toàn để nối backend/AI**:

1. **S1: cổng private bị bypass trong bản production.** Route `/private` và mục "Mở private session (mock)" trong Settings có trong APK release (đã xác minh bằng chuỗi trong `libapp.so`). Không có guard, không có abstraction unlock/`PrivateSession`, không có trigger khóa. Engine private được tạo với `privateSessionActive=true` chỉ bằng một lần điều hướng. Điều này vi phạm INV-07 và PRIVACY_SPEC §5.2/§5.5. Hiện chưa có media private được render, nhưng nếu Phase 6 nối vault vào màn này thì đây sẽ thành đường lộ nội dung trực tiếp.
2. **Reducer không kiểm tra state hiện tại** (S2). Event cũ, trùng hoặc sai thứ tự làm state nhảy sai, ví dụ `ClipEnded` cũ đẩy `listening` về `idle`, hoặc `TtsFinished` của turn đã bị barge-in. Các effect (`ScheduleTick`, `ReleaseTtsGate`, `StopTts`, …) **không có bộ thực thi**. Mọi timer trong spec §8.4 đều chưa có, nên `sleep` không bao giờ đạt tới, reaction dùng clip loop bị kẹt, và `thinking` không có timeout.
3. **Manifest boundary chưa được nối vào runtime** (S2). App dùng `DemoManifestFactory` hard-code, khác manifest Phase 4 ở 9 state map, 8 quality/weight và 12 kích thước. Validator thiếu toàn bộ ràng buộc chéo §4.4, gồm prefix↔delivery, path↔asset_id, `manifest_kind`, bundle⇒normal và `audio_streams==0`.
4. **Kích thước APK là lỗi cấu hình, không phải do build debug** (S2). `packaging.jniLibs.keepDebugSymbols += "**/*.so"` áp dụng cho **mọi** build type. APK release x86_64 vẫn **169,9 MB**, trong đó 148 MB là section `.debug*` của `libflutter.so`. Bản release còn được ký bằng debug key.

Mọi S1/S2 đều có hướng sửa rõ ràng và khối lượng vừa phải. Sau khi sửa S1 (và tốt nhất cả S2), Phase 5 có thể được review lại để đạt CONDITIONAL PASS hoặc PASS.

---

## 2. Reviewed files / modules

| Nhóm | File |
|---|---|
| Engine | `lib/character/engine/{character_engine,engine_state,engine_event,engine_effect,character_cue,clock,session_manager}.dart` |
| Resolver/Policy | `lib/character/resolver/{asset_resolver,random_source}.dart`, `lib/character/policy/owner_policy.dart` |
| Manifest | `lib/character/manifest/{manifest_loader,manifest_models}.dart`, `lib/app/demo_manifest.dart` |
| Stage/Vault | `lib/character/stage/{video_stage,video_controller_port,asset_repository}.dart` |
| App/UI | `lib/main.dart`, `lib/app/{hana_app,providers,character_runtime_controller}.dart`, `lib/chat/home_screen.dart`, `lib/settings/settings_screen.dart`, `lib/private_mode/private_mode_screen.dart`, `lib/character/lab/character_lab_screen.dart` |
| Scaffold | `lib/core/*`, `lib/voice/tts_audio.dart`, các module placeholder |
| Android | `android/app/build.gradle.kts`, `android/build.gradle.kts`, `android/gradle.properties`, `AndroidManifest.xml` (main/debug), `MainActivity.kt` |
| Tests | `test/*.dart` (6 file + fixture) |
| Data | `assets_processed/hana/character_manifest.json`, `source_asset_map.json` (chỉ lấy danh sách tên để quét APK), `assets_source/` (chỉ liệt kê tên) |
| Docs | ARCHITECTURE (§0.1, §13 INV), CHARACTER_SYSTEM (§4.4, §8–§17), PRIVACY_SPEC (§2, §4.1, §5.2–§5.5), PHASE_3_2 patch, PHASE_4_REPORT, PHASE_5_REPORT |

---

## 3. Commands run

| Lệnh | Kết quả |
|---|---|
| `flutter test --no-pub --reporter expanded` (trong `repo/app`) | **53/53 PASS** |
| `flutter analyze --no-pub` | **No issues found** |
| `flutter build apk --release --target-platform android-x64 --no-pub` | PASS: `build/app/outputs/flutter-apk/app-release.apk` **178.184.695 byte** (169,9 MB), sha256 `994e84d4…63b5`. Đây là artifact build mới, không sửa source. |
| Python `zipfile` + ELF section parse trên `app-debug.apk` và `app-release.apk` | Xem §4 (S2-08) và §7 |
| Quét chuỗi APK: 43 stem tên file nguồn, `source_asset_map`, `assets_source`, `assets_processed`, `HANA_DEV_VAULT_ROOT`, `Downloads/Hana`, `secret`, `Bearer`, route/UI strings (UTF-8 và UTF-16) | Xem §7 |
| Diff `DemoManifestFactory` ↔ `assets_processed/hana/character_manifest.json` | Khác nhau: states 9, technical_quality 8, weight 8, width/height 12 |
| **Probe test đối kháng** `phase5_audit_probe_test.dart` (33 test), chạy trên **bản sao** app trong scratchpad của phiên (`…/scratchpad/probe_app/`), không ghi vào repo | **33/33 tái hiện được**. Mỗi probe PASS khi defect xuất hiện, trừ R4 và M10 là đối chứng dương. Output đáng chú ý: `R2 talking oneshot picks: 29/200`, `R3 shy loop picks: 73/200`, `V1 live controllers: 10` |

Không có file nào trong `repo/` bị sửa, ngoài việc tạo tài liệu này và artifact `app-release.apk` trong `build/` (thư mục đã gitignore).

---

## 4. Findings

### S1-01 — Cổng private bị bypass trong bản production (mock shortcut được ship)

- **Vi phạm:** INV-07; PRIVACY_SPEC §5.2 (PIN do server xác minh), §5.3 (session token trong RAM), §5.4 (trigger khóa), §5.5 (route guard `/private/**`); CHARACTER_SYSTEM §13.
- **Bằng chứng**
  - `lib/app/hana_app.dart:26`: `'/private': (_) => const PrivateModeScreen()` được đăng ký **vô điều kiện**. Chỉ `/character-lab` được gate bằng `kDebugMode`.
  - `lib/settings/settings_screen.dart:76-82`: mục `private-mode-entry` "Mở private session (mock)" gọi thẳng `Navigator.pushNamed('/private')`.
  - `lib/private_mode/private_mode_screen.dart:27-30`: `CharacterEngineSessionManager(...)..openPrivate(manifest, policy)` chạy ngay trong `initState`, không có token hay credential nào.
  - `lib/character/engine/session_manager.dart:40-47`: `openPrivate` là API public, không nhận bằng chứng unlock. Gọi lại sẽ âm thầm thay session cũ. `lockPrivate` chỉ gán `_private = null`, và reference cũ vẫn dispatch được với `privateSessionActive=true` (probe A5).
  - **APK release:** `libapp.so` chứa chuỗi UTF-16 `"private session (mock)"` (1 lần), `"Demo PTT"` (1 lần) và `/private` (5 lần). Mock flow có trong bản production.
  - Không có trigger khóa: không khóa khi `paused ≥ 60 s`, không khóa sau 15 phút idle, không có overlay khi `inactive` (probe A4: paused 20 phút, resume, màn private vẫn mở).
  - Private flow **không nối với normal engine thật**: `PrivateModeScreen` tạo một `CharacterEngineSessionManager` riêng (kèm một normal session thừa). Normal engine của Home không bị pause (§13 bước 4), và bước "lock → normal idle" không tác động lên engine của Home.
- **Tái hiện**
  1. Build release, mở app, vào Cài đặt, chọn "Mở private session (mock)". Màn hiển thị "Context: private".
  2. Probe A1: `Navigator.pushNamed('/private')` từ bất kỳ đâu → `find.text('Context: private')`.
- **Tác động hiện tại:** chưa có media hoặc dữ liệu private được render, nên chưa lộ nội dung. Tuy nhiên đây đúng là tiêu chí S1 "production bypass private gate": nếu Phase 6 gắn VideoStage, vault hoặc private manifest vào màn này, nội dung sẽ lộ mà không cần PIN.
- **Hướng sửa**
  1. Gỡ route `/private` và mục Settings mock khỏi bản non-debug. Gate chúng bằng `kDebugMode` hoặc một flavor `dev` riêng, và thêm test đảm bảo release không có chuỗi mock.
  2. Tạo abstraction `PrivateUnlockService` → `PrivateSession` (token chỉ trong RAM, có hạn). `openPrivate(PrivateSession)` phải bắt buộc nhận session hợp lệ, và route guard phải kiểm tra session.
  3. Tạo `PrivateLockCoordinator` idempotent theo đúng 7 bước §5.4, gồm dispose engine/controllers, wipe `prv_rt`, rồi mới tắt FLAG_SECURE. Nối trigger `paused≥60s` (đo bằng monotonic clock), idle 15 phút và lỗi `PRIVATE_SESSION_*`.
  4. Dùng một `CharacterEngineSessionManager` duy nhất cho toàn app: normal engine pause khi private mở và tiếp tục ở `idle`/`daily` sau khi khóa.
- **Release impact:** chặn release và chặn việc nối backend private.

---

### S2-01 — Reducer không kiểm tra state hiện tại: event cũ/sai thứ tự làm sai state machine

- **Vi phạm:** CHARACTER_SYSTEM §8.3 ("Event không có trong bảng cho state hiện tại → bỏ qua") và thứ tự ưu tiên §8.1.
- **Bằng chứng** (`lib/character/engine/character_engine.dart`)
  - `:144-146`: `ClipEnded` được xử lý ở **mọi** state và không so `assetId` với clip đang phát.
  - `:33-39`: barge-in (`PttPressed`) không xoá `currentTurnId`, nên `TtsFinished`/`TtsFailed` của turn vừa bị dừng vẫn khớp và đưa state từ `listening` về `idle`/reaction.
  - `:214-215`: `_matchesTurn` trả `true` khi `currentTurnId == null`. Vì vậy sau `TurnCancelled`/`TtsFinished`, `ReplyReady`/`TtsStarted` đến muộn của turn cũ vẫn được nhận (`:51`), phát `ReleaseTtsGate` và chuyển sang `talking`.
  - `:127-132`: `JobStarted` ghi đè `talking`/`listening`. `JobFinished` đưa mọi state về `idle`, kể cả khi đang nói. Job không được theo dõi theo id nên nhiều job chồng nhau bị tính sai.
  - `:133-140`: `CueReceived` ghi đè `listening`/`talking`/`thinking`.
  - `:158-159`: `Tick('pre_speech_max')` không gắn turn, nên tick cũ mở TTS gate của turn mới.
- **Tái hiện (probe P1–P6)**
  - P1: `PttPressed` → `ClipEnded('chr_999')` ⇒ `idle`.
  - P2: `TurnSubmitted(t1)` → `ReplyReady` → `TtsStarted(t1)` → `PttPressed` → `TtsFinished(t1)` ⇒ `idle` (đáng lẽ vẫn `listening`).
  - P3: `TurnSubmitted(t1)` → `TurnCancelled(t1)` → `ReplyReady(t1)` ⇒ có `ReleaseTtsGate`; sau đó `TtsStarted(t1)` ⇒ `talking`.
  - P4: đang `talking`, `JobFinished` ⇒ `idle`.
  - P5: đang `listening`, `CueReceived(neutral)` ⇒ `idle`.
  - P6: `TurnSubmitted(t2)` → `Tick('pre_speech_max')` ⇒ `ReleaseTtsGate`.
- **Hướng sửa:** viết reducer dạng bảng `(activity, overlay) × event` theo §8.3. Ghi nhớ turn đã đóng (`lastClosedTurnId` hoặc bộ đếm tăng dần). Barge-in phải đóng turn hiện tại. `ClipEnded`/`ClipError` phải mang `playbackToken` do engine cấp và bị bỏ qua nếu token không khớp. `Tick` phải mang token/turn. Job cần theo dõi bằng tập `activeJobIds`.
- **Release impact:** sẽ lộ ngay khi nối TTS/STT thật (Phase 6).

### S2-02 — Không có effect runner và không có timer: state bị kẹt, `sleep` không đạt tới

- **Vi phạm:** §8.2–§8.4 (`thinking_min_dwell`, `overlay_max`, `working_max`, `idle_to_sleep_*`, `context_hold`, `tts_wait_timeout` 8 s), §8.5.2 và §14.
- **Bằng chứng**
  - `lib/app/character_runtime_controller.dart:35-38`: `dispatch` **bỏ qua `result.effects`**. `PauseStage`, `ResumeStage`, `StopTts`, `ReleaseTtsGate`, `ScheduleTick` và `LogEngine` không được thực thi ở đâu (grep toàn bộ `lib/`). `Tick('pre_speech_max')` sẽ không bao giờ đến, nên TTS gate của reply `surprised` sẽ treo khi nối TTS thật.
  - Chỉ có `ScheduleTick('pre_speech_max')`, không có timer nào khác.
  - Không event nào dẫn tới `sleep`. Test gốc phải tự gán `copyWith(activity: sleep)` (`test/character_engine_test.dart:58`). Probe P7 chạy 10.000 event ngẫu nhiên (kèm các `Tick` theo tên spec) và không lần nào vào `sleep`. `thinking` không bao giờ thoát nếu thiếu `TtsStarted`.
  - Reaction không có `overlay_max`. Probe R3 trên manifest thật (relationship bật, cue `shy`) chọn clip **loop** (`chr_013`) **73/200** lần, và vì loop không phát `ClipEnded` nên activity kẹt ở `shy` vĩnh viễn. Tương tự `happy` với `chr_015`/`chr_016`, và `concerned` trong daily khi fallback về một idle loop.
  - `stage_context` bị dính: `working` ép `assistant` và `_show` lưu lại giá trị đó, nên sau `JobFinished` context vẫn là `assistant` (probe P9). Không có `context_hold` để trả về `daily`, và `AppStarted`/`AppResumed ≥ 60 s` cũng không reset về `daily`.
- **Hướng sửa:** thêm `EngineEffectRunner` ở runtime để thực thi mọi effect và đặt/huỷ timer theo tag + token. Đưa hằng số §8.4 vào `engine/config.dart`. Tách overlay khỏi activity theo §8.1 (overlay luôn là oneshot, có `overlay_max`). Thêm transition `idle → sleep` và `context_hold`.
- **Release impact:** chặn Phase 6 (TTS/turn thật).

### S2-03 — Clip oneshot trong pool activity kết thúc luôn activity (`thinking`/`talking` → `idle`)

- **Vi phạm:** §11.2 bước 3 (`M = ∅` → oneshot được nối bằng crossfade, tức là chọn lại) và §8.3 (`ClipEnded` chỉ có ý nghĩa với overlay).
- **Bằng chứng:** trên manifest thật, pool daily `thinking` chỉ có `chr_030` (oneshot, primary). Pool `talking` gồm `chr_018` (loop main), `chr_002` (oneshot) và `chr_029` (loop, review), với xác suất chọn variant 0,2.
  - R1: `PttPressed` → `PttReleased(valid)` → `playRequest.loop == false`; `ClipEnded` ⇒ `idle` trong khi vẫn đang chờ LLM.
  - R2: 29/200 seed chọn oneshot cho `talking`. Khoảng 6 s sau, `ClipEnded` đưa về `idle` dù TTS vẫn đang nói.
  - Các test gốc không phát hiện vì chạy trên demo manifest.
- **Hướng sửa:** với activity state, `ClipEnded` phải chọn lại clip trong cùng state (có variant rotation và `thinking_variant_rotate_ms`) thay vì chuyển activity.
- **Release impact:** lỗi hiển thị lặp lại thường xuyên ngay khi vault có media.

### S2-04 — Validator manifest fail-open ở các ràng buộc chéo §4.4

- **Vi phạm:** CHARACTER_SYSTEM §4.4 (vi phạm bất kỳ → từ chối toàn bộ manifest), INV-03, INV-05; §16 "Manifest validator test".
- **Bằng chứng** (`lib/character/manifest/manifest_loader.dart`)
  - `_safePath` (`:186-203`) chỉ khớp regex chung. Nó **không** ràng buộc số `chr_NNN` trong path với `asset_id`, prefix với `delivery`, đuôi `.mp4` cho `path` hay `.jpg` cho `poster`.
    - M1: `chr_001` trỏ tới `vault/chr_040.mp4` vẫn được nhận. Một asset nhãn `suggestive`/daily có thể phát media của asset `private`.
    - M2: `delivery=vault` với path `private_vault/…` (và ngược lại) được nhận.
    - M3: `path` trỏ `.jpg`, `poster` trỏ `.mp4` được nhận.
  - `manifest_kind` bị bỏ qua hoàn toàn.
    - M4: `delivery=bundle` + `content_sensitivity=private` được nhận.
    - M5: `manifest_kind=private_vault` với `allowed_modes=[daily]` được nhận, trong khi normal engine lẽ ra phải từ chối.
  - `audio_streams` chỉ yêu cầu `≥ 0`. M6: `audio_streams=2` được nhận **và** resolver vẫn chọn phát clip đó, vì `_eligible` thiếu điều kiện `audio_streams == 0` (§11.1).
  - M7: các field cấm ship (`source_file`, `notes`, `hard_block`) được nhận mà không báo lỗi. Nhờ vậy manifest có tên file nguồn vẫn lọt qua.
  - M8: enum không phân biệt hoa/thường (`"PRIVATE"`), và ID không liên tục (`chr_007`, `chr_900`) vẫn được nhận, trái với PHASE_5_REPORT §5 ("sequential unique IDs").
  - Đối chứng dương (M9, M10): JSON rác, weight âm và `allowed_modes` rỗng đều bị từ chối đúng. `load()` không bao giờ throw.
- **Hướng sửa:** kiểm tra `manifest_kind` theo bảng §4.4. Ràng buộc `path == '<delivery_dir>/<asset_id>.mp4'`, `poster == '…/<asset_id>.poster.jpg'`, `poster_blur == '…/<asset_id>.blur.jpg'`. Bắt buộc `audio_streams == 0` (hoặc bỏ asset đó như spec mô tả). Thêm denylist field cấm. So enum chính xác. Tuỳ quyết định: kiểm tra ID liên tục hoặc sửa report. Đồng thời thêm `audio_streams == 0` vào `_eligible`.
- **Release impact:** S2 hôm nay, vì manifest còn hard-code. Mức này sẽ **nâng lên S1** ngay khi Phase 6 đồng bộ manifest từ server.

### S2-05 — Runtime không dùng manifest canonical và đường fail-closed chưa được nối; test/report dựa trên demo

- **Bằng chứng**
  - `lib/app/providers.dart:10-12`: `manifestProvider` gọi `DemoManifestFactory.create()`, và hàm này gọi `parse()` (có thể **throw**) chứ không gọi `load()`. Runtime không có đường nào xử lý `ManifestLoadResult.invalid` → silhouette như PHASE_5_REPORT §5 mô tả (probe M11). Nếu manifest demo sai, provider sẽ throw và Home crash.
  - Demo manifest khác manifest Phase 4 ở: `states` 9 asset (ví dụ `chr_013` thật có `shy: primary`, `chr_014` thật là `sleep: primary`, `chr_015`/`chr_016` có `happy`), `technical_quality` 8 (`fair` bị đổi thành `good`), `weight` 8 (0,4 đổi thành 0,5), width/height 12 (768×1168 đổi thành 720×1280).
  - Các test mà PHASE_5_REPORT §5 gọi là kiểm tra "real 43-asset counts" (41/2, 19 review, poor, 15/15/41/41) thực ra chạy trên `DemoManifestFactory` (`test/asset_resolver_test.dart:32`, `test/manifest_loader_test.dart:80`). Manifest thật chỉ được kiểm tra `length == 43`.
  - Demo manifest (bảng sensitivity theo asset id, chuỗi `phase5-demo-v1`) có mặt trong `libapp.so` của bản release.
- **Hướng sửa:** thêm `ManifestRepository` trả về `ManifestLoadResult`; khi invalid, dùng library rỗng và engine chỉ hiển thị silhouette. Chạy toàn bộ test resolver/engine trên manifest Phase 4 thật (qua fixture copy hoặc snapshot đã kiểm hash). Chỉ giữ demo manifest trong test hoặc flavor dev.
- **Release impact:** chặn Phase 6 vì kết quả kiểm thử hiện không đại diện cho dữ liệu thật.

### S2-06 — VideoStage: số controller in-flight không giới hạn; timeout làm quarantine vĩnh viễn; race khi dispose

- **Vi phạm:** §12 (tối đa 3 controller; crossfade đang chạy bị thay bởi Play mới), §14 (hết bộ nhớ thì giảm về 2).
- **Bằng chứng** (`lib/character/stage/video_stage.dart`)
  - `:94-175`: mỗi `_apply` tạo một controller mới **trước** khi biết generation có còn hiện hành không. Controller cũ chỉ bị dispose khi `initialize` xong hoặc hết timeout. `assert(_controllerCount <= 3)` chỉ đếm slot, không đếm controller đang init. Probe V1: 10 resolution liên tiếp tạo **10 controller sống đồng thời**. Trên Android, việc này dễ cạn MediaCodec và gây lỗi init hàng loạt.
  - `:139` + `:171-174`: init chậm hơn 1500 ms (thiết bị yếu, cold start) sinh `ClipError` (probe V2), và engine đưa asset vào `brokenAssetIds` **suốt phiên** (`character_engine.dart:147-150`, không bao giờ xoá). Lỗi tạm thời vì vậy dần làm cạn pool thành poster/silhouette. `ClipError` còn được phát cả khi generation đã cũ hoặc widget đã unmount.
  - `:141-149`: ở nhánh generation cũ, listener đã gắn vào `_listeners` nhưng `incoming.dispose()` được gọi trực tiếp, nên map giữ reference tới controller đã dispose (leak nhỏ).
  - `:159-169`: nếu `_clearPlayback()` (poster/silhouette) chạy trong lúc `Future.delayed(crossfade)`, `outgoing` bị dispose hai lần. Nếu init của clip mới lỗi, clip cũ (có thể đã **không còn eligible** sau khi policy đổi) vẫn tiếp tục phát.
  - `:83-92` và `home_screen.dart:40-47`: lifecycle được xử lý hai nơi. Effect `PauseStage`/`ResumeStage` từ engine bị bỏ qua (xem S2-02).
- **Hướng sửa:** dùng controller pool có hạn mức cứng (tính cả controller đang init). Huỷ hoặc dispose ngay controller in-flight khi generation đổi. Phân biệt timeout với lỗi decode: timeout thì thử lại hoặc backoff, chưa đánh dấu broken (§14 yêu cầu "tải lại 1 lần" cho lỗi file). Chỉ phát `ClipError` khi generation còn hiện hành và widget còn mounted. Khi policy đổi làm clip hiện tại không còn eligible, gỡ ngay xuống poster/silhouette trước khi init clip mới.

### S2-07 — Chính sách chụp màn hình không được thực thi (Home và private)

- **Vi phạm:** PRIVACY_SPEC §4.1 (`stage_secure_window=auto`: FLAG_SECURE trên Home khi library normal có asset ≥ suggestive; overlay khi `inactive`), §5.5 (FLAG_SECURE khi vào màn PIN/private), §5.4 bước 6; T4/T17.
- **Bằng chứng**
  - `OwnerPolicy.blockScreenshots` mặc định `true` nhưng **không được áp dụng khi khởi động**. Home không bao giờ gọi `setSecure(true)` (probe A3), trong khi toàn bộ pool daily là `suggestive`.
  - `private_mode_screen.dart:31-33`: màn private chỉ bật FLAG_SECURE khi `blockScreenshots == true`. Owner tắt toggle thì màn private chụp được (probe A2). Lời gọi `setBlocked` không được `await`.
  - `private_mode_screen.dart:40`: khi khóa, FLAG_SECURE luôn bị tắt, kể cả khi Home cần bật (probe A3).
  - Không có privacy overlay khi `inactive` (recents thumbnail).
  - Policy là bool thay cho `auto|always|off` như §17.1.
- **Hướng sửa:** thêm `SecureWindowCoordinator` tính trạng thái từ route hiện tại, library và policy. Route private/PIN luôn bật FLAG_SECURE, không phụ thuộc toggle. Home bật theo `auto`. Thêm overlay khi `inactive`.
- **Release impact:** chặn release. Mức này sẽ **thành S1** khi màn private hiển thị nội dung.

### S2-08 — Cấu hình build release: debug symbols bị giữ cho mọi `.so`, và bản release ký bằng debug key

- **Bằng chứng**
  - `android/app/build.gradle.kts:16-18`: `packaging { jniLibs.keepDebugSymbols += "**/*.so" }` không giới hạn theo build type.
  - Kích thước đo được:

    | APK | Tổng | `libflutter.so` | Section `.debug*` | `.text` |
    |---|---:|---:|---:|---:|
    | debug x86_64 | 454.845.355 | 390.001.840 (stored) | **340.384.767** | 10,2 MB |
    | release x86_64 | 178.184.695 | 165.996.904 (stored) | **148.141.777** | 7,5 MB |

    Các phần còn lại của bản debug: `kernel_blob.bin` 73,7 MB (bình thường với JIT debug), `isolate_snapshot_data` 11,6 MB và dex khoảng 17 MB. Nguyên nhân chính của mức 455 MB **không phải "vì là debug build"** như PHASE_5_REPORT §17 viết, mà là cấu hình `keepDebugSymbols`. Nếu strip, bản release x86_64 ước tính còn khoảng 30 MB.
  - Không phải do video, cache hay generated media: `flutter_assets` chỉ gồm font, shader, NOTICES và manifest.
  - `build.gradle.kts:36-39`: bản release ký bằng `signingConfigs.getByName("debug")`.
  - `android/build.gradle.kts:3-5`: biến môi trường `HANA_FLUTTER_ENGINE_MAVEN` chèn một maven repo **trước** `google()`/`mavenCentral()`. Đây là rủi ro supply-chain nếu CI có biến này (S3, nhưng nên sửa cùng lúc).
  - APK build với `--target-platform android-x64` vẫn có thư mục `lib/arm64-v8a` và `lib/armeabi-v7a`, nhưng các thư mục này chỉ chứa `libsqlite3.so`. Nếu cài APK này lên thiết bị ARM, `libflutter.so` sẽ thiếu (S3; cần dùng `abiFilters` hoặc build đủ ABI/AAB).
- **Hướng sửa:** xoá `keepDebugSymbols` (hoặc chỉ giữ cho debug), dùng `--split-debug-info` và `ndk.debugSymbolLevel` để upload symbol riêng. Cấu hình keystore release qua `key.properties` hoặc CI secret. Thêm CI check: APK release ≤ ngưỡng và không có section `.debug*`. Phát hành bằng AAB hoặc `--split-per-abi`.
- **Release impact:** chặn release.

---

### S3 (không chặn, nên sửa trước hoặc trong Phase 6)

| ID | Vấn đề | Bằng chứng | Đề xuất |
|---|---|---|---|
| S3-01 | Reducer không thuần hoàn toàn: trạng thái RNG nằm trong `AssetResolver` (ngoài `CharacterEngineState`), nên cùng `(state, event)` cho ra kết quả khác nhau. Replay/time-travel debug không tái hiện được. | Probe P8 (20 lần `reduce(base, AppStarted)` cho hơn 1 asset khác nhau); `session_manager.dart:61` | Lưu seed/counter của RNG trong state, hoặc truyền giá trị random qua input. |
| S3-02 | Resolver lệch spec §11.2/§11.3: không đảm bảo "poor không chọn 2 lần liên tiếp / không là clip đầu sau AppStarted"; không đảm bảo "không chọn V hai lần liên tiếp"; thiếu quy tắc `seamless && |M|=1 → setLooping` (hiện `crossfadeMs` 0/250 không được VideoStage dùng cho vòng loop); `discreet` áp cho cả private engine (spec chỉ normal); fallback daily ghi `effectiveContext=daily` vào state nên relationship/assistant bị hạ vĩnh viễn. | `asset_resolver.dart:73-80,131-133,224-251` | Bổ sung các quy tắc còn thiếu; tách "context để chọn" khỏi "context lưu trong state". |
| S3-03 | Owner policy: không persist, không có `policy_version`; `confirm_sensitive` chỉ là helper, vì constructor public `OwnerPolicy(overrides: …)`/`AssetPolicyOverride(...)` bỏ qua xác nhận và validate (probe O1: modes rỗng, weight −3); không chặn override cho asset `private_vault` (O2, trái §17.2); `updateOwnerPolicy` dispatch `AppStarted` làm reset turn đang chạy (spec: `PolicyUpdated` giữ state); policy của private engine là snapshot và không cập nhật; `OwnerPolicyNotifier` là provider toàn cục có mutator public. | `owner_policy.dart:12-49`, `character_runtime_controller.dart:40-43`, `providers.dart:22-50` | Dùng factory `OwnerPolicy.validated`/`fromJson` có validate; thêm event `PolicyUpdated`; ở Phase 6 ràng buộc bằng import-linter/lint để module chat/AI không import `ownerPolicyProvider`. |
| S3-04 | Vault abstraction: `CharacterAssetRepository` trả `File` plaintext và mặc định file đã có sẵn cục bộ. Chưa có chỗ cho giải mã vào `vault_rt`/`prv_rt` (LRU 8 file, wipe khi paused ≥ 60 s), verify sha256, hay tách repository theo zone (một provider dùng chung cho normal và private). `LocalDevVaultAssetRepository` không resolve symlink. `HANA_DEV_VAULT_ROOT` là `--dart-define`; nếu CI truyền giá trị này khi build release thì dev vault sẽ lọt vào production. | `asset_repository.dart`, `providers.dart:14-20` | Tạo interface `DecryptedMediaLease` (acquire/release, xoá file khi release); tách repository normal và private; CI kiểm tra release không có define `HANA_DEV_VAULT_ROOT`. |
| S3-05 | Ranh giới cue: `specialCue` chỉ được kiểm regex, không đối chiếu registry hoặc `llm_selectable`, và engine không dùng nó (special cue chưa được implement); thiếu log `CUE_CONTEXT_PRIVATE_IN_NORMAL`. `ClipEnded`/`ClipError` mang `assetId` và là event public: **tuyệt đối không** được bridge từ mạng/SSE (nếu bridge, backend có thể quarantine asset tuỳ ý). | `character_cue.dart:21-36`, `engine_event.dart:92-101` | Tách `NetworkCueEvent` (chỉ `CharacterCue`) khỏi `StageEvent` nội bộ; thêm test kiến trúc. |
| S3-06 | Chất lượng test: 53 test đều pass nhưng nhiều assertion yếu. Fuzz 500 bước chỉ kiểm `context != private` và không kiểm CHR-01/03/06/07/08 (spec yêu cầu 10.000 bước với policy ngẫu nhiên); test "ten states" tự gán `sleep`; test "stale callbacks" chỉ kiểm `TtsStarted`, bỏ qua trường hợp `currentTurnId == null`; không test barge-in kèm TTS callback, `ClipEnded` cũ, timer, hay lifecycle khi đang `listening`; test `setVolume` bằng grep chuỗi (bỏ sót nếu truyền biến) và không kiểm `mixWithOthers`; test resolver dùng demo manifest; không có test cho VideoStage khi nhiều Play dồn dập, timeout, hay dispose; test APK chỉ đọc `pubspec.yaml` mà không quét APK thật; test private route **khẳng định mock bypass là hành vi đúng**. | `test/*` | Thêm property test CHR-xx trên manifest thật; chuyển các probe của audit này thành test hồi quy (đảo kỳ vọng); thêm script CI quét APK; kiểm `VideoPlayerOptions` bằng factory injection. |
| S3-07 | Vệ sinh APK: `libapp.so` bản release chứa đường dẫn tuyệt đối máy dev `file:///C:/Users/Administrator/Downloads/Hana/repo/app/.dart_tool/flutter_build/dart_plugin_registrant.dart` (2 lần); bản debug nhúng toàn bộ source Dart kèm đường dẫn máy dev (36 lần, chỉ debug); demo manifest và nút "Demo PTT"/"Demo công việc" có trong release. | Quét APK §7 | Build release trên CI với đường dẫn trung tính; bỏ UI demo khỏi release. |
| S3-08 | Vòng đời: `runConversationDemo`/`runWorkDemo` vẫn `dispatch` sau khi `HomeScreen.dispose` (lỗi dùng ChangeNotifier sau dispose); `refreshVaultAvailability` chỉ chạy một lần, không có `AssetReady`; `brokenAssetIds` không bao giờ được xoá. | `character_runtime_controller.dart:45-85` | Thêm cờ `_disposed`, event `AssetReady`, cơ chế thử lại 1 lần. |
| S3-09 | PHASE_5_REPORT có các nhận định không khớp code: "sequential unique IDs", "audio count" được validate, "malformed manifests fail closed to stage fallback" (chưa nối vào runtime), "real 43-asset counts" (thực ra chạy trên demo), "Lock destroys the private session" (chỉ gán null), APK lớn "because … debug build" (thực ra do `keepDebugSymbols`, release vẫn 170 MB). | §4 ở trên | Sửa report sau khi fix. |

---

## 5. Các kiểm tra đạt (đã xác minh)

| Hạng mục | Kết quả | Bằng chứng |
|---|---|---|
| LLM/backend không điều khiển được asset | ✔ | `CharacterCue.fromJson` chỉ nhận enum `emotion`/`intensity`/`stage_context` và `special_cue` theo regex; các field `asset_id`/`path`/`filename` bị bỏ qua (test gốc). `ResolverInput` không có field nào đến từ mạng. Không có API nhận sensitivity, allowed_modes hay filter tuỳ ý từ backend. `stage_context` từ Director được phép theo §8.5; `private` bị ép về `daily`. |
| Normal engine không bao giờ ở context `private` | ✔ | `_effectiveContext`/`_cueContext`; `privateSessionActive` là field bất biến. Property R4 chạy 10.000 bước trên manifest thật. |
| Relationship tắt → clip relationship-only không lọt | ✔ | R4: mọi clip được chọn đều có `effectiveContext ∈ allowedModes`, `excludedByDefault=false`, và không có relationship khi policy tắt. |
| Daily/assistant chỉ ở tier thấp nhất | ✔ | R4: mọi lần chọn daily/assistant đều là `suggestive` (tier thấp nhất có trong thư viện). |
| Fallback không vượt mode | ✔ | Fallback daily chỉ áp cho assistant/relationship (§11.3); poster được kiểm lại `_eligible`; test gốc "fallback never crosses". |
| `recentUsage` giữa các mode | ✔ (chấp nhận được) | Danh sách dùng chung trong normal engine, nhưng poster fallback kiểm lại eligibility; private dùng instance riêng. |
| `confirm_sensitive` ở luồng UI | ✔ | Settings/Lab bắt buộc qua dialog; helper throw `SensitiveModeConfirmationRequired` (xem thêm S3-03 về constructor). |
| Âm lượng video | ✔ | `MutedVideoSession`: initialize → `setVolume(0.0)` → setLooping → play; adapter từ chối mọi giá trị khác 0; `mixWithOthers: true`; `lib/` không có lời gọi `setVolume(` nào khác. |
| Black-frame | ✔ (cơ bản) | Poster/silhouette nằm dưới video; video chỉ render khi `isInitialized`. |
| Discreet | ✔ | Luôn trả về silhouette. |
| Character Lab | ✔ | Route và nút đều gate bằng `kDebugMode`; release `libapp.so` có 0 lần `CharacterLabScreen`/`Character Lab`/`character-lab`. |
| Manifest: JSON hỏng, weight âm, modes rỗng, path traversal, đường dẫn tuyệt đối, enum sai, ID trùng | ✔ | Test gốc và probe M9/M10. |
| Log | ✔ | Không có `print`/`debugPrint`/`log` trong `lib/`; `LogEngine` chỉ mang mã, không có asset id (hiện chưa có sink). |
| Secret/config | ✔ | Không có key/token; `local.properties` chỉ chứa đường dẫn SDK (đã gitignore trong `android/.gitignore`); chuỗi `secret` trong dex là định danh thư viện (`secretKey`/`SecretKeySpec` của flutter_secure_storage/Tink). |
| Manifest Android | ✔ | `allowBackup=false`, `fullBackupContent=false`; `INTERNET` chỉ có trong manifest debug; APK release không `debuggable`. |

---

## 6. Ma trận theo 14 hạng mục yêu cầu

| # | Hạng mục | Kết luận | Finding |
|---|---|---|---|
| 1 | Character engine | ✘ | S2-01, S2-02, S2-03, S3-01 |
| 2 | LLM/server boundary | ✔ (có lưu ý) | S3-05 |
| 3 | Mode isolation | ✘ (private) / ✔ (resolver) | S1-01, S3-02 |
| 4 | Sensitivity policy | ✔ ở resolver; ✘ `audio_streams` | S2-04, S3-03 |
| 5 | Resolver | ✔ lõi; lệch spec nhỏ | S2-03, S3-02 |
| 6 | Manifest | ✘ | S2-04, S2-05 |
| 7 | VideoStage | ✘ | S2-06 |
| 8 | Vault boundary | ✔ Phase 5; thiết kế cần mở rộng | S3-04 |
| 9 | APK content | ✔ không có media/tên nguồn/map; ✘ có mock private | S1-01, S3-07 |
| 10 | Owner policy | ✘ | S2-07, S3-03 |
| 11 | Private mode UI boundary | ✘ | S1-01, S2-07 |
| 12 | Test quality | ✘ | S3-06, S2-05 |
| 13 | Performance / APK size | ✘ | S2-08, S2-06 |
| 14 | Security | ✘ | S1-01, S2-07, S3-07 |

---

## 7. APK content audit (read-only)

| Kiểm tra | `app-debug.apk` (455 MB) | `app-release.apk` (170 MB) |
|---|---|---|
| Entry video (`.mp4/.mov/.webm/.mkv`) | **0** | **0** |
| Ảnh ngoài `res/` | 0 | 0 |
| `flutter_assets` | font, shader, NOTICES, kernel/snapshot | font (đã tree-shake), shader, NOTICES |
| 43 stem tên file nguồn (`ARRJ9858`, …) | **0** | **0** |
| `source_asset_map` / `assets_source` / `assets_processed` | 0 / 0 / 0 | 0 / 0 / 0 |
| `HANA_DEV_VAULT_ROOT` | 1 (source nhúng trong kernel debug) | 0 |
| Đường dẫn máy dev `Downloads/Hana` | 36 (source debug) | 2 (URI plugin registrant) → S3-07 |
| `chr_0…` | 2 (source) | 1 (`chr_003`, mẫu trong Settings) |
| UI mock private ("private session (mock)") | có | **có** → S1-01 |
| Character Lab | có (debug) | **không** |
| ABI | x86_64 (đủ) + arm64/armv7 (chỉ sqlite) | như bản debug → S2-08 |
| `.debug*` trong `libflutter.so` | 340 MB | 148 MB → S2-08 |
| Ký | debug | **debug key** → S2-08 |

---

## 8. Release impact

Chưa thể phát hành bản nào (kể cả bản thử nội bộ có vault thật) trước khi đóng **S1-01, S2-07, S2-08**. Các lỗi S2-01 đến S2-06 không làm lộ dữ liệu ngay hôm nay, nhưng làm hành vi nhân vật sai ngay khi có TTS/turn/media thật, và S2-04 sẽ thành S1 khi manifest được đồng bộ từ server.

## 9. Phase 6 readiness

**CHƯA SẴN SÀNG.** Điều kiện tối thiểu trước khi bắt đầu Phase 6:

1. S1-01: gỡ mock private khỏi release; thêm `PrivateUnlockService`/`PrivateSession`, route guard, lock coordinator và một session manager duy nhất.
2. S2-04 và S2-05: validator §4.4 đầy đủ; runtime dùng `ManifestLoadResult` (invalid → silhouette); test chạy trên manifest thật.
3. S2-01, S2-02 và S2-03: reducer dạng bảng có guard theo state/turn/playback token; `EngineEffectRunner` với các timer §8.4; activity oneshot được chọn lại.
4. S2-06: giới hạn cứng số controller; phân biệt timeout với lỗi decode.
5. S2-07: `SecureWindowCoordinator` (private luôn bật; Home theo `auto`; overlay khi `inactive`).
6. S2-08: strip symbol, cấu hình keystore release, CI gate cho kích thước APK và nội dung APK.
7. Chuyển 33 probe của audit thành test hồi quy với kỳ vọng đảo ngược, rồi review lại Phase 5.

Phần nên giữ nguyên: hợp đồng `CharacterCue` (enum-only), `AssetResolver` (eligibility/tier/mode/fallback), `MutedVideoSession`, và tách instance private engine.

---

**PHASE 5 REVIEW — FAIL**

Lý do: có 1 S1 (cổng private bị bypass trong bản production) và kiến trúc private/manifest/effect-runner chưa an toàn để nối backend/AI. Không có media bị cấm trong APK.

STOP. Không sửa code. Không làm Phase 6.
