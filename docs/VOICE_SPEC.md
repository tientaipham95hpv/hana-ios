# HANA — VOICE SPEC (Push-to-talk, STT, TTS)

> **Phase 6.3 active V1 contract (2026-09-17; supersedes conflicting sections below):** Client target is iOS only. PTT records with `AVAudioRecorder` under `AVAudioSession`; audio is uploaded to Hana and transcribed server-side by Deepgram (`nova-3`, `vi`). Reply text is delivered through SSE before any speech. Speech output is local `AVSpeechSynthesizer` with `vi-VN`; Flutter never requests server TTS for the active iOS path. AUTO speaks PTT replies but not typed replies; TEXT_ONLY never auto-speaks; VOICE_REPLY auto-speaks when auto-play is on; every assistant message has manual speak/stop. ElevenLabs/9Router audio and `tts.segment` playback remain legacy optional compatibility only and are not V1 acceptance dependencies.

Native utterances carry `turn_id:generation`. Flutter accepts start/finish/cancel/failure callbacks only for the current token, so a stopped utterance cannot mutate a newer turn. Backgrounding, audio interruption, route loss, or PTT barge-in stops speech/recording, deactivates the audio session, and converges the Character Engine out of `listening`/`talking`. Voice selection is never hard-coded: Voice Lab enumerates installed voices whose locale begins with `vi`, shows name/identifier/locale/quality, and persists an optional identifier plus rate/pitch/volume.

Phiên bản: 1.1 (Phase 1 + Final Decision Patch) · Vị trí canonical: `repo/docs/` · Quyết định chốt: ARCHITECTURE §0.1
Phụ thuộc: `ARCHITECTURE.md` §6.3–§6.4, §8.2, §9; `CHARACTER_SYSTEM.md` §7–§9; `AI_PROTOCOL.md` §2, §6; `PRIVACY_SPEC.md` §5.

---

## 1. Nguyên tắc

1. **Giọng Hana chỉ đến từ TTS.** Không bao giờ dùng audio từ video (INV-03).
2. **Push-to-talk, không always-listening.** Không wake word, không ghi âm nền, không duplex streaming ở v1.
3. **STT chạy server-side qua Deepgram; TTS chạy local trên iOS qua AVSpeechSynthesizer.** Deepgram/9Router key không ở thiết bị (INV-14); native TTS không cần cloud key.
4. **Text là nguồn gốc, giọng là phụ.** Lỗi TTS không làm mất câu trả lời; lỗi STT không tạo tin nhắn rỗng.
5. **Text hiển thị và text đọc tách biệt**: `display_text` (lưu DB) → `speech_text` (sinh xác định bởi `SpeechNormalizer`).
6. **Private voice không để lại dấu vết trên disk thiết bị** và bị xóa khỏi server sớm nhất có thể.

---

## 2. Component

| Component | Vị trí | Trách nhiệm |
|---|---|---|
| `PttController` | Flutter `features/voice/` | Gesture giữ-để-nói, cancel zone, giới hạn thời lượng, phát event cho Character Engine |
| `VoiceRecorder` | Flutter + iOS platform channel | `AVAudioRecorder`, permission, interruption/route handling, temp M4A |
| `VoiceUploader` | Flutter | `POST /v1/turns/voice` (hoặc private) |
| `IosNativeTtsQueue` | Flutter + iOS platform channel | Gửi reply text + voice settings tới `AVSpeechSynthesizer`; correlate callback bằng utterance generation; gate/barge-in |
| `AudioSessionManager` | Flutter | Package `audio_session`, cấu hình speech, xử lý interruption |
| `SttService` | Backend `domain/voice/stt.py` | Validate audio, gọi Deepgram, lọc transcript |
| `SpeechNormalizer` | Backend `domain/voice/speech_normalizer.py` | display → speech text (§6) |
| `Segmenter` | Backend `domain/voice/segmenter.py` | Chia speech text thành segment (§7.3) |
| `TtsService` | Backend `domain/voice/tts.py` | Synthesize, lưu blob, cache, emit event |

