# HANA PHASE 3.2 — ASSET POLICY PATCH: DÙNG TOÀN BỘ 43 VIDEO

- **Trạng thái**: PASS (xem §12)
- **Ngày**: 2026-09-15
- **Loại phase**: chỉ tài liệu. Không code, không transcode, không sửa `assets_source/` hay `asset_analysis/`.
- **Input**: `asset_analysis/classification.json`, `asset_analysis/inventory.json` (chỉ để lấy nhóm độ phân giải), `repo/docs/VISUAL_CLASSIFICATION_REPORT.md`
- **Quyết định sản phẩm**: ứng dụng cá nhân; owner dùng cả 43 video nguồn làm animation library của Hana. Nhãn `private` của Phase 3 không còn nghĩa là "cấm dùng ngoài private mode".

---

## 1. Tóm tắt thay đổi

| Trước (Phase 1 / Phase 3) | Sau (Phase 3.2) |
|---|---|
| Asset có một trục `mode: normal|private` (Phase 3 gọi là `category=private`) quyết định cả nội dung lẫn nơi hiển thị | Hai trục tách biệt: `content_sensitivity` (`normal|suggestive|private`) mô tả nội dung; `allowed_modes` (⊆ `daily|assistant|relationship|private`) + Owner Asset Policy quyết định nơi hiển thị |
| 43/43 = private ⇒ normal mode có 0 asset, cần `coverage_waiver` cho 10 state | 15 clip dùng được ở `daily`/`assistant`, 41 ở `relationship`/`private` theo mặc định; 2 clip còn lại được publish nhưng tắt mặc định, owner bật lại được |
| Mỗi CoreState phải có ≥ 1 asset normal, thiếu thì build fail | Không yêu cầu asset riêng cho từng state; nhiều state dùng chung pool (`primary`/`shared`); thiếu thì fallback, không fail build |
| 2 clip `reject` bị loại khỏi manifest | Giữ lại: `technical_quality=poor`, `kind=oneshot`, `weight=0.2`, `excluded_by_default=true` |
| 19 clip `review` chờ duyệt, không vào manifest | Giữ lại: `review_flag=true`, `weight` 0.4–0.5, không làm main-loop |
| Private asset: không trong APK, chỉ qua private session | Phân phối theo `delivery` suy ra: `bundle` (chỉ `normal`), `vault` (sensitivity ≥ suggestive, được phép ở normal zone; JWT + cache mã hóa), `private_vault` (chỉ `[private]`; private session) |
| Asset ID `{n|p}.{class}.{state}.{nn}` | `chr_{nnn}` opaque (không mã hóa state/mode/sensitivity/tên nguồn) |

---

## 2. Invariant được giữ nguyên (không đổi)

| Invariant | Nội dung | Nơi enforce |
|---|---|---|
| INV-02 | LLM và backend không bao giờ gửi/quyết định filename, path, asset_id, URL video | CHARACTER_SYSTEM §6.1; AI_PROTOCOL §1, AIP-05, AIP-06 |
| INV-21 (mới, siết thêm) | LLM không thấy/chọn/biết asset_id, filename, `content_sensitivity`, `allowed_modes`, `stage_context`; không action nào đổi owner asset policy | AI_PROTOCOL §4.2, §7.2, AIP-06 |
| Chọn asset | Chỉ Character Engine (client) qua Asset Policy Engine thuần | CHARACTER_SYSTEM §1, §11, CHR-06 |
| INV-03 | Mọi video app-ready 0 audio stream, player volume 0, `mixWithOthers=true`; áp dụng cho mọi sensitivity/delivery/cờ | CHARACTER_SYSTEM §5.1 (M1–M10) |
| Giọng | Âm thanh duy nhất của Hana là TTS | CHARACTER_SYSTEM M6; VOICE_SPEC |
| INV-16 | `assets_source` bất biến | pipeline read-only + checksum |
| Cách ly dữ liệu private | Không đổi: DB/Redis/queue/route/notification/PIN | PRIVACY_SPEC §5–§13 |

---

## 3. Mô hình mới

### 3.1 Hai trục

**`content_sensitivity`** — nội dung là gì (gán ở `labels.yaml`, thiếu → `private`):

