# HANA PHASE 3 — VISUAL CLASSIFICATION REPORT

> **Đã được thay thế một phần bởi `PHASE_3_2_ASSET_POLICY_PATCH.md` (2026-09-15).** Dữ liệu quan sát (identity, loop grade, confidence, near-duplicates) vẫn giữ nguyên giá trị. Các diễn giải chính sách sau **không còn hiệu lực**: §3 và §8 (`category=private` = cấm ngoài private mode), §4–§5 (yêu cầu coverage normal, `state=none`), §10 (review = chờ loại), §12.1–§12.3 (loại 2 clip reject, `coverage_waiver`, chỉ dùng 22 clip keep). Ghi chú số liệu: §6.2 ghi loop 9 / oneshot 34, nhưng `classification.json` có loop 8 / oneshot 35 (`MNZY6791` loop grade B nhưng `playback_kind=oneshot`) — `classification.json` là nguồn đúng.

- **Status**: **PASS**
- **Date**: 2026-09-15
- **Role**: Visual Classifier for Character Asset Library (Hana)
- **Input Corpus**: `asset_analysis/inventory.json`, `asset_analysis/visual_index.json` (43 source videos)
- **Outputs**: `asset_analysis/classification.json`, `asset_analysis/classification.csv`
- **Canonical Specification Reference**: `CHARACTER_SYSTEM.md`, `ARCHITECTURE.md`, `PRIVACY_SPEC.md`, `ACCEPTANCE_CRITERIA.md`, `PHASE_2_REPORT.md`

---

## 1. Tổng số video

- **Tổng số video phân tích**: **43 / 43** (100% hoàn thành)
- **Phân bổ theo nhóm kỹ thuật (Phase 2 probe)**:
  - **Nhóm A (544×544, 1:1, 6.04s, 24fps)**: 17 video
  - **Nhóm B (720×1280, 9:16, 10.04s, 24fps)**: 14 video
  - **Nhóm C (768×1168, ~2:3, 10.04s, 24fps)**: 12 video
- **Tình trạng nguồn**: Nguyên vẹn, không có file nguồn nào bị sửa, đổi tên, di chuyển hoặc chuyển mã. Toàn bộ checksum khớp `inventory.json`.

---

## 2. Thống kê Quyết định (Decision)

| Quyết định | Số lượng | Tỷ lệ | Tiêu chuẩn áp dụng |
|---|---|---|---|
| **keep** | **22** | 51.2% | Chất lượng hình ảnh tốt, tính nhất quán nhân vật cao, motion ổn định, confidence ≥ 0.80. |
| **review** | **19** | 44.2% | Cần người duyệt do độ tương đồng thị giác cao (near-duplicate candidates), loop boundary không rõ, hoặc confidence < 0.80 (tuân thủ Quy tắc 8 & 12). |
| **reject** | **2** | 4.6% | `DFRT1741.MP4`, `KKWB4339.MP4` — chứa jump cut góc quay gắt, đứt đoạn tư thế nghiêm trọng (discontinuity), không phù hợp phát lại trên character stage. |
| **Tổng** | **43** | **100.0%** | |

---

## 3. Phân loại Category

| Category | Số lượng | Tỷ lệ | Giải thích |
|---|---|---|---|
| **private** | **43** | 100.0% | Toàn bộ 43 clip nguồn đều chứa nội dung nhạy cảm / khỏa thân / đồ ngủ hở ngực. Theo `PRIVACY_SPEC` §10.3 và `CHARACTER_SYSTEM` §4.2, tuyệt đối không đưa sang normal mode. |
| **core** | **0** | 0.0% | Không có asset trang phục thường ngày phù hợp làm animation nền normal. |
| **reaction** | **0** | 0.0% | Không có reaction asset normal. |
| **special** | **0** | 0.0% | Không có special asset normal. |
| **unknown** | **0** | 0.0% | Mọi clip đều xác định rõ ràng là private asset. |

---

## 4. Coverage của 10 Core States (Normal Mode)

Tuân thủ Quy tắc 13: *"category private không được gán normal core semantics"*. Vì 100% kho nguồn là private asset, độ phủ của normal core states hiện tại là **0**:

| Core State | Loại | Yêu cầu App | Số lượng Asset | Tình trạng |
|---|---|---|---|---|
| `idle` | activity | Loop nền mặc định | **0** | Thiếu |
| `listening` | activity | PTT đang giữ | **0** | Thiếu |
| `talking` | activity | TTS đang phát | **0** | Thiếu |
| `thinking` | activity | Turn đang chờ | **0** | Thiếu |
| `happy` | emotion | Phản hồi vui | **0** | Thiếu |
| `shy` | emotion | Phản hồi ngại ngùng | **0** | Thiếu |
| `surprised` | emotion | Phản ứng bất ngờ | **0** | Thiếu |
| `concerned` | emotion | Phản ứng lo lắng / lỗi | **0** | Thiếu |
| `working` | activity | Tác vụ nền dài | **0** | Thiếu |
| `sleep` | activity | Quiet hours / idle lâu | **0** | Thiếu |

---

## 5. Phân bổ State

- **State có 0 asset**: 10 state (`idle`, `listening`, `talking`, `thinking`, `happy`, `shy`, `surprised`, `concerned`, `working`, `sleep`)
- **State có 1 asset**: 0 state
- **State có nhiều asset**: `none`: **43** asset (tất cả private assets đều gắn `state = "none"` để bảo vệ tính cách ly ngữ nghĩa)

---

## 6. Phân bổ Loop Grade & Playback Kind

### 6.1 Loop Grade

| Grade | Số lượng | Tiêu chí | Danh sách clip tiêu biểu |
|---|---|---|---|
| **A** (Gần seamless) | **2** | Sai lệch điểm đầu/cuối rất thấp (match ≥ 0.92), camera tĩnh, tư thế giữ nguyên. | `LXEZ3296.MP4` (0.925), `WXYU8680.MP4` (0.921) |
| **B** (Loop được với crossfade nhẹ) | **7** | Tư thế đầu/cuối tương đồng tốt (match 0.60..0.85), chuyển động nhịp thở/nghiêng nhẹ. | `KNRQ5338.MP4`, `GZRZ3107.MP4`, `HOIJ9018.MP4`, `EZRB0829.MP4`, `JEPK9717.MP4`, `MNZY6791.MP4`, `MMMD2325.MP4` |
| **C** (Loop thấy điểm nối) | **17** | Có chuyển dịch tư thế hoặc chuyển động tay/đầu; ưu tiên phát oneshot hoặc loop có crossfade dài. | `AYAB0517.MP4`, `LCHY0735.MP4`, `KPJR0660.MP4`, `MDBL5375.MP4`, `OGNR9411.MP4`, `AXXF9103.MP4`, `ECOT1008.MP4`, `SBDE7512.MP4`, ... |
| **D** (Không phù hợp loop) | **17** | Thay đổi tư thế hoàn toàn (ngồi sang nằm, quay lưng, cúi người, thức dậy); chỉ phát oneshot. | `DFRT1741.MP4`, `KKWB4339.MP4`, `GAOW0715.MP4`, `IBFT8450.MP4`, `ARRJ9858.MP4`, `VXMN4535.MP4`, `BSOO5255.MP4`, `MBYF9623.MP4`, `BQLH6157.MP4`, ... |

### 6.2 Playback Kind

- **loop**: **9** clip (Grade A & B có độ ổn định cao để lặp vô hạn)
- **oneshot**: **34** clip (Grade C & D có diễn tiến hành động cụ thể)

---

## 7. Đánh giá Tính nhất quán Nhân vật (Identity Consistency)

- **Identity Consistency**: **43 / 43 pass** (100%). Nhân vật nữ trưởng thành nhất quán về khuôn mặt Á Đông, mắt hai mí sắc nét, tóc đen dài bồng bềnh có ngôi/mái đặc trưng.
- **Face Consistency**:
  - **pass**: **40** clip
  - **minor_issue**: **3** clip (`DFRT1741.MP4`, `KKWB4339.MP4`, `CECO9917.MP4`) do chuyển động camera và đầu quá nhanh làm biến dạng nhẹ đường viền mặt.
  - **fail**: 0 clip
- **Outfit Consistency**: **43 / 43 pass**.
  - Nhóm A (17 clip): Áo vest đen mở cúc, cà vạt đen buông, vòng cổ choker mặt tim kim loại nhỏ đồng nhất 100%.
  - Nhóm B & C (26 clip): Khỏa thân nghệ thuật toàn phần hoặc bán phần nhất quán theo series chụp mẫu.

---

## 8. Nghi ngờ Private (Private Suspected Count)

- **private_suspected = true**: **0** clip.
- Toàn bộ 43/43 video đều chứa hình ảnh khỏa thân hoặc trang phục hở hang rõ ràng, không có trường hợp ranh giới mập mờ. Do đó tất cả được gán dứt khoát `category = "private"`, `private_suspected = false`.

---

## 9. Thống kê Confidence

