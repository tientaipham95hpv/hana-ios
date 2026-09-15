# HANA — PRODUCT REQUIREMENTS DOCUMENT

Phiên bản: 1.1 (Phase 1 + Final Decision Patch)
Ngày: 2026-09-15
Chủ sở hữu tài liệu: Lead Architect
Trạng thái: CHỐT phạm vi v1
Vị trí canonical: `repo/docs/`. Quyết định chốt: ARCHITECTURE §0.1.

Tài liệu kỹ thuật: `ARCHITECTURE.md` (gốc), `CHARACTER_SYSTEM.md`, `AI_PROTOCOL.md`, `VOICE_SPEC.md`, `MEMORY_SPEC.md`, `WORK_JOURNAL_SPEC.md`, `STANDING_INSTRUCTIONS_SPEC.md`, `TIMEZONE_SPEC.md`, `PRIVACY_SPEC.md`, `ACCEPTANCE_CRITERIA.md`.

---

## 1. Tầm nhìn

Hana là một **AI companion trưởng thành kiêm trợ lý cá nhân** trên điện thoại: một người đồng hành có hình ảnh sống động (video), giọng nói, trí nhớ và sự liên tục trong mối quan hệ, đồng thời làm được việc thật — nhắc việc, ghi nhật ký công việc, tổng hợp báo cáo tháng, ghi nhớ chỉ thị lâu dài.

Hai giá trị cốt lõi phải cùng tồn tại:

1. **Cảm giác có một người thật sự ở đó**: Hana phản ứng bằng biểu cảm phù hợp, nói bằng giọng tự nhiên, nhớ chuyện hôm qua, hỏi thăm việc dang dở.
2. **Tin cậy như một công cụ**: nhắc đúng giờ Việt Nam, lưu nguyên văn, báo cáo không bịa, dữ liệu riêng tư không bao giờ lộ.

---

## 2. Người dùng và bối cảnh

| Mục | Giá trị |
|---|---|
| Người dùng | **Một chủ sở hữu duy nhất** (single-owner) — người dùng trưởng thành, nói tiếng Việt, làm việc văn phòng/kỹ thuật |
| Thiết bị | **Android là target release V1** (điện thoại), tối đa 3 thiết bị đăng nhập. **iOS ngoài phạm vi V1** |
| Ngôn ngữ | Tiếng Việt (chấp nhận xen thuật ngữ tiếng Anh) |
| Múi giờ nghiệp vụ | Asia/Ho_Chi_Minh |
| Triển khai | Tự host: phát triển trên Windows, chạy thật trên VPS riêng |
| Kênh AI | 9Router (gateway OpenAI-compatible) |

---

## 3. Persona Hana

| Thuộc tính | Mô tả |
|---|---|
| Danh tính | Hana, một người phụ nữ trưởng thành |
| Tính cách | Ấm áp, tinh tế, hơi tinh nghịch, chu đáo; làm việc gọn gàng, đáng tin |
| Xưng hô | Mặc định Hana xưng "em", gọi người dùng "anh" (chỉnh được) |
| Giọng nói | Một giọng TTS nhất quán cho mọi mode |
| Hình ảnh | Chỉ dùng video có sẵn; 10 trạng thái core + special videos |
| Trung thực | Thừa nhận là AI khi được hỏi nghiêm túc; không nói đã làm việc gì khi chưa làm |
| Lành mạnh | Không thao túng, không trách móc khi người dùng vắng, khuyến khích nghỉ ngơi và đời sống thật |
| Giới hạn | Normal mode không nội dung tình dục tường minh; private mode có giới hạn tuyệt đối (PRIVACY_SPEC §10) |

---

## 4. Phạm vi v1

### 4.1 Mục tiêu