| Giá trị | Rank | Ý nghĩa |
|---|---|---|
| `normal` | 0 | Trang phục thường ngày, không nhạy cảm |
| `suggestive` | 1 | Gợi cảm / hở một phần, không khỏa thân |
| `private` | 2 | Khỏa thân hoặc tương đương |

**`allowed_modes`** — được hiển thị ở StageContext nào (gán ở `labels.yaml`, owner override được lúc runtime, thiếu → `[private]`):

| StageContext | Zone | Khi nào |
|---|---|---|
| `daily` | normal | mặc định, trò chuyện thường, chào sáng/hỏi thăm |
| `assistant` | normal | action nghiệp vụ, reminder, report, job dài (`working`) |
| `relationship` | normal | trò chuyện tình cảm, chỉ khi owner bật `relationship_stage_enabled` |
| `private` | private | mọi thứ trong private session |

Zone (`normal|private`) vẫn là ranh giới cách ly dữ liệu. StageContext chỉ dùng để chọn hình ảnh.

### 3.2 Delivery (suy ra, không gán tay)

```
private_vault  nếu allowed_modes == [private]
bundle         nếu content_sensitivity == normal
vault          còn lại
```

Seed hiện tại: 0 bundle, 43 vault, 0 private_vault. APK không chứa video nào; chỉ có silhouette `fallback.png`.

### 3.3 Các trường chất lượng / duyệt

| Trường | Giá trị | Tác động |
|---|---|---|
| `technical_quality` | `good|fair|poor` | `poor` không làm main-loop, không phát 2 lần liên tiếp, không làm clip đầu tiên |
| `review_flag` | bool | không làm main-loop khi có lựa chọn khác; weight thấp hơn |
| `excluded_by_default` | bool | publish nhưng không eligible; owner bật lại bằng override `enabled=true` |
| `hard_block` | bool | chỉ dùng cho vi phạm giới hạn tuyệt đối PRIVACY_SPEC §10.1; không publish, owner không bật lại được. Seed: 0 clip |
| `weight` | 0.05..10 | trọng số gốc |
| `states` | `{CoreState: primary|shared}` | pool dùng chung; `shared` nhân trọng số 0.5 |
| `cues` | `[SpecialCue]` | special video |

---

## 4. Owner policy

### 4.1 Cài đặt toàn cục (`hana.asset_policy`)

| Cài đặt | Mặc định | Tác động |
|---|---|---|
| `relationship_stage_enabled` | `false` | `true` → Director có thể phát `stage_context=relationship`; tắt → mọi relationship quy về `daily` |
| `relationship_trigger` | `affection` | `affection`: chỉ khi emotion `shy`, `happy` ≥ medium, hoặc cue chỉ dành cho relationship; `conversation`: mọi reply không có action nghiệp vụ |
| `stage_discreet` | `false` | stage normal zone chỉ hiện silhouette |
| `stage_secure_window` | `auto` | FLAG_SECURE trên Home khi library normal có asset eligible với sensitivity ≥ suggestive |

### 4.2 Override theo asset (`hana.asset_policy_overrides`; private_vault: `hana_private.private_asset_policy_overrides`)

- `enabled` (null/true/false): bật lại clip `excluded_by_default`, hoặc tắt clip bất kỳ.
- `allowed_modes`: nới hoặc thu hẹp. Thêm `daily`/`assistant` cho asset sensitivity ≥ suggestive mà labels không có → bắt buộc `confirm_sensitive=true` (422 nếu thiếu).
- `weight_multiplier` 0.00..4.00.
- Không override được `content_sensitivity`, `delivery`, `hard_block`, `states`, `cues` (chỉ qua labels + publish lại).
- Chỉ đổi qua UI Cài đặt. Không có action LLM, lệnh chat hay `settings.update` key nào đổi policy.

---

## 5. Quy tắc theo mode