- **Confidence ≥ 0.80**: **24** clip (22 keep, 2 reject do lỗi kỹ thuật cắt cảnh).
- **Confidence < 0.80**: **19** clip (tất cả 19 clip đều có `decision = "review"` theo Quy tắc 8).
- Không có bất kỳ clip nào có `confidence < 0.80` mà được gắn nhãn `keep`.

---

## 10. Danh sách các Clip Cần Người Duyệt (Review Queue)

Tất cả **19 clip** dưới đây có `decision: review` và cần kỹ thuật viên / đạo diễn duyệt lại trong Phase 4:

| STT | File nguồn | Source ID | Conf | Loop | Lý do & Ứng viên trùng lặp thị giác (Near-Duplicates) |
|---|---|---|---|---|---|
| 1 | `LCHY0735.MP4` | `src_1b35ba3c3b1bd863_29c091d0` | 0.76 | C | Near-duplicate candidate với `MDBL5375.MP4`, `RDOC5978.MP4` (cùng tư thế quỳ trên giường đệm tím, tay sau gáy). |
| 2 | `MDBL5375.MP4` | `src_1b522e4695217e9b_eb00c92b` | 0.74 | C | Near-duplicate candidate với `LCHY0735.MP4`, `RDOC5978.MP4`. |
| 3 | `RDOC5978.MP4` | `src_bda13d41375e0e1a_b0a3238d` | 0.75 | C | Near-duplicate candidate với `LCHY0735.MP4`, `MDBL5375.MP4`. |
| 4 | `OGNR9411.MP4` | `src_a79e88fb54d01426_78a547c8` | 0.75 | C | Near-duplicate candidate với `BHGW7313.MP4`, `BBDR6876.MP4` (frame đầu giống hệt nhau diff < 0.2). |
| 5 | `BHGW7313.MP4` | `src_e9309a7764a6f4f4_9e0c1ce9` | 0.76 | C | Near-duplicate candidate với `OGNR9411.MP4`, `BBDR6876.MP4`. |
| 6 | `BBDR6876.MP4` | `src_fe9dd845248fa3e7_ff2a2288` | 0.75 | D | Near-duplicate candidate với `OGNR9411.MP4`, `BHGW7313.MP4`. |
| 7 | `SANI5812.MP4` | `src_7e03c4eae207419b_08b6353a` | 0.76 | C | Near-duplicate candidate với `KPJR0660.MP4` (tư thế bên cửa sổ ban đêm). |
| 8 | `KPJR0660.MP4` | `src_a7ef672aa079e488_fdd7697e` | 0.76 | C | Near-duplicate candidate với `SANI5812.MP4`. |
| 9 | `KNRQ5338.MP4` | `src_28afcdaf2e6c0c1e_351c5443` | 0.78 | B | Near-duplicate candidate với `HOIJ9018.MP4` (mẫu đứng toàn thân phông trắng, diff trung bình 12.68). |
| 10 | `HOIJ9018.MP4` | `src_aa3e6b4d4a6a8298_a2382254` | 0.78 | B | Near-duplicate candidate với `KNRQ5338.MP4`. |
| 11 | `MMMD2325.MP4` | `src_705ce91a59e669f8_b552dcf3` | 0.77 | B | Near-duplicate candidate với `RBQJ4191.MP4` (Nhóm A góc quay trung cảnh bán thân rất gần nhau). |
| 12 | `RBQJ4191.MP4` | `src_d51db77e63e77e55_64bb5285` | 0.77 | C | Near-duplicate candidate với `MMMD2325.MP4`. |
| 13 | `ECOT1008.MP4` | `src_0408397b794fb5f6_55c90d51` | 0.75 | C | Biểu cảm ngạc nhiên / hé môi, điểm nối loop có giật nhẹ, cần duyệt điểm cắt trim. |
| 14 | `DAIM1610.MP4` | `src_337807b74d2a51de_2e8b3aa0` | 0.72 | D | Camera zoom out nhanh, cường độ chuyển động cao (0.80), cần duyệt framing. |
| 15 | `KCBG9830.MP4` | `src_39f2c3d860fbf205_82a50643` | 0.75 | D | Góc máy hạ thấp, chuyển động gập người về phía trước, cần duyệt độ phù hợp. |
| 16 | `JRQD8891.MP4` | `src_55ad7dd39b872eb9_489ff494` | 0.74 | D | Xoay góc máy 180 độ ra phía sau, cần duyệt tính tương thích sân khấu. |
| 17 | `ARRJ9858.MP4` | `src_bc162a396ea66856_e3e8752e` | 0.73 | D | Xoay góc máy sang sau lưng, có bước nhảy khung hình. |
| 18 | `CECO9917.MP4` | `src_fe00e7ac7eddcc65_8a7c3578` | 0.71 | C | Cường độ chuyển động rất lớn (0.89), máy quay lia gấp, cần duyệt ổn định thị giác. |
| 19 | `JEYK8192.MP4` | `src_fea53725a74dcc1c_61895406` | 0.74 | D | Nhảy từ trung cảnh sang toàn cảnh góc thấp, đứt đoạn bố cục. |