Interface backend:

```python
class SttProvider(Protocol):
    async def transcribe(self, *, audio_path: Path, mime: str, language: str,
                         prompt: str | None, timeout_s: float) -> SttResult: ...
# SttResult: text: str, duration_ms: int | None, latency_ms: int, model: str

class TtsProvider(Protocol):
    async def synthesize(self, *, text: str, voice: str, speed: float,
                         style: str | None, timeout_s: float) -> TtsResult: ...
# TtsResult: audio_bytes: bytes, mime: "audio/mpeg", latency_ms: int, model: str
```

Implement mặc định: `NineRouterSttProvider`, `NineRouterTtsProvider`. Test: `FakeSttProvider` (trả transcript định sẵn), `FakeTtsProvider` (trả mp3 im lặng có độ dài tỉ lệ số ký tự).

**Provider active V1:** STT = Deepgram `nova-3`, language `vi`; TTS = iOS `AVSpeechSynthesizer`, language `vi-VN`, voice identifier selected from installed voices. ElevenLabs adapter may remain inactive on the backend but no key or live ElevenLabs call is required.

---

## 3. Push-to-talk UX và state machine client

### 3.1 Gesture

| Hành động | Kết quả |
|---|---|
| Nhấn giữ nút mic ≥ 150 ms | Bắt đầu ghi; haptic `mediumImpact`; Character Engine `PttPressed` |
| Chạm < 150 ms | Không ghi; tooltip "Giữ để nói" |
| Kéo lên hoặc sang trái > 80 dp khi đang ghi | Vào cancel zone (nút đỏ, chữ "Thả để hủy"); haptic `selectionClick` |
| Kéo quay lại | Ra khỏi cancel zone |
| Thả ngoài cancel zone, thời lượng ≥ 400 ms | Gửi; `PttReleased(valid: true)` |
| Thả ngoài cancel zone, < 400 ms | Hủy; tooltip "Giữ lâu hơn một chút"; `PttReleased(valid: false)` |
| Thả trong cancel zone | Hủy; `PttCancelled` |
| Đạt 55 s | Đồng hồ chuyển màu cảnh báo |
| Đạt 60 s | Tự dừng và gửi; haptic |
| App vào background / cuộc gọi đến / mất audio focus khi đang ghi | Hủy; `PttCancelled` |

### 3.2 State machine

```
idle ──press≥150ms──► checking_permission
checking_permission ──granted──► starting
checking_permission ──denied──► idle (snackbar "Cho phép micro" + nút mở Settings)
starting ──recorder started──► recording
starting ──error──► idle (snackbar lỗi micro)
recording ⇄ cancel_zone
recording ──release (≥400ms)──► finalizing
recording ──release (<400ms)──► idle (xóa file)
recording/cancel_zone ──cancel──► idle (xóa file)
recording ──60s──► finalizing
finalizing ──silence detected──► idle (tooltip "Em không nghe thấy tiếng", xóa file)
finalizing ──ok──► uploading
uploading ──202──► awaiting_transcript (xóa file local)
uploading ──network error──► upload_failed (giữ file ≤ 2 phút, bubble nút "Gửi lại")
upload_failed ──retry──► uploading | ──timeout 2 phút / hủy──► idle (xóa file)
awaiting_transcript ──transcript.final──► idle
awaiting_transcript ──turn.failed(STT_*)──► idle (bubble fallback)
```

- Khi `press` mà TTS đang phát: `TtsQueue.stopAll()` **trước** khi bắt đầu ghi (tránh thu tiếng Hana).
- Khi `press` mà có turn active chưa có reply: upload sau đó dùng `supersede=true`.
- Chỉ một phiên ghi tại một thời điểm.

### 3.3 Hiển thị