| Mode | Candidate | Ưu tiên | Fallback khi rỗng |
|---|---|---|---|
| `daily` | asset eligible có `daily ∈ allowed_modes` | **chỉ tier sensitivity thấp nhất** có mặt trong pool của state đó (CHR-07); main-loop trước variant | state → idle(daily) → poster → silhouette |
| `assistant` | `assistant ∈ allowed_modes` | như daily | state → idle(assistant) → state(daily) → idle(daily) → poster → silhouette |
| `relationship` | `relationship ∈ allowed_modes`, chỉ khi owner bật | không lọc tier; main-loop trước variant | state → idle(relationship) → state(daily) → idle(daily) → poster → silhouette |
| `private` | `private ∈ allowed_modes`, chỉ private engine | không lọc tier; toàn bộ asset được allow | state → idle(private) → poster → silhouette |

Quy tắc chung:

- Overlay (emotion/special) không có asset → bỏ overlay, giữ clip đang chạy.
- Fallback **không** mượn asset không eligible cho context đang dùng.
- Thiếu coverage → cảnh báo trong `coverage_report.json`, **không** fail build.
- Trọng số hiệu dụng: `weight × weight_multiplier × fit` (`primary` 1.0, `shared` 0.5).
- Activity state: `M` = loop ∧ ¬review ∧ quality≠poor → main; còn lại là variant, chọn với xác suất 0.2, không chọn variant 2 lần liên tiếp; `M` rỗng thì variant đóng vai chính.
- `stage_context` do Director tính **xác định** từ action đã validate, sự kiện hệ thống và cờ owner (CHARACTER_SYSTEM §8.5), không do LLM. Normal engine nhận `private` → coi là `daily`.

---

## 6. Ánh xạ từ nhãn Phase 3

| Trường Phase 3 | Trường Phase 3.2 | Luật |
|---|---|---|
| `category=private` | `content_sensitivity` | Nhóm A (544×544; Phase 3 §7: vest đen mở cúc, cà vạt, choker) → `suggestive` **provisional**; nhóm B/C (Phase 3 §7: khỏa thân toàn phần/bán phần) → `private`. `sensitivity_source` ghi rõ; owner xác nhận ở Phase 4 |
| (không có) | `allowed_modes` | `suggestive` → `[daily, assistant, relationship, private]`; `private` → `[relationship, private]` |
| `decision=reject` | `technical_quality=poor`, `kind=oneshot`, `weight=0.2`, `excluded_by_default=true` | 2 clip |
| `decision=review` | `review_flag=true`, `weight` 0.5 (good) / 0.4 (fair) | 19 clip |
| `decision=keep` | `review_flag=false`, `weight` 1.0 (good) / 0.8 (fair) | 22 clip |
| `face_consistency=minor_issue` hoặc `motion_intensity ≥ 0.70` (không reject) | `technical_quality=fair` | 8 clip |
| còn lại | `technical_quality=good` | 33 clip |
| `playback_kind` | `kind` | giữ nguyên (reject ép `oneshot`) |
| `state=none`, `semantic_cue=null` | `states`, `cues` | bảng §7 là **đề xuất**, dựa trên `expression` + `reason` + Phase 3 §11; Phase 4 xác nhận trên contact sheet |

Nếu owner không xác nhận nhóm A là `suggestive` ở Phase 4 (giữ `private`), daily/assistant vẫn chạy: tier thấp nhất trong pool khi đó là `private` và các asset vẫn eligible nhờ `allowed_modes`. Tier filter dựa trên thứ hạng tương đối trong thư viện, không dựa trên ngưỡng tuyệt đối.

---

## 7. Seed policy theo clip (43/43)

Bảng sinh xác định bằng script đọc `classification.json` + `inventory.json` (sắp theo tên nguồn; `asset_id` gán theo thứ tự này và cố định từ đây). Tên nguồn chỉ xuất hiện trong tài liệu dev/`asset_analysis`, không ship.