- G1. Trò chuyện text và voice push-to-talk tự nhiên, có TTS.
- G2. Nhân vật video phản ứng đúng ngữ cảnh với 10 trạng thái core và special videos, không bao giờ phát âm thanh video.
- G3. Trí nhớ dài hạn minh bạch, người dùng kiểm soát được.
- G4. Trợ lý: task, reminder đúng giờ Việt Nam, kể cả khi mất mạng.
- G5. Work journal hằng ngày + báo cáo tháng theo kỳ half-open `[ngày 15 tháng trước, ngày 15 tháng này)` ("từ ngày 15 tháng trước đến hết ngày 14 tháng này") chính xác, có trích dẫn, không ngày nào thuộc hai kỳ.
- G6. Standing instructions: người dùng dặn một lần, Hana nhớ và làm theo lịch, có xác nhận.
- G7. Daily companion: chào buổi sáng, hỏi thăm buổi tối, hỏi lại việc dang dở.
- G8. Private/adult mode cách ly hoàn toàn, chỉ mở chủ động.

### 4.2 Ngoài phạm vi v1 (non-goals)

| # | Không làm | Lý do |
|---|---|---|
| NG1 | **iOS** (quyết định chốt: ngoài phạm vi V1), web, desktop client | Android là target release V1; toolchain Phase 0 chỉ Android; tập trung chất lượng |
| NG2 | Nhiều người dùng / đăng ký công khai | Sản phẩm cá nhân |
| NG3 | Sinh video/ảnh mới, lip-sync, avatar 3D | Chỉ dùng video có sẵn |
| NG4 | Wake word, always-listening, duplex voice streaming | Quyền riêng tư, độ phức tạp |
| NG5 | Streaming token LLM ra UI | Envelope JSON có cấu trúc; trạng thái `thinking` che độ trễ |
| NG6 | Tích hợp Google Calendar/Email/Slack | Sau v1 |
| NG7 | Lịch âm | Sau v1 |
| NG8 | Export PDF báo cáo | Markdown đủ cho v1 |
| NG9 | Export dữ liệu private | Giảm bề mặt rò rỉ |
| NG10 | Hot-update asset video qua mạng (normal) | Asset bundle theo bản build |
| NG11 | Routine định kỳ tùy ý (ngoài `work_report`, `journal_nudge`) | Tập đóng để kiểm soát chất lượng |
| NG12 | Khóa toàn app bằng PIN | Dựa vào khóa thiết bị; private có PIN riêng |

---

## 5. Danh sách tính năng

Ưu tiên: **P0** = bắt buộc cho v1; **P1** = nên có trong v1 nếu không ảnh hưởng P0.

| ID | Tính năng | Ưu tiên | Spec |
|---|---|---|---|
| F-01 | Chat text | P0 | ARCHITECTURE §8.1, AI_PROTOCOL |
| F-02 | Voice push-to-talk + STT | P0 | VOICE_SPEC §3–§5 |
| F-03 | TTS giọng Hana | P0 | VOICE_SPEC §6–§8 |
| F-04 | Character stage — 10 core states | P0 | CHARACTER_SYSTEM |
| F-05 | Special videos | P0 | CHARACTER_SYSTEM §10 |
| F-06 | Private/adult mode | P0 | PRIVACY_SPEC §5 |
| F-07 | Memory dài hạn + UI quản lý | P0 | MEMORY_SPEC |
| F-08 | Daily companion (morning brief, evening check-in, followup) | P0 | ARCHITECTURE §8.5, MEMORY_SPEC §9 |
| F-09 | Task & reminder (kể cả lặp lại) | P0 | ARCHITECTURE §8.3–§8.4, TIMEZONE_SPEC §7 |
| F-10 | Work journal | P0 | WORK_JOURNAL_SPEC §3–§5 |
| F-11 | Standing instructions | P0 | STANDING_INSTRUCTIONS_SPEC |
| F-12 | Báo cáo công việc định kỳ | P0 | WORK_JOURNAL_SPEC §6 |
| F-13 | Relationship continuity | P0 | MEMORY_SPEC §8 |
| F-14 | Notifications + inbox | P0 | ARCHITECTURE §8.6 |
| F-15 | Settings & kiểm soát dữ liệu (xóa lịch sử, xóa tất cả, thu hồi thiết bị) | P0 | PRIVACY_SPEC §9 |
| F-16 | Export dữ liệu normal | P1 | PRIVACY_SPEC §9 |
| F-17 | Hoàn tác action 30 giây | P0 | AI_PROTOCOL §7.4 |
| F-18 | Semantic memory retrieval (embeddings) | P1 | MEMORY_SPEC §7.4 |

### F-01 Chat text