- Trong `recording`: waveform/amplitude bar cập nhật mỗi 100 ms, đồng hồ `0:07`.
- Sau khi gửi: bubble người dùng tạm "🎤 0:07 · đang nghe…"; khi `transcript.final` → thay bằng transcript + icon mic.

---

## 4. Ghi âm

| Thông số | Giá trị |
|---|---|
| Package | `record` |
| Encoder | AAC-LC |
| Container | `.m4a` |
| Sample rate | 16.000 Hz |
| Channels | 1 |
| Bitrate | 48 kbps |
| iOS audio source | `AVAudioRecorder` + `AVAudioSession.playAndRecord`; AAC/M4A, 16 kHz mono |
| AGC / echo cancel / noise suppress | bật nếu thiết bị hỗ trợ |
| Thời lượng | 400 ms … 60.000 ms |
| File normal | `<cache>/voice/<client_id>.m4a` |
| File private | `<cache>/prv_rt/voice/<client_id>.m4a` |

Silence detection phía client: lấy amplitude mỗi 100 ms; nếu `max_amplitude_dbfs < -45` trong toàn bộ bản ghi → không upload.

Quyền: `RECORD_AUDIO`. Không yêu cầu quyền khi app khởi động; chỉ yêu cầu ở lần nhấn mic đầu tiên.

---

## 5. Upload & STT (server)

### 5.1 Request

`POST /v1/turns/voice` (private: `POST /v1/private/turns/voice`), multipart:

| Field | Ràng buộc |
|---|---|
| `client_id` | UUID |
| `audio` | file ≤ 2 MB, `audio/mp4` / `audio/m4a` / `audio/aac` |
| `duration_ms` | 400..62.000 |
| `speak` | bool |
| `supersede` | bool |

api:

1. Lưu file vào blob tạm (`media_objects kind=voice_input`, `expires_at = now + 24h` normal; private → `private_media_objects`, `expires_at = now + 10 phút`).
2. `ffprobe` (timeout 3 s): phải có đúng 1 audio stream, duration trong khoảng (sai lệch ≤ 2 s so với `duration_ms`). Sai → 422 `AUDIO_INVALID`, xóa file.
3. Tạo `turns(input_kind=voice, state=queued, input_media_id)`; **chưa** tạo user message.
4. Enqueue `process_turn` / `process_private_turn`. Trả 202.

### 5.2 Worker — state `transcribing`

1. Emit `turn.progress {stage:"transcribing"}`.
2. Chuẩn bị file: nếu `STT_INPUT_FORMAT=wav` → ffmpeg chuyển 16 kHz mono PCM WAV (file tạm cùng namespace); mặc định gửi m4a nguyên bản.
3. Gọi `SttProvider.transcribe` (§5.3), timeout 20 s, không retry tự động.
4. Hậu xử lý transcript (§5.4).
5. Rỗng → `failed(STT_EMPTY)` + message fallback (AI_PROTOCOL §8.3). Lỗi provider → `failed(STT_FAILED)`.
6. Hợp lệ → insert `messages(role=user, origin=voice, text=transcript)`, cập nhật `turns.user_message_id`, emit `transcript.final`.
7. Private: xóa blob audio **ngay** sau bước 3 (thành công hoặc thất bại). Normal: giữ theo `expires_at` (24 h) để debug, không ai đọc lại trừ job cleanup.
8. Tiếp tục `context_building` như text turn.

### 5.3 Gọi Deepgram

```
POST {NINE_ROUTER_BASE_URL}/audio/transcriptions
Authorization: Bearer …
Content-Type: multipart/form-data
  file=@voice.m4a
  model=${STT_MODEL}
  language=vi
  response_format=json
  temperature=0
  prompt=<vocabulary hint, tùy chọn>
```

Response: `{"text": "…"}`.

Vocabulary hint (≤ 200 ký tự, chỉ gửi nếu provider hỗ trợ, cờ `STT_PROMPT_SUPPORTED`):