| asset_id | Nguồn (chỉ asset_analysis) | Nhóm | content_sensitivity | allowed_modes (seed) | technical_quality | review_flag | excluded_by_default | playback_kind | loop | weight | state pools (P=primary, S=shared) | cue ứng viên |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `chr_001` | `ARRJ9858.MP4` | A | suggestive | daily,assistant,relationship,private | fair | true | false | oneshot | D | 0.4 | idle:S | — |
| `chr_002` | `AXXF9103.MP4` | A | suggestive | daily,assistant,relationship,private | good | false | false | oneshot | C | 1.0 | talking:P | — |
| `chr_003` | `AYAB0517.MP4` | B | private | relationship,private | good | false | false | oneshot | C | 1.0 | idle:S | — |
| `chr_004` | `BBDR6876.MP4` | B | private | relationship,private | fair | true | false | oneshot | D | 0.4 | idle:S | — |
| `chr_005` | `BHGW7313.MP4` | B | private | relationship,private | good | true | false | oneshot | C | 0.5 | idle:S | greeting |
| `chr_006` | `BIOI9071.MP4` | A | suggestive | daily,assistant,relationship,private | good | false | false | oneshot | C | 1.0 | happy:P | — |
| `chr_007` | `BQLH6157.MP4` | C | private | relationship,private | good | false | false | oneshot | D | 1.0 | idle:S | playful |
| `chr_008` | `BSOO5255.MP4` | C | private | relationship,private | good | false | false | oneshot | D | 1.0 | sleep:P | — |
| `chr_009` | `CECO9917.MP4` | A | suggestive | daily,assistant,relationship,private | fair | true | false | oneshot | C | 0.4 | idle:S | — |
| `chr_010` | `DAIM1610.MP4` | A | suggestive | daily,assistant,relationship,private | fair | true | false | oneshot | D | 0.4 | idle:S | — |
| `chr_011` | `DFRT1741.MP4` | A | suggestive | daily,assistant,relationship,private | poor | false | true | oneshot | D | 0.2 | idle:S | — |
| `chr_012` | `ECOT1008.MP4` | C | private | relationship,private | good | true | false | oneshot | C | 0.5 | surprised:P | — |
| `chr_013` | `EZRB0829.MP4` | C | private | relationship,private | good | false | false | loop (main-loop) | B | 1.0 | shy:P, idle:S | — |
| `chr_014` | `GAOW0715.MP4` | B | private | relationship,private | good | false | false | oneshot | D | 1.0 | sleep:P | — |
| `chr_015` | `GZRZ3107.MP4` | C | private | relationship,private | good | false | false | loop (main-loop) | B | 1.0 | idle:S, happy:S | — |
| `chr_016` | `HOIJ9018.MP4` | C | private | relationship,private | good | true | false | loop | B | 0.5 | idle:S, happy:S | — |
| `chr_017` | `IBFT8450.MP4` | B | private | relationship,private | fair | false | false | oneshot | D | 0.8 | concerned:P | — |
| `chr_018` | `JEPK9717.MP4` | A | suggestive | daily,assistant,relationship,private | good | false | false | loop (main-loop) | B | 1.0 | idle:P, listening:S, talking:S | — |
| `chr_019` | `JEYK8192.MP4` | A | suggestive | daily,assistant,relationship,private | fair | true | false | oneshot | D | 0.4 | idle:S | — |
| `chr_020` | `JRQD8891.MP4` | A | suggestive | daily,assistant,relationship,private | fair | true | false | oneshot | D | 0.4 | idle:S | — |
| `chr_021` | `KCBG9830.MP4` | B | private | relationship,private | good | true | false | oneshot | D | 0.5 | idle:S | — |
| `chr_022` | `KKWB4339.MP4` | A | suggestive | daily,assistant,relationship,private | poor | false | true | oneshot | D | 0.2 | idle:S | — |
| `chr_023` | `KNRQ5338.MP4` | C | private | relationship,private | good | true | false | loop | B | 0.5 | idle:S, listening:S | — |
| `chr_024` | `KPJR0660.MP4` | B | private | relationship,private | good | true | false | oneshot | C | 0.5 | idle:S | — |
| `chr_025` | `LCHY0735.MP4` | B | private | relationship,private | good | true | false | oneshot | C | 0.5 | idle:S | — |
| `chr_026` | `LXEZ3296.MP4` | C | private | relationship,private | good | false | false | loop (main-loop) | A | 1.0 | idle:P, listening:S, thinking:S | — |
| `chr_027` | `MBYF9623.MP4` | C | private | relationship,private | good | false | false | oneshot | D | 1.0 | working:P | — |
| `chr_028` | `MDBL5375.MP4` | B | private | relationship,private | good | true | false | oneshot | C | 0.5 | idle:S | — |
| `chr_029` | `MMMD2325.MP4` | A | suggestive | daily,assistant,relationship,private | good | true | false | loop | B | 0.5 | idle:S, talking:S | — |
| `chr_030` | `MNZY6791.MP4` | A | suggestive | daily,assistant,relationship,private | good | false | false | oneshot | B | 1.0 | thinking:P | — |
| `chr_031` | `OGNR9411.MP4` | B | private | relationship,private | good | true | false | oneshot | C | 0.5 | idle:S | — |
| `chr_032` | `QOGV4635.MP4` | C | private | relationship,private | good | false | false | oneshot | C | 1.0 | happy:P | — |
| `chr_033` | `RBQJ4191.MP4` | A | suggestive | daily,assistant,relationship,private | good | true | false | oneshot | C | 0.5 | shy:S, happy:S | — |
| `chr_034` | `RDOC5978.MP4` | B | private | relationship,private | good | true | false | oneshot | C | 0.5 | surprised:P | — |
| `chr_035` | `RKUV3687.MP4` | A | suggestive | daily,assistant,relationship,private | good | false | false | oneshot | C | 1.0 | idle:S | — |
| `chr_036` | `SANI5812.MP4` | B | private | relationship,private | good | true | false | oneshot | C | 0.5 | idle:S | — |
| `chr_037` | `SBDE7512.MP4` | C | private | relationship,private | good | false | false | oneshot | C | 1.0 | shy:P | — |
| `chr_038` | `VEZT1070.MP4` | C | private | relationship,private | fair | false | false | oneshot | D | 0.8 | idle:S | — |
| `chr_039` | `VXMN4535.MP4` | B | private | relationship,private | good | false | false | oneshot | D | 1.0 | working:P | — |
| `chr_040` | `WRKX9090.MP4` | A | suggestive | daily,assistant,relationship,private | good | false | false | oneshot | D | 1.0 | shy:P | — |
| `chr_041` | `WXYU8680.MP4` | B | private | relationship,private | good | false | false | loop (main-loop) | A | 1.0 | idle:P, listening:S, thinking:S | — |
| `chr_042` | `XNPM3086.MP4` | A | suggestive | daily,assistant,relationship,private | good | false | false | oneshot | D | 1.0 | happy:P | — |
| `chr_043` | `YITD3424.MP4` | A | suggestive | daily,assistant,relationship,private | good | false | false | oneshot | C | 1.0 | happy:S | greeting |