- Người dùng gõ tin → Hana `thinking` → trả lời có biểu cảm → (tùy cài đặt) đọc bằng giọng.
- Tin gửi lúc mất mạng được xếp hàng và tự gửi lại, không trùng.
- Hana có thể thực hiện hành động (đặt nhắc, lưu nhật ký…) và hiển thị thẻ kết quả kèm Hoàn tác.
- **User story:** "Là người dùng, tôi nhắn 'mai 3h chiều nhắc anh họp team' và thấy ngay thẻ nhắc đúng 15:00 Thứ Tư, 16/09."

### F-02 Voice push-to-talk

- Giữ nút mic để nói (≤ 60 s), kéo để hủy, thả để gửi. Hana `listening` khi đang giữ.
- Transcript hiện thành tin nhắn của người dùng.
- Nhấn mic khi Hana đang nói → Hana im ngay và nghe.

### F-03 TTS

- Chỉ nguồn âm thanh của Hana. Video luôn im lặng.
- Giờ, ngày, số, tiền được đọc tự nhiên tiếng Việt.
- Cài đặt: luôn đọc / chỉ khi nói bằng voice / không đọc; tốc độ; nút tắt tiếng nhanh.

### F-04 Character stage

- 10 trạng thái: `idle, listening, talking, thinking, happy, shy, surprised, concerned, working, sleep`.
- Chuyển trạng thái mượt (crossfade), không màn hình đen, không lặp một clip nhàm chán.
- LLM chỉ gợi ý cảm xúc; app quyết định clip.

### F-05 Special videos

- Clip đặc biệt gắn "cue" ngữ nghĩa (vd chào buổi sáng, ăn mừng khi báo cáo xong).
- Có cooldown, tôn trọng giờ yên lặng, tách normal/private.

### F-06 Private mode

- Chỉ mở chủ động từ Cài đặt. **PIN 6 số là credential bắt buộc và luôn là fallback**; mở khóa bằng vân tay/khuôn mặt là **tùy chọn tiện lợi** (bật sau khi nhập PIN, định kỳ 72 giờ phải nhập lại PIN), không bao giờ là cách mở duy nhất. Không bao giờ được Hana gợi ý.
- Lịch sử, ký ức, asset, giọng nói private tách biệt; không notification; chặn screenshot; tự khóa khi rời app.
- Không có nhắc việc/nhật ký/chỉ thị trong private.

### F-07 Memory

- Hana tự ghi nhớ từ trò chuyện (có bằng chứng từ lời người dùng) hoặc khi được dặn "nhớ giúp anh…".
- Màn hình Ký ức: xem theo nhóm, nguồn gốc, sửa, ghim, xóa.
- Thông tin sức khỏe/tài chính/nhạy cảm chỉ lưu khi người dùng dặn rõ.

### F-08 Daily companion

- Mặc định (đều **cấu hình được**): 08:00 chào buổi sáng + tóm tắt nhắc việc hôm nay; 14:00 hỏi lại việc dang dở nếu có; 21:30 hỏi thăm buổi tối (bỏ qua nếu vừa trò chuyện).
- Không nhắn chủ động trong quiet hours (mặc định 23:00–07:00, cấu hình được); tối đa 3 tin chủ động/ngày.
- Bật/tắt và đổi giờ trong Cài đặt hoặc qua chat.

### F-09 Task & reminder

- Task có hạn ngày, ưu tiên; reminder có giờ, lặp lại hằng ngày/tuần/tháng/năm.
- Nhắc nổ đúng giờ kể cả khi không có mạng (lịch cục bộ trên Android) và **kể cả khi FCM chưa được cấu hình**; push FCM chỉ là dự phòng tùy chọn.
- Hoàn thành / hoãn (snooze) / bỏ qua từ notification.

### F-10 Work journal

- Người dùng kể việc đã làm → Hana lưu **nguyên văn** vào ngày làm việc (cutoff ngày nghiệp vụ mặc định 04:00, cấu hình được: sau nửa đêm đến trước 04:00 vẫn tính hôm trước).
- Màn Nhật ký theo lịch: xem/sửa/xóa/thêm, lịch sử chỉnh sửa.

### F-11 Standing instructions