- Normal: `address_user`, tên người dùng, biệt danh, tên dự án từ `work_journal_items` 30 ngày gần nhất (tối đa 10), tên người trong memory category `people` pinned (tối đa 5).
- Private: chỉ `address_user`, `address_hana`, tên người dùng. Không lấy từ memory/journal.

### 5.4 Hậu xử lý transcript

1. Unicode NFC, trim, gộp khoảng trắng.
2. Bỏ nếu sau khi xóa dấu câu và khoảng trắng còn < 1 ký tự chữ/số.
3. Danh sách câu "ảo giác" thường gặp của STT (so khớp không dấu, lowercase, toàn chuỗi): `hay subscribe cho kenh`, `cam on cac ban da theo doi`, `hen gap lai cac ban trong nhung video tiep theo`, `ghien mi go`, `subtitles by`, `thank you for watching`. Khớp → coi như rỗng. Danh sách lưu `domain/voice/stt_blocklist.txt`, bổ sung được.
4. Cắt tối đa 4.000 ký tự.

---

## 6. Speech text

### 6.1 Khi nào đọc

`speak` của turn do client gửi, tính từ `user_settings.speak_replies` + nút tắt tiếng nhanh trên stage (lưu local, mặc định bật tiếng):

| `speak_replies` | Text turn | Voice turn |
|---|---|---|
| `always` | đọc | đọc |
| `voice_turns_only` | không | đọc |
| `never` | không | không |

Server enforce: `speak_replies = never` → bỏ qua `speak=true`. Tin proactive/reminder/report không tự đọc (chỉ đọc khi người dùng bấm loa — `POST /v1/messages/{id}/speak`).

### 6.2 Pipeline

```
envelope.reply (có placeholder)
   ├─ render display form  → messages.text (display_text)
   └─ render speech form   → SpeechNormalizer.normalize → speech_text → Segmenter → TTS
```

Placeholder được render riêng cho speech (AI_PROTOCOL §6.2), **không** suy ngược từ display.

### 6.3 SpeechNormalizer — quy tắc (áp dụng tuần tự)

| # | Quy tắc | Ví dụ vào → ra |
|---|---|---|
| N1 | Bỏ markdown: `**x**`, `*x*`, `_x_`, `` `x` ``, `# `, `> ` → `x`; `[chữ](url)` → `chữ` | `**Họp** lúc` → `Họp lúc` |
| N2 | Danh sách: mỗi dòng bắt đầu `- `, `* `, `1. ` → nối bằng `, `, dòng cuối kết thúc `.` | |
| N3 | URL (`https?://…`) → `đường link`; email → `địa chỉ email` | |
| N4 | Xóa emoji (Unicode `Extended_Pictographic`, `Emoji_Component` ngoài chữ số) | `Dạ 😊` → `Dạ` |
| N5 | Giờ `HH:MM`, `H:MM`, `Hh`, `HhMM`, `H giờ MM` → dạng nói §6.4 | `15:30` → `ba giờ rưỡi chiều` |
| N6 | Ngày `DD/MM/YYYY`, `DD/MM` → dạng nói §6.5 | `16/09` → `ngày mười sáu tháng chín` |
| N7 | Khoảng `A–B` / `A - B` giữa hai ngày/giờ/số → `A đến B` | `15/08–14/09` → `ngày mười lăm tháng tám đến ngày mười bốn tháng chín` |
| N8 | Tiền: `50k` → `năm mươi nghìn`; `2tr`/`2 triệu` → `hai triệu`; `100.000đ`, `100.000 VND`, `100.000 đồng` → `một trăm nghìn đồng`; `$20` → `hai mươi đô la` | |
| N9 | Phần trăm `30%` → `ba mươi phần trăm` | |
| N10 | Số: `1.234.567` (dấu chấm nghìn) → chữ; `3,5` → `ba phẩy năm`; dãy ≥ 7 chữ số liền không phân cách → đọc từng chữ số | `0912345678` → `không chín một hai …` |
| N11 | Viết tắt: `ko`/`k` (đứng riêng) → `không`; `dc`/`đc` → `được`; `CN` → `Chủ nhật`; `T2..T7` → `thứ hai..thứ bảy`; `vs` → `với`; `ok`/`OK` → `ô kê` | |
| N12 | Ký hiệu: `&` → `và`; `+` giữa chữ → `cộng`; `/` giữa hai chữ → `hoặc`; `~` trước số → `khoảng` | |
| N13 | Gộp khoảng trắng, bảo đảm câu kết thúc bằng dấu câu | |