Thống kê seed: nhóm A 17 / B 14 / C 12 · `suggestive` 17 / `private` 26 · quality good 33 / fair 8 / poor 2 · `review_flag` 19 · `excluded_by_default` 2 · loop 8 / oneshot 35 · main-loop 5 · 43/43 thuộc ≥ 1 pool · eligible mặc định: daily 15, assistant 15, relationship 41 (khi bật), private 41.

---

## 8. Coverage theo seed (chỉ để báo cáo, không phải điều kiện build)

Mỗi ô: số candidate `primary / shared / main-loop` (main-loop chỉ áp dụng cho activity state). Đã bỏ 2 clip `excluded_by_default`. Relationship tính khi owner đã bật.

| CoreState | daily / assistant | relationship | private | Hành vi daily khi thiếu |
|---|---|---|---|---|
| `idle` | 1 / 7 / 1 | 3 / 22 / 5 | 3 / 22 / 5 | — |
| `listening` | 0 / 1 / 1 | 0 / 4 / 3 | 0 / 4 / 3 | — (dùng chung idle loop) |
| `talking` | 1 / 2 / 1 | 1 / 2 / 1 | 1 / 2 / 1 | — |
| `thinking` | 1 / 0 / 0 | 1 / 2 / 2 | 1 / 2 / 2 | oneshot `chr_030` nối crossfade làm chính |
| `happy` | 2 / 2 / n/a | 3 / 4 / n/a | 3 / 4 / n/a | — |
| `shy` | 1 / 1 / n/a | 3 / 1 / n/a | 3 / 1 / n/a | — |
| `surprised` | 0 / 0 / n/a | 2 / 0 / n/a | 2 / 0 / n/a | bỏ overlay |
| `concerned` | 0 / 0 / n/a | 1 / 0 / n/a | 1 / 0 / n/a | bỏ overlay |
| `working` | 0 / 0 / 0 | 2 / 0 / 0 | 2 / 0 / 0 | assistant → idle(assistant) = idle loop nhóm A |
| `sleep` | 0 / 0 / 0 | 2 / 0 / 0 | 2 / 0 / 0 | idle(daily) |