- Hana nhận diện yêu cầu lâu dài, **tóm tắt lại rõ ràng (kèm ngày bắt đầu/kết thúc kỳ đầu tiên)** và chờ xác nhận.
- Màn Chỉ thị: xem, xác nhận, sửa tham số, tạm dừng, hủy, lịch sử chạy.

### F-12 Báo cáo định kỳ

- Kỳ báo cáo tháng (chốt): backend dùng khoảng half-open `[ngày 15 tháng trước 00:00:00, ngày 15 tháng này 00:00:00)` giờ Việt Nam; UI ghi **"Từ ngày 15 tháng trước đến hết ngày 14 tháng này"**. Không ngày nào thuộc hai kỳ.
- Report tự tạo vào ngày 15 (mặc định 09:00, sau khi kỳ đóng) hoặc muộn hơn nếu hệ thống bù; gửi vào chat + notification (push nếu có FCM, không thì qua đồng bộ nền).
- Nếu copy sản phẩm gọi là "báo cáo ngày 14" thì đó chỉ là cách gọi trên UI; kỳ và ngày tạo không đổi.
- Số liệu do hệ thống tính; nội dung LLM có trích dẫn ngày; tạo lại khi nhật ký thay đổi; chia sẻ Markdown.
- Yêu cầu thủ công: kỳ gần nhất, kỳ hiện tại đến hôm nay, khoảng tùy chọn.

### F-13 Relationship continuity

- Hana biết đã quen bao lâu, lần cuối trò chuyện, cách xưng hô, biệt danh, kỷ niệm mốc (7/30/100/365 ngày).
- Tóm tắt từng ngày giúp Hana nhớ "hôm qua anh mệt".

### F-14 Notifications

- Kênh Android: "Nhắc việc", "Hana nhắn". Inbox trong app lưu mọi thông báo.
- FCM tùy chọn: khi chưa cấu hình, reminder vẫn nổ bằng lịch cục bộ; tin Hana/báo cáo đến qua đồng bộ khi mở app và đồng bộ nền định kỳ (có thể trễ vài phút).
- Preview mặc định chung chung cho tin Hana/báo cáo.

### F-15 Settings & dữ liệu

- Giọng nói, companion, giờ yên lặng, mốc ngày nhật ký, thiết bị, xóa lịch sử, xóa tất cả, chế độ riêng tư.

---

## 6. Màn hình và điều hướng

```
Bottom navigation: [Hana] [Việc] [Nhật ký] [Thêm]

Hana (Home)
 ├─ Stage video (9:16, phần trên)
 ├─ Danh sách tin nhắn + thẻ receipt/report
 ├─ Ô nhập text · nút gửi · nút mic (giữ để nói)
 ├─ Nút tắt tiếng nhanh · nút dừng nói
 └─ Icon inbox (badge số chưa đọc)

Việc
 ├─ Tab Task (hôm nay / quá hạn / sắp tới / xong)
 └─ Tab Nhắc nhở (sắp tới / lặp lại / đã qua)

Nhật ký
 ├─ Lịch tháng (chấm ngày có nhật ký)
 ├─ Chi tiết ngày (entries + items, sửa/xóa/thêm, lịch sử sửa)
 └─ Báo cáo → danh sách → chi tiết (Markdown render, số liệu, chia sẻ, tạo lại)

Thêm
 ├─ Chỉ thị (pending / active / paused / lịch sử)
 ├─ Ký ức (theo nhóm, việc dang dở, cách xưng hô)
 ├─ Cài đặt
 │   ├─ Giọng nói · Hana chủ động nhắn · Giờ yên lặng · Nhật ký (mốc giờ)
 │   ├─ Thông báo (preview) · Thiết bị
 │   ├─ Dữ liệu (xuất, xóa lịch sử, xóa tất cả)
 │   └─ Chế độ riêng tư (thiết lập / mở)
 └─ Giới thiệu

Private (route riêng, thay thế toàn bộ stack khi mở)
 ├─ Màn PIN
 ├─ Private Home (stage + chat + mic, nhãn "Riêng tư", nút Khóa)
 ├─ Ký ức riêng tư
 └─ Cài đặt riêng tư (thời hạn lưu, bật/tắt mở khóa sinh trắc học tùy chọn, đổi PIN, xóa sạch)
```

