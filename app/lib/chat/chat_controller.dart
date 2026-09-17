import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../app/character_runtime_controller.dart';
import '../backend/hana_backend_client.dart';
import '../backend/sse_client.dart';
import '../backend/turn_models.dart';
import '../character/engine/character_cue.dart';
import '../character/engine/engine_event.dart';
import '../character/manifest/manifest_models.dart';
import '../voice/tts_queue.dart';
import '../voice/voice_preferences.dart';
import '../voice/voice_recorder.dart';

class ChatController extends ChangeNotifier {
  ChatController({
    required this.client,
    required this.runtime,
    required this.tts,
    required this.recorder,
    VoicePreferences? preferences,
    this.configureAudio = true,
  }) : preferences =
           preferences ??
           VoicePreferences(store: MemoryVoicePreferenceStore()) {
    tts.onStarted = (turn) {
      _playingTurnId = turn;
      if (runtime.state.currentTurnId == turn &&
          runtime.state.pendingCue != null &&
          runtime.state.deferredReply == null) {
        runtime.dispatch(TtsStarted(turn));
      } else {
        _earlyTtsStartTurnId = turn;
      }
      notifyListeners();
    };
    tts.onFinished = (turn) {
      _playingTurnId = null;
      if (_requestedSpeechTurnId == turn) _requestedSpeechTurnId = null;
      _earlyTtsStartTurnId = null;
      runtime.dispatch(TtsFinished(turn));
      if (runtime.state.currentTurnId == turn) {
        runtime.dispatch(TtsFailed(turn));
      }
      if (manualAudioTurnId == turn) manualAudioTurnId = null;
      notifyListeners();
    };
    tts.onFailed = (turn) {
      _playingTurnId = null;
      if (_requestedSpeechTurnId == turn) _requestedSpeechTurnId = null;
      _earlyTtsStartTurnId = null;
      runtime.dispatch(TtsFailed(turn));
      if (manualAudioTurnId == turn) manualAudioTurnId = null;
      error = 'Không phát được giọng nói. Tin nhắn văn bản vẫn dùng được.';
      notifyListeners();
    };
    tts.onCancelled = (turn) {
      _playingTurnId = null;
      if (_requestedSpeechTurnId == turn) _requestedSpeechTurnId = null;
      _earlyTtsStartTurnId = null;
      runtime.dispatch(TtsFailed(turn));
      if (manualAudioTurnId == turn) manualAudioTurnId = null;
      notifyListeners();
    };
    recorder.onInterrupted = () {
      if (!recording) return;
      recording = false;
      runtime.dispatch(const PttCancelled());
      error = 'Ghi âm đã dừng do cuộc gọi, Siri, đổi thiết bị âm thanh hoặc ứng dụng vào nền.';
      notifyListeners();
    };
    runtime.addListener(_flushEarlyTtsStart);
    if (configureAudio) unawaited(tts.configure());
  }

  final BackendTurnClient client;
  final CharacterRuntimeController runtime;
  final TtsQueue tts;
  final VoiceRecorder recorder;
  final VoicePreferences preferences;
  final bool configureAudio;
  final _uuid = const Uuid();
  final messages = <ChatMessageModel>[];
  final _lastSeq = <String, int>{};
  StreamSubscription<void>? _events;
  String? activeTurnId;
  String? pendingClientId;
  String? pendingDraft;
  String? error;
  bool sending = false;
  bool recording = false;
  MicrophonePermissionState microphonePermission =
      MicrophonePermissionState.notDetermined;
  String? manualAudioTurnId;
  String? _playingTurnId;
  String? _requestedSpeechTurnId;
  String? _earlyTtsStartTurnId;
  String semanticMode = 'daily';

  void setSemanticMode(String mode) {
    if (mode != 'daily' && mode != 'relationship') return;
    semanticMode = mode;
    notifyListeners();
  }

  void _flushEarlyTtsStart() {
    final turn = _earlyTtsStartTurnId;
    if (turn == null) return;
    if (runtime.state.currentTurnId != turn) {
      _earlyTtsStartTurnId = null;
      return;
    }
    if (runtime.state.pendingCue == null ||
        runtime.state.deferredReply != null) {
      return;
    }
    _earlyTtsStartTurnId = null;
    scheduleMicrotask(() {
      if (_playingTurnId == turn && runtime.state.currentTurnId == turn) {
        runtime.dispatch(TtsStarted(turn));
      }
    });
  }