Nhận xét:

- Daily/assistant chỉ có một main-loop (`chr_018`) cho idle/listening/talking; engine xen variant (xác suất 0.2) từ 7 clip shared của nhóm A để tránh lặp.
- `working`/`sleep` không có loop ở mọi context; Phase 4 NÊN cân nhắc crossfade dài giữa các oneshot hoặc trim clip. Không chặn build.
- Owner muốn daily có `surprised`/`concerned`/`working`/`sleep` thì override `allowed_modes` của clip nhóm B/C tương ứng (có `confirm_sensitive`). Tier filter vẫn ưu tiên nhóm A ở state nào nhóm A có mặt.

---

## 9. Xử lý clip đặc biệt

### 9.1 Hai clip jump-cut (Phase 3 `reject`)

| asset_id | Nguồn | Chính sách |
|---|---|---|
| `chr_011` | `DFRT1741.MP4` | `technical_quality=poor`, `kind=oneshot`, `weight=0.2`, `excluded_by_default=true`, `states: {idle: shared}`; transcode + publish; owner bật bằng override `enabled=true` |
| `chr_022` | `KKWB4339.MP4` | như trên |

Khi đã bật: chỉ làm variant, không làm main-loop, không phát 2 lần liên tiếp, không làm clip đầu tiên. Phase 4 CÓ THỂ đặt `trim_end_ms` cắt trước điểm jump-cut; nếu trim loại được discontinuity thì nâng `technical_quality`, còn các cờ khác do owner quyết định.

### 9.2 Mười chín clip review

`chr_001, 004, 005, 009, 010, 012, 016, 019, 020, 021, 023, 024, 025, 028, 029, 031, 033, 034, 036` — không loại; `review_flag=true`, `weight` 0.5 (good) / 0.4 (fair); không làm main-loop khi có main-loop khác (CHR-08). Ba clip review có `kind=loop` (`chr_016`, `chr_023`, `chr_029`) chỉ đóng vai variant. Nhóm near-duplicate Phase 3 vẫn giữ đủ; trùng lặp thị giác được giảm tác động nhờ recency window + weight thấp. Phase 4 CÓ THỂ gỡ `review_flag` sau khi duyệt.

---

## 10. Thay đổi tài liệu