Từ tiếng Anh giữ nguyên để provider tự đọc.

### 6.4 Đọc giờ

Giờ `h` (0..23), phút `m`:

| h | Buổi | Giờ nói |
|---|---|---|
| 0 | đêm | `mười hai giờ` |
| 1–4 | sáng | `h` |
| 5–10 | sáng | `h` |
| 11–12 | trưa | `h` |
| 13–17 | chiều | `h-12` |
| 18–21 | tối | `h-12` |
| 22–23 | đêm | `h-12` |

Phút: `0` → bỏ; `30` → `rưỡi`; khác → số bằng chữ.
Mẫu: `{giờ} giờ[ {phút}] {buổi}`. `08:00` → `tám giờ sáng`; `12:00` → `mười hai giờ trưa`; `15:30` → `ba giờ rưỡi chiều`; `20:15` → `tám giờ mười lăm tối`; `00:05` → `mười hai giờ năm đêm`.

### 6.5 Đọc ngày

- Ngày 1–10 → `mùng {n}`; 11–31 → số bằng chữ.
- Tháng: `tháng một`, `tháng hai`, `tháng ba`, `tháng tư`, `tháng năm`, …, `tháng mười`, `tháng mười một`, `tháng mười hai`.
- Năm: đọc số đầy đủ (`2026` → `hai nghìn không trăm hai mươi sáu`); bỏ năm nếu là năm hiện tại theo giờ Việt Nam.
- `16/09` → `ngày mười sáu tháng chín`; `01/04/2027` → `ngày mùng một tháng tư năm hai nghìn không trăm hai mươi bảy`.

### 6.6 Đọc số (hàm `number_to_vietnamese`)

- `0` không, `1` một, … `10` mười.
- Hàng đơn vị sau hàng chục ≥ 2: `1` → `mốt`, `4` → `tư`, `5` → `lăm`. Sau `mười`: `5` → `lăm`, `1` → `một`, `4` → `bốn`.
- Hàng chục = 0 và hàng trăm có mặt: `linh` (`105` → `một trăm linh năm`).
- Nhóm nghìn: `nghìn`, `triệu`, `tỷ`. Nhóm giữa bằng 0 nhưng nhóm sau khác 0: `không trăm` (`1.005.000` → `một triệu không trăm linh năm nghìn`).
- Số âm: `âm …`.

---

## 7. TTS

### 7.0 Active iOS-native path (Phase 6.3)

1. Backend persists/emits `reply.ready`; it does not synthesize audio for an iOS-native request (`speak=false`).
2. Flutter renders text immediately, resolves response mode locally, and calls `hana/native_tts.speak` only when required.
3. Native code chooses the configured installed `vi-VN` identifier or the system `vi-VN` default, then applies bounded rate `0.10…0.65`, pitch `0.50…2.00`, and volume `0…1`.
4. `AVSpeechSynthesizerDelegate` emits `speechStarted`, `speechFinished`, and `speechCancelled`. Setup/runtime errors are returned as platform errors and settle the engine without removing text.
5. `AVAudioSession` uses `playAndRecord`/`spokenAudio` for speech and `playAndRecord`/`measurement` for PTT. Starting one path stops the other. Interruption, old-route loss, and backgrounding cancel active work and deactivate the session.
6. Sections 7.1–8 describing server synthesis/audio blobs are retained only for the inactive compatibility adapter. They are not the active iOS V1 path.