---

## 7. Hành trình người dùng chính

### J1 — Lần đầu mở app

1. Đăng nhập (tài khoản owner tạo sẵn bằng CLI).
2. Giới thiệu ngắn Hana (stage `greeting` nếu có).
3. Chọn cách xưng hô (mặc định anh/em).
4. Cho phép notification; giải thích và xin quyền exact alarm (Android).
5. Xem/chỉnh các mặc định: chào buổi sáng 08:00, hỏi lại việc dang dở 14:00, hỏi thăm tối 21:30, quiet hours 23:00–07:00, cutoff ngày nhật ký 04:00.
6. Vào Home; không nhắc gì đến private mode.

### J2 — Trò chuyện và đặt nhắc bằng voice

1. Giữ mic: "Chiều mai 3 giờ nhắc anh gọi cho khách hàng." → Hana `listening`.
2. Thả → `thinking` → transcript hiện → Hana `talking`: "Dạ, em đặt nhắc anh gọi cho khách hàng lúc ba giờ chiều thứ Tư, ngày mười sáu tháng chín rồi nha."
3. Thẻ ⏰ + Hoàn tác 30 s. Điện thoại đặt lịch cục bộ.
4. 15:00 hôm sau: notification + tin nhắn trong chat; nút Xong / Hoãn 10 phút.

### J3 — Workflow nhật ký và báo cáo tháng

1. Người dùng: "Hàng ngày anh sẽ gửi công việc đã làm, em lưu lại. Mỗi tháng tổng hợp từ ngày 14 tháng trước đến ngày 14 tháng này."
2. Hana tóm tắt 2 chỉ thị, nêu rõ kỳ theo quyết định chốt ("kỳ từ ngày 15 tháng trước đến hết ngày 14 tháng này, em tạo báo cáo lúc 09:00 ngày 15 sau khi kỳ đóng; kỳ đầu tiên: 15/09 – 14/10, báo cáo vào 15/10") và xin xác nhận; người dùng xác nhận hoặc bấm Sửa.
3. Mỗi tối người dùng kể việc → Hana lưu nguyên văn, xác nhận "em lưu vào nhật ký hôm nay (Thứ Ba, 15/09) rồi nha". Nhật ký gửi lúc 01:00 ngày 15/10 kể việc ngày 14/10 vẫn thuộc kỳ 15/09 – 14/10.
4. 09:00 ngày 15/10: Hana `working` (nếu đang mở app) → gửi thẻ "Báo cáo công việc 15/09/2026 – 14/10/2026" + notification; báo cáo có số liệu, nổi bật, theo dự án, vướng mắc, ngày chưa có nhật ký, trích dẫn ngày. Ngày 15/10 thuộc kỳ tiếp theo, không nằm trong báo cáo này.
5. Người dùng sửa nhật ký ngày 10/10 → báo cáo đánh dấu "có thay đổi" → Tạo lại → phiên bản 2.

### J4 — Daily companion

1. 08:00: "Chào buổi sáng anh, hôm nay anh có 2 lịch nhắc, cái đầu lúc 10:00…" (giờ do hệ thống chèn).
2. 14:00: "Sáng nay anh đi khám răng thế nào rồi?" (followup từ hôm trước).
3. 21:30 (nếu người dùng chưa nói chuyện trong 2 giờ): hỏi thăm ngày làm việc, mời kể việc hôm nay nếu chưa có nhật ký và có routine nhắc.

### J5 — Private mode

1. Cài đặt → Chế độ riêng tư → Mở → nhập PIN 6 số (hoặc, nếu người dùng đã tự bật, quét vân tay — luôn có nút "Dùng PIN").
2. Màn private (nhãn "Riêng tư", không chụp màn hình được), lịch sử private riêng, clip private.
3. Người dùng chuyển sang app khác 2 phút → quay lại: màn khóa; cần mở khóa lại (PIN, hoặc biometric nếu đã bật và chưa quá 72 giờ kể từ lần nhập PIN gần nhất).
4. Ra normal: Hana normal không biết gì về cuộc trò chuyện private; không notification nào về private.

### J6 — Quản lý ký ức