| Tài liệu | Thay đổi |
|---|---|
| `CHARACTER_SYSTEM.md` → 1.2 | Viết lại: §2.5–§2.8 (StageContext, ContentSensitivity, Delivery, cờ chất lượng); §3 seed; §4.2 `labels.yaml` v2 + quy tắc không fail vì coverage; §4.3 `chr_nnn`; §4.4 manifest v2 theo `manifest_kind`; §4.5–§4.6 bundle/vault/private_vault; §5.1 M9–M10; §6 `stage_context` trong CharacterCue + Director; §7 event `PolicyUpdated`/`ManifestUpdated`/`AssetReady`; §8.5 stage context; §11 Asset Policy Engine (eligibility, tier, main-loop/variant, fit, fallback); §13–§16; §17 Owner Asset Policy (bảng, override, API, seed) |
| `ARCHITECTURE.md` → 1.2 | §0.1 D8; §1 sơ đồ + nguyên tắc 3; §2.1 C2/C12/C15; §2.2; §2.3 import rule `domain/assets`; §4.1–§4.2; §5 layout; §6.6 Assets; §7.3 chỉ mục bảng; §12 F16 + F23; §13 INV-05/17/18 sửa, INV-21/22 mới; §14 mã lỗi; §16 `ASSET_VAULT_ROOT` |
| `PRIVACY_SPEC.md` → 1.2 | §1 nguyên tắc 3/3a; §2 lớp D2V; §3 T6 + T17–T18; §4.1 vault asset (mới); §5.6 private_vault; §5.8 ma trận; §5.9 regex asset_id + policy private; §9 logout/xóa; §10.3 hình ảnh + hard_block; §11 L6 + L16–L17; §12 PRV-08; §13 ISO-08/09 sửa + ISO-27–ISO-31 |
| `AI_PROTOCOL.md` → 1.2 | §1 nguyên tắc 3/5; §4.2 `allowed_special_cues` theo `allowed_modes`; §5.3; §7.2 `settings.update` không có key asset policy; §11; §14 AIP-06; §15 test prompt |
| `ACCEPTANCE_CRITERIA.md` → 1.2 | DOD-3 INV-22; AC-CHAT-11; AC-AI-12/13; AC-CHR-05 thay; AC-MED-03/04/08 sửa; nhóm AC-AST-01…15 mới; AC-PRV-01 ISO-01…ISO-31; §18 tiêu chí Phase 3.2 |
| `PRD.md` → 1.2 | §3 hình ảnh; §4.1 G2/G8; NG10; F-04/F-05/F-06; F-19/F-20 mới; §6 Cài đặt "Nhân vật & hình ảnh"; J1, J5; §10 A1, A7; §11 lộ trình |
| `VISUAL_CLASSIFICATION_REPORT.md` | Banner đánh dấu phần chính sách đã bị thay thế + ghi chú lệch số loop |

Không sửa: `asset_analysis/*` (classification giữ nguyên làm bằng chứng quan sát), `assets_source/*`, các spec khác.

---

## 11. Phát hiện & việc để lại cho Phase 4 (không làm trong phase này)

| # | Mục | Ghi chú |
|---|---|---|
| P1 | Xác nhận `content_sensitivity` nhóm A (`suggestive` provisional) | Owner duyệt contact sheet; đổi `sensitivity_source` → `owner_confirmed` |
| P2 | Xác nhận state pools / cue ứng viên §7 | Đặc biệt: `greeting`, `playful`; `thinking`/`working`/`sleep` thiếu loop |
| P3 | Lệch số liệu Phase 3 report §6.2 (loop 9 / oneshot 34) so với JSON (8 / 35) | JSON là nguồn đúng (`MNZY6791`) |
| P4 | Trim tùy chọn cho `chr_011`, `chr_022` | Có thể nâng quality sau trim |
| P5 | Tạo `labels.yaml` v2 + `asset_id_registry.json` từ bảng §7 | Phase 4 |
| P6 | Đặt tên cue trung tính cuối cùng | Tên cue có thể vào prompt LLM |

---

## 12. Kết quả phase

| Tiêu chí (ACCEPTANCE_CRITERIA §18) | Kết quả |
|---|---|
| AC-P32-01 Tách `content_sensitivity` và `allowed_modes`; không còn `category=private` / `mode` / `coverage_waiver` trong spec canonical | PASS |
| AC-P32-02 Invariant giữ nguyên: LLM không thấy/chọn filename/asset_id; Engine chọn asset; video muted; voice chỉ TTS | PASS (§2) |
| AC-P32-03 Owner policy cho phép sensitivity cao ở relationship/private; daily/assistant ưu tiên tier thấp nhất; fallback không fail build | PASS (§4, §5) |
| AC-P32-04 Không yêu cầu mỗi CoreState có asset riêng; pool dùng chung | PASS (CHARACTER_SYSTEM §2.1, §4.2) |
| AC-P32-05 43/43 video giữ trong thư viện, không loại vì `category=private` | PASS (§7) |
| AC-P32-06 2 clip jump-cut: poor/oneshot/weight thấp/excluded_by_default, owner bật lại được | PASS (§9.1) |
| AC-P32-07 19 clip review: giữ, review_flag, weight thấp, không main-loop | PASS (§9.2) |
| AC-P32-08 6 tài liệu yêu cầu được cập nhật nhất quán; không có code; `assets_source`/`asset_analysis` không bị sửa | PASS |

**Tổng: PASS.** Phase 3.2 dừng ở đây. Không bắt đầu Phase 4.