### 7.1 Thời điểm

Sau khi assistant message persist (`reply_ready`) và `speak = true` → state `speaking`.

### 7.2 Giới hạn độ dài

- `speech_text` ≤ 1.200 ký tự → đọc toàn bộ.
- > 1.200 → lấy các segment đầu có tổng ≤ 1.000 ký tự, thêm segment cuối cố định: `Phần còn lại em để trong tin nhắn nha {u}.`

### 7.3 Segmenter

1. Tách câu tại `.`, `!`, `?`, `…`, xuống dòng (giữ dấu).
2. Gộp câu liên tiếp đến khi segment ≥ 40 ký tự, không vượt 220.
3. Câu > 220: tách tại `,` `;` `:`; vẫn > 220 → tách tại khoảng trắng gần nhất trước 220.
4. Mỗi segment giữ `char_start`, `char_end` theo `speech_text` (dùng cho highlight tùy chọn, không bắt buộc ở v1).

### 7.4 Gọi 9Router

```
POST {NINE_ROUTER_BASE_URL}/audio/speech
Authorization: Bearer …
Content-Type: application/json
{ "model": "${TTS_MODEL}", "voice": "${TTS_VOICE}", "input": "<segment>",
  "response_format": "mp3", "speed": <user_settings.tts_speed> }
```

- Nếu `TTS_STYLE_SUPPORTED=true`: thêm field `instructions` theo emotion của reply: neutral → "Giọng nữ trưởng thành, ấm áp, tự nhiên."; happy → "… vui tươi"; shy → "… nhỏ nhẹ, hơi ngại ngùng"; surprised → "… ngạc nhiên"; concerned → "… dịu dàng, quan tâm". Không hỗ trợ → không gửi.
- Response: bytes `audio/mpeg`. Validate: ≥ 1 KB và `ffprobe` đọc được duration (lấy `duration_ms`).

### 7.5 Điều phối synthesize

- Concurrency 2 segment song song, emit event **theo đúng thứ tự index** (segment 1 xong trước segment 0 → giữ lại đến khi 0 xong).
- Timeout 15 s/segment; retry 1 lần; vẫn lỗi → emit `tts.failed {index}` và **dừng** các segment sau (không đọc nhảy cóc). Turn vẫn `completed`.
- Tổng `speaking` ≤ 60 s; quá → như lỗi tại segment chưa xong.
- Kiểm tra cờ cancel/supersede trước mỗi segment.

### 7.6 Lưu trữ và cache

| | Normal | Private |
|---|---|---|
| Nơi lưu | `MEDIA_ROOT/tts/<yyyy>/<mm>/<media_id>.mp3` | `PRIVATE_MEDIA_ROOT/tts/<media_id>.mp3` |
| Bảng | `media_objects(kind=tts_audio)` | `hana_private.private_media_objects` |
| TTL | 7 ngày | 1 giờ |
| Cache | `cache_key = sha256(model|voice|speed|style|segment_text)`; trùng và chưa hết hạn → dùng lại, không gọi provider | **không cache** |
| URL | `/v1/media/{media_id}` | `/v1/private/media/{media_id}` |

### 7.7 Event

`tts.segment {index, media_id, media_url, duration_ms, char_start, char_end, is_last}`; `is_last=true` ở segment cuối thực sự được đọc.

---

## 8. Phát lại trên client (`TtsQueue`)

### 8.1 Hành vi

1. Nhận `tts.segment` → tải bytes bằng dio (header Authorization, + `X-Private-Session` nếu private) vào **RAM** (không ghi disk ở cả hai mode).
2. Phát bằng `just_audio` với `StreamAudioSource` tùy biến đọc từ bytes; nối bằng `ConcatenatingAudioSource` (thêm dần).
3. Chờ **TTS gate** từ Character Engine (`ReleaseTtsGate`) trước khi phát segment 0; gate mặc định mở ngay khi không có pre-speech reaction; timeout gate 1.500 ms → tự mở.
4. Bắt đầu phát segment 0 → Engine `TtsStarted(turn_id)`.
5. Hết segment `is_last` → `TtsFinished(turn_id)`.
6. Segment kế chưa tải xong khi segment trước hết → chờ tối đa 8 s; quá → dừng, `TtsFailed`.
7. `tts.failed` → phát hết các segment đã có rồi `TtsFailed`; bubble hiện icon loa gạch chéo, chạm để thử lại (`POST /v1/messages/{id}/speak`).