1. Thêm → Ký ức → thấy "Anh thích cà phê đen (Em tự ghi nhớ từ trò chuyện ngày 12/09)".
2. Sửa thành "Anh chuyển sang uống trà" hoặc xóa.
3. Hoặc nói trong chat "Quên chuyện anh thích cà phê đi" → Hana xóa, có Hoàn tác.

---

## 8. Yêu cầu phi chức năng

| Nhóm | Yêu cầu |
|---|---|
| Hiệu năng | ARCHITECTURE §17, VOICE_SPEC §13 |
| Độ tin cậy | Reminder nổ đúng giờ ±60 s khi thiết bị đã đồng bộ (kể cả offline); turn text thành công ≥ 98% khi 9Router khỏe |
| Offline | Xem cache chat/nhắc/nhật ký; text vào outbox; reminder cục bộ vẫn nổ; voice cần mạng |
| Riêng tư | PRIVACY_SPEC; không quảng cáo, không analytics bên thứ ba, không crash reporter bên thứ ba ở v1 |
| Thời gian | TIMEZONE_SPEC — nghiệp vụ theo giờ Việt Nam, lưu UTC |
| Media | Mọi video app-ready không có audio stream; tiếng Hana chỉ từ TTS |
| Khả năng bảo trì | Mọi prompt versioned; Fake gateway cho test; import-linter; test cách ly |
| Kích thước APK | Chấp nhận ≤ 250 MB (sideload cá nhân) |
| Pin | Không chạy nền liên tục; không ghi âm nền; video pause khi background |
| Khả năng tiếp cận | Chữ tối thiểu 14sp, hỗ trợ font scale hệ thống, nút mic ≥ 64dp |

---

## 9. Chỉ số theo dõi (cục bộ, không gửi bên thứ ba)

| Chỉ số | Mục tiêu v1 |
|---|---|
| Tỉ lệ turn `completed` / tổng turn | ≥ 98% |
| Tỉ lệ envelope hợp lệ ngay lần đầu | ≥ 95% |
| Tỉ lệ TTS thành công | ≥ 98% |
| Reminder nổ trễ > 60 s (đã sync) | ≤ 1% |
| Report tạo thành công đúng hạn | 100% (có catch-up) |
| Rò rỉ private (bộ test ISO) | 0 |

---

## 10. Giả định và ràng buộc

| # | Giả định / ràng buộc |
|---|---|
| A1 | 43 video trong `assets_source` đủ để phủ 10 core state normal sau khi gắn nhãn (cần xác minh ở phase phân tích asset) |
| A2 | 9Router cung cấp được model chat, STT tiếng Việt, TTS tiếng Việt chất lượng chấp nhận được qua endpoint OpenAI-compatible. **Provider STT/TTS: UNRESOLVED**, benchmark ở voice phase |
| A3 | Có một model/route qua 9Router cho phép nội dung người lớn hư cấu cho private mode. **Provider private LLM: UNRESOLVED**, benchmark ở private mode phase |
| A4 | FCM là **tùy chọn**: không có Firebase project thì push tắt, reminder cục bộ vẫn hoạt động đầy đủ, tin Hana/báo cáo đến qua đồng bộ nền |
| A5 | VPS Linux có Docker, domain + TLS cho staging/production |
| A6 | Chỉ một người dùng; không cần phân quyền nhiều người |

---

## 11. Lộ trình đề xuất (chưa bắt đầu; chỉ để định hướng)

| Phase | Nội dung |
|---|---|
| 1 | Tài liệu nền (phase này) |
| 2 | Scaffolding repo + infra local (compose, DB roles, migrations khung, Flutter khung, CI lint) |
| 3 | Asset analysis + gắn nhãn + pipeline mute + manifest |
| 4 | Backend core: auth, turns, AI protocol, Character Director, SSE |
| 5 | Flutter core: chat, Character Engine, VideoStage |
| 6 | Voice: PTT, STT, TTS |
| 7 | Tasks/reminders/notifications + scheduler |
| 8 | Memory + relationship + daily companion |
| 9 | Work journal + standing instructions + reports |
| 10 | Private mode |
| 11 | Hardening, toàn bộ ACCEPTANCE_CRITERIA, staging VPS |
| 12 | Production |