  Future<void> sendText(String raw, {bool? speak}) async {
    final text = raw.trim();
    if (text.isEmpty || sending) return;
    final clientId = pendingDraft == text && pendingClientId != null
        ? pendingClientId!
        : _uuid.v4();
    pendingClientId = clientId;
    pendingDraft = text;
    sending = true;
    error = null;
    notifyListeners();
    try {
      final resolvedSpeak = speak ?? preferences.shouldSpeak(voiceInput: false);
      await tts.stop();
      if (runtime.state.activity.name == 'talking') {
        runtime.dispatch(const TtsStoppedByUser());
      }
      final accepted = await client.createTextTurn(
        clientId: clientId,
        text: text,
        speak: tts.usesNativeText ? false : resolvedSpeak,
        supersede: activeTurnId != null,
        responseMode: preferences.responseMode.apiValue,
        autoPlayVoice: preferences.autoPlayVoice,
        semanticMode: semanticMode,
      );
      messages.add(
        ChatMessageModel(
          id: clientId,
          role: 'user',
          text: text,
          turnId: accepted.turnId,
        ),
      );
      pendingClientId = null;
      pendingDraft = null;
      await _follow(accepted, speak: resolvedSpeak);
    } on DioException catch (exception) {
      error = _networkMessage(exception);
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  Future<void> _follow(AcceptedTurn turn, {required bool speak}) async {
    await _events?.cancel();
    activeTurnId = turn.turnId;
    runtime.dispatch(TurnSubmitted(turn.turnId));
    notifyListeners();
    _events = client
        .events(turn)
        .asyncMap((event) => _handle(event, speak: speak))
        .listen(
          (_) {},
          onError: (Object value) async {
            if (activeTurnId != turn.turnId) return;
            if (value is SseProtocolException) {
              error = 'Máy chủ gửi sự kiện không hợp lệ.';
            } else {
              error = 'Mất kết nối cập nhật. Đang dùng trạng thái đã lưu.';
            }
            await _recoverTerminal(turn.turnId);
            notifyListeners();
          },
        );
  }

  Future<void> _recoverTerminal(String turnId) async {
    try {
      final snapshot = await client.state(turnId);
      if (activeTurnId != turnId) return;
      final terminal = snapshot['state'];
      if (terminal != 'completed' &&
          terminal != 'failed' &&
          terminal != 'cancelled') {
        return;
      }
      final raw = snapshot['assistant_message'];
      if (raw is Map<String, dynamic>) {
        final message = ChatMessageModel.fromJson(raw);
        _appendAssistant(message);
        if (terminal == 'completed') {
          runtime.dispatch(
            ReplyReady(
              turnId: turnId,
              cue:
                  message.cue ??
                  const CharacterCue(
                    emotion: Emotion.neutral,
                    intensity: Intensity.low,
                  ),
              // Snapshot has no ordered audio segments; settle the logical turn.
              willSpeak: false,
            ),
          );
        }
      }
      if (terminal == 'failed') runtime.dispatch(TurnFailed(turnId));
      if (terminal == 'cancelled') runtime.dispatch(TurnCancelled(turnId));
      if (terminal == 'completed' &&
          runtime.state.currentTurnId == turnId &&
          runtime.state.activity != CoreState.talking) {
        runtime.dispatch(TtsFailed(turnId));
      }
      activeTurnId = null;
    } catch (_) {
      // The SSE client has its own bounded reconnect. Keep the draft and
      // current turn visible if the snapshot endpoint is unavailable too.
    }
  }

  Future<void> _handle(TurnEventModel event, {required bool speak}) async {
    if (event.turnId != activeTurnId) return;
    if (event.seq <= (_lastSeq[event.turnId] ?? 0)) return;
    _lastSeq[event.turnId] = event.seq;
    switch (event.type) {
      case 'transcript.final':
        final raw = event.payload['user_message'];
        if (raw is Map<String, dynamic>) {
          messages.add(ChatMessageModel.fromJson(raw));
        }
      case 'reply.ready':
        final raw = event.payload['assistant_message'];
        if (raw is Map<String, dynamic>) {
          final message = ChatMessageModel.fromJson(raw);
          _appendAssistant(message);
          runtime.dispatch(
            ReplyReady(
              turnId: event.turnId,
              cue:
                  message.cue ??
                  const CharacterCue(
                    emotion: Emotion.neutral,
                    intensity: Intensity.low,
                  ),
              willSpeak: speak,
            ),
          );
          if (speak && tts.usesNativeText) {
            unawaited(_speakNative(message));
          }
        }
      case 'tts.segment':
        if (tts.usesNativeText) break;
        final model = TtsSegmentModel.fromEvent(event);
        try {
          final bytes = await client.audioBytes(model.mediaUrl);
          if (event.turnId != activeTurnId) return;
          await tts.add(
            TtsAudioSegment(
              turnId: model.turnId,
              index: model.index,
              bytes: Uint8List.fromList(bytes),
              mime: model.mime,
              isLast: model.isLast,
            ),
          );
        } catch (_) {
          runtime.dispatch(TtsFailed(event.turnId));
        }
      case 'tts.failed':
        runtime.dispatch(TtsFailed(event.turnId));
        error = 'Không tạo được giọng nói. Tin nhắn văn bản vẫn dùng được.';
      case 'turn.failed':
        runtime.dispatch(TurnFailed(event.turnId));
        activeTurnId = null;
      case 'turn.cancelled':
        runtime.dispatch(TurnCancelled(event.turnId));
        activeTurnId = null;
      case 'turn.completed':
        activeTurnId = null;
    }
    notifyListeners();
  }

  void _appendAssistant(ChatMessageModel message) {
    if (messages.any((item) => item.id == message.id)) return;
    messages.add(message);
  }

  Future<void> cancelTurn() async {
    final turn = activeTurnId;
    if (turn == null) return;
    await tts.stop();
    runtime.dispatch(const TtsStoppedByUser());
    try {
      await client.cancel(turn);
    } finally {
      runtime.dispatch(TurnCancelled(turn));
      activeTurnId = null;
      notifyListeners();
    }
  }

  Future<void> playMessage(ChatMessageModel message) async {
    final turnId = message.turnId;
    if (turnId == null || message.role != 'assistant') return;
    if (activeTurnId != null) {
      error = 'Hãy đợi lượt hiện tại hoàn tất trước khi phát lại giọng nói.';
      notifyListeners();
      return;
    }
    await stopAudio();
    error = null;
    try {
      manualAudioTurnId = turnId;
      runtime.dispatch(TurnSubmitted(turnId));
      runtime.dispatch(
        ReplyReady(
          turnId: turnId,
          cue:
              message.cue ??
              const CharacterCue(
                emotion: Emotion.neutral,
                intensity: Intensity.low,
              ),
          willSpeak: true,
        ),
      );
      if (tts.usesNativeText) {
        await _speakNative(message);
        notifyListeners();
        return;
      }
      final segments = await client.speech(turnId);
      if (segments.isEmpty) throw StateError('empty speech');
      for (final segment in segments) {
        final bytes = await client.audioBytes(segment.mediaUrl);
        if (manualAudioTurnId != turnId) return;
        await tts.add(
          TtsAudioSegment(
            turnId: turnId,
            index: segment.index,
            bytes: Uint8List.fromList(bytes),
            mime: segment.mime,
            isLast: segment.isLast,
          ),
        );
      }
    } catch (_) {
      manualAudioTurnId = null;
      runtime.dispatch(TtsFailed(turnId));
      error = 'Không tạo được giọng nói. Tin nhắn văn bản vẫn dùng được.';
    }
    notifyListeners();
  }

  Future<void> _speakNative(ChatMessageModel message) async {
    final turnId = message.turnId;
    if (turnId == null) return;
    _requestedSpeechTurnId = turnId;
    try {
      await tts.speakText(
        turnId: turnId,
        text: message.text,
        settings: TtsVoiceSettings(
          voiceIdentifier: preferences.voiceIdentifier,
          rate: preferences.speechRate,
          pitch: preferences.speechPitch,
          volume: preferences.speechVolume,
        ),
      );
    } catch (_) {
      if (_requestedSpeechTurnId == turnId) _requestedSpeechTurnId = null;
      if (manualAudioTurnId == turnId) manualAudioTurnId = null;
      runtime.dispatch(TtsFailed(turnId));
      error = 'Không phát được giọng nói trên thiết bị. Tin nhắn văn bản vẫn dùng được.';
      notifyListeners();
    }
  }

  Future<void> stopAudio({bool interrupted = false}) async {
    final interruptedTurn =
        _requestedSpeechTurnId ?? _playingTurnId ?? manualAudioTurnId;
    await tts.stop();
    _playingTurnId = null;
    _requestedSpeechTurnId = null;
    _earlyTtsStartTurnId = null;
    if (interrupted && interruptedTurn != null) {
      runtime.dispatch(TtsFailed(interruptedTurn));
    } else if (runtime.state.activity == CoreState.talking ||
        manualAudioTurnId != null) {
      runtime.dispatch(const TtsStoppedByUser());
    }
    manualAudioTurnId = null;
    notifyListeners();
  }

  Future<void> beginPtt() async {
    if (recording) return;
    await tts.stop();
    final interruptedTurn = activeTurnId;
    activeTurnId = null;
    await _events?.cancel();
    if (interruptedTurn != null) {
      unawaited(client.cancel(interruptedTurn).catchError((_) {}));
    }
    runtime.dispatch(const PttPressed());
    microphonePermission = await recorder.permissionStatus();
    if (microphonePermission == MicrophonePermissionState.denied ||
        microphonePermission == MicrophonePermissionState.restricted) {
      runtime.dispatch(const PttCancelled());
      error = 'Quyền micro đang bị từ chối. Chat văn bản vẫn dùng được; hãy mở Cài đặt để cấp quyền.';
      notifyListeners();
      return;
    }
    final clientId = _uuid.v4();
    final started = await recorder.start(clientId);
    if (!started) {
      microphonePermission = await recorder.permissionStatus();
      runtime.dispatch(const PttCancelled());
      error = 'Không thể dùng micro. Hãy cấp quyền micro trong Cài đặt.';
      notifyListeners();
      return;
    }
    pendingClientId = clientId;
    recording = true;
    notifyListeners();
  }

  Future<void> endPtt() async {
    if (!recording) return;
    final result = await recorder.stop();
    recording = false;
    if (result == null || result.durationMs < 400) {
      runtime.dispatch(const PttReleased(valid: false));
      if (result != null) await recorder.delete(result.path);
      error = 'Giữ lâu hơn một chút để nói.';
      notifyListeners();
      return;
    }
    runtime.dispatch(const PttReleased(valid: true));
    final clientId = pendingClientId ?? _uuid.v4();
    sending = true;
    notifyListeners();
    try {
      final accepted = await client.createVoiceTurn(
        clientId: clientId,
        path: result.path,
        durationMs: result.durationMs,
        speak: tts.usesNativeText
            ? false
            : preferences.shouldSpeak(voiceInput: true),
        supersede: activeTurnId != null,
        responseMode: preferences.responseMode.apiValue,
        autoPlayVoice: preferences.autoPlayVoice,
        semanticMode: semanticMode,
      );
      await recorder.delete(result.path);
      pendingClientId = null;
      await _follow(accepted, speak: preferences.shouldSpeak(voiceInput: true));
    } catch (exception) {
      error = 'Không gửi được ghi âm. Bản ghi sẽ được xóa để bảo vệ riêng tư.';
      await recorder.delete(result.path);
      runtime.dispatch(const PttUploadFailed());
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  Future<void> cancelPtt() async {
    if (!recording) return;
    await recorder.cancel();
    recording = false;
    runtime.dispatch(const PttCancelled());
    notifyListeners();
  }

  Future<void> openMicrophoneSettings() async {
    await recorder.openSettings();
  }

  void appPaused() {
    if (recording) unawaited(cancelPtt());
    unawaited(stopAudio(interrupted: true));
  }

  String _networkMessage(DioException exception) =>
      exception.type == DioExceptionType.connectionError
      ? 'Không kết nối được backend. Nội dung vẫn còn để thử lại.'
      : 'Không gửi được tin nhắn. Anh thử lại nhé.';

  @override
  void dispose() {
    runtime.removeListener(_flushEarlyTtsStart);
    recorder.onInterrupted = null;
    unawaited(_events?.cancel());
    unawaited(tts.dispose());
    super.dispose();
  }
}