### 8.2 Barge-in và ngắt

| Sự kiện | Hành vi |
|---|---|
| Nhấn PTT | `stopAll()` ngay (≤ 100 ms), bỏ mọi segment còn lại của turn đó |
| Người dùng gửi text mới | `stopAll()` |
| Người dùng chạm nút dừng trên stage | `stopAll()`, Engine `TtsStoppedByUser` |
| Tắt tiếng nhanh | `stopAll()`, lưu pref, các turn sau `speak=false` |
| Cuộc gọi đến / interruption begin | `stopAll()` (không tự tiếp tục) |
| Rút tai nghe (`becomingNoisy`) | `stopAll()` |
| App background | tiếp tục phát normal (như app nghe); private → dừng ngay |
| Rời private mode | `stopAll()`, xóa bytes khỏi RAM |

### 8.3 Audio session

`AudioSession.configure(AudioSessionConfiguration.speech())`; khi phát TTS: `setActive(true)` (duck app khác); khi xong: `setActive(false)`. Video player dùng `mixWithOthers: true`, không tham gia audio session.

---

## 9. Settings liên quan

| Setting | Nơi | Mặc định |
|---|---|---|
| `speak_replies` | server `user_settings` | `always` |
| `tts_speed` | server | 1.00 |
| quick mute | local pref | off |
| haptics PTT | local pref | on |

---

## 10. Quy tắc private voice

1. Endpoint riêng `/v1/private/turns/voice`, queue `hana:private`, blob `PRIVATE_MEDIA_ROOT`.
2. File ghi âm local nằm trong `cache/prv_rt/voice/`, xóa ngay sau upload 202; khóa private → xóa toàn bộ `prv_rt`.
3. Audio private trên server bị xóa ngay sau STT.
4. Transcript private chỉ lưu trong `hana_private.private_messages` (ciphertext).
5. TTS private không cache, TTL 1 giờ, client giữ RAM.
6. STT vocabulary hint private không lấy từ memory/journal (§5.3).
7. Không log transcript, speech text, hay độ dài chi tiết theo nội dung ở private (chỉ `duration_ms` làm tròn 5 s).

---

## 11. Failure modes

| Sự cố | Hành vi | Người dùng thấy |
|---|---|---|
| Từ chối quyền micro | Không ghi | Snackbar + nút mở cài đặt |
| Thiết bị không có encoder AAC | Fallback encoder `opus` trong `.ogg` (server chấp nhận `audio/ogg`) | Không thấy |
| Im lặng | Không upload | Tooltip |
| Upload lỗi mạng | Giữ file 2 phút, nút gửi lại | Bubble lỗi |
| ffprobe không đọc được audio | 422 `AUDIO_INVALID` | "Ghi âm bị lỗi, anh thử lại nha" |
| STT timeout/lỗi | `STT_FAILED` | Bubble fallback, cue concerned |
| STT rỗng/ảo giác | `STT_EMPTY` | Bubble fallback |
| STT sai tiếng Việt (chất lượng) | Không tự phát hiện; người dùng sửa bằng text | — |
| TTS lỗi segment đầu | `tts.failed{0}` | Text hiện, icon loa gạch, Hana không vào `talking` |
| TTS lỗi giữa chừng | Dừng sau segment lỗi | Hana dừng nói, text đầy đủ |
| Tải segment lỗi (media hết hạn khi resume) | `POST speak` để tạo lại | Chạm loa để nghe lại |
| Người dùng nhấn PTT khi Hana đang nói | Barge-in §8.2 | Hana dừng ngay, chuyển listening |
| Hai thiết bị cùng nói | Mỗi device độc lập; turn concurrency theo user (ARCHITECTURE §9.3) → device thứ hai nhận 409 nếu không supersede | Snackbar |