---

## 11. Đề xuất Semantic Cue Ứng viên (Private Catalog Candidates)

Các đề xuất dưới đây tuân thủ quy tắc trung tính chức năng, không mô tả chi tiết nhạy cảm:

| Semantic Cue Ứng viên | Mode | Clip phù hợp | Mô tả chức năng |
|---|---|---|---|
| `private_idle` | private | `LXEZ3296.MP4`, `WXYU8680.MP4`, `JEPK9717.MP4` | Vòng lặp nền tĩnh / thở nhẹ cho private mode stage. |
| `private_pose` | private | `GZRZ3107.MP4`, `EZRB0829.MP4`, `AYAB0517.MP4`, `BQLH6157.MP4` | Tư thế tạo dáng người mẫu toàn thân. |
| `private_working` | private | `MBYF9623.MP4`, `VXMN4535.MP4` | Hana làm việc tại bàn (vẽ wacom tablet, gõ laptop). |
| `private_sleep` | private | `BSOO5255.MP4`, `GAOW0715.MP4` | Hana thức dậy trên giường hoặc ngả lưng nghỉ ngơi. |
| `private_reaction_shy` | private | `SBDE7512.MP4`, `WRKX9090.MP4` | Phản ứng ngại ngùng, bẽn lẽn. |
| `private_reaction_happy` | private | `XNPM3086.MP4`, `BIOI9071.MP4`, `QOGV4635.MP4` | Phản ứng cười tươi, vui vẻ. |
| `private_reaction_concerned` | private | `IBFT8450.MP4` | Biểu cảm lo lắng, băn khoăn. |
| `private_reaction_speaking` | private | `AXXF9103.MP4` | Chuyển động miệng như đang nói chuyện. |

---

## 12. Gap Analysis & Khuyến nghị Kiến trúc cho Ứng dụng

### 12.1 Thực trạng Kho Tài nguyên Hiện tại
1. **Thiếu hoàn toàn Normal Mode Assets**: Toàn bộ 43 file video nguồn đều là asset nhạy cảm thuộc Private Mode. Không có video nào được phép đóng gói vào Normal bundle của ứng dụng theo quy định bảo mật `INV-05` và `PRIVACY_SPEC`.
2. **Kho Private Mode Đầy đủ**: Private mode có nguồn tài nguyên phong phú (22 asset `keep`, 19 asset `review`) đủ cho các trạng thái idle, làm việc, nghỉ ngơi và phản ứng cảm xúc.

### 12.2 Tác động tới Tiêu chuẩn Nghiệm thu (Acceptance Criteria)
- Tiêu chí **AC-CHR-05**: *"Mọi CoreState có ≥ 1 asset normal hoặc có coverage_waiver được ghi rõ"*.
- Tiêu chí **INV-18**: *"Fallback chain khi thiếu clip: pool(state) rỗng → pool(idle) → poster → placeholder silhouette bundle"*.

### 12.3 Khuyến nghị Hành động cho Phase 4 & Dự án
1. **Về phía Normal Mode**:
   - Khởi tạo danh sách `coverage_waiver` cho toàn bộ 10 CoreState trong cấu hình `labels.yaml` của Phase 4 để asset pipeline không bị build fail.
   - Client VideoStage kích hoạt fallback chain an toàn: sử dụng placeholder poster tĩnh / silhouette (`assets/character/fallback.png`) cho phiên bản build hiện tại.
   - Đề xuất bổ sung một đợt thu thập / sinh asset nguồn mới với trang phục công sở / đời thường cho nhân vật Hana để phủ đủ 10 core states cho Normal mode.
2. **Về phía Private Mode**:
   - Sử dụng 22 asset `keep` để xây dựng `private_manifest.json` trong Phase 4.
   - 19 clip `review` cần được kỹ thuật viên đưa qua giao diện duyệt nhãn (duyệt near-duplicates để chọn clip tối ưu nhất cho từng cụm).
   - 2 clip `reject` (`DFRT1741.MP4`, `KKWB4339.MP4`) nên được loại bỏ hoàn toàn khỏi manifest xuất xưởng do lỗi cắt cảnh thị giác.