---

## 12. Retention

| Dữ liệu | Normal | Private |
|---|---|---|
| File ghi âm trên thiết bị | xóa sau 202 (hoặc ≤ 2 phút nếu lỗi) | xóa sau 202; xóa toàn bộ khi khóa |
| Audio input trên server | 24 giờ | xóa ngay sau STT; tối đa 10 phút nếu worker chết |
| Transcript | là user message (lưu như chat) | private_messages (mã hóa) |
| TTS audio server | 7 ngày | 1 giờ |
| TTS audio thiết bị | RAM | RAM |

---

## 13. Latency budgets

| Đoạn | p50 | p95 |
|---|---|---|
| Nhấn giữ → bắt đầu ghi | 200 ms | 400 ms |
| Thả → 202 (5 s audio, 4G) | 600 ms | 1.5 s |
| 202 → `transcript.final` | 1.5 s | 5 s |
| `reply.ready` → segment 0 sẵn trên server | 1.0 s | 2.5 s |
| Segment 0 sẵn → bắt đầu phát trên client | 300 ms | 800 ms |
| Nhấn PTT → TTS im lặng | 100 ms | 200 ms |

---

## 14. Invariants

INV-03, INV-14, INV-15 (ARCHITECTURE §13), cộng:

| ID | Invariant |
|---|---|
| VOC-01 | Không có code path phát âm thanh nào ngoài `TtsQueue` (và âm thanh hệ thống của notification). |
| VOC-02 | Không bao giờ ghi âm khi TTS đang phát (TTS dừng trước khi recorder start). |
| VOC-03 | Transcript rỗng không tạo user message. |
| VOC-04 | `speech_text` sinh xác định từ `display_text` + placeholder speech; cùng input → cùng output. |
| VOC-05 | TTS bytes không bao giờ ghi disk trên thiết bị. |
| VOC-06 | Audio input private không tồn tại trên server quá 10 phút. |

---

## 15. Kiểm thử bắt buộc

- Unit test `SpeechNormalizer` bảng tối thiểu:

| Input | Output kỳ vọng |
|---|---|
| `Họp lúc 15:00 nha` | `Họp lúc ba giờ chiều nha.` |
| `08:30` | `tám giờ rưỡi sáng` |
| `00:00` | `mười hai giờ đêm` |
| `12:05` | `mười hai giờ năm trưa` |
| `21` (số) | `hai mươi mốt` |
| `24` | `hai mươi tư` |
| `15` | `mười lăm` |
| `105` | `một trăm linh năm` |
| `1.005.000` | `một triệu không trăm linh năm nghìn` |
| `3,5` | `ba phẩy năm` |
| `50k` | `năm mươi nghìn` |
| `30%` | `ba mươi phần trăm` |
| `01/04` | `ngày mùng một tháng tư` |
| `15/08–14/09` | `ngày mười lăm tháng tám đến ngày mười bốn tháng chín` |
| `**Xong** rồi 😊` | `Xong rồi.` |
| `ko dc` | `không được` |

- Unit test Segmenter: câu dài 500 ký tự không dấu câu → mọi segment ≤ 220, nối lại bằng input.
- Test STT blocklist + transcript rỗng → `STT_EMPTY`, không có user message.
- Test thứ tự emit segment khi segment 1 xong trước 0.
- Test barge-in (widget/integration): PTT trong lúc phát → player stop ≤ 200 ms, recorder start sau stop.
- Test private: sau STT, file audio private không còn trên disk server; client không có file trong `prv_rt` sau khi khóa.
- Test `speak_replies=never` → server không synthesize dù client gửi `speak=true`.
