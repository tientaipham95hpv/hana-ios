import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'tts_queue.dart';

/// iOS-only speech output backed by AVSpeechSynthesizer through a platform
/// channel. The utterance token includes a local generation so callbacks from
/// stopped speech can never finish a newer turn.
class IosNativeTtsQueue implements TtsQueue {
  IosNativeTtsQueue({this._channel = const MethodChannel('hana/native_tts')}) {
    _channel.setMethodCallHandler(handleNativeEvent);
  }

  final MethodChannel _channel;
  int _generation = 0;
  String? _activeTurnId;
  String? _activeUtteranceId;
  bool _disposed = false;

  @override
  bool get usesNativeText => true;

  @override
  void Function(String turnId)? onStarted;
  @override
  void Function(String turnId)? onFinished;
  @override
  void Function(String turnId)? onCancelled;
  @override
  void Function(String turnId)? onFailed;

  @override
  Future<void> configure() async {
    await _channel.invokeMethod<void>('configure', const {'language': 'vi-VN'});
  }

  @override
  Future<List<TtsVoice>> availableVoices() async {
    final raw = await _channel.invokeListMethod<dynamic>('listVoices');
    return (raw ?? const <dynamic>[])
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .map(
          (value) => TtsVoice(
            name: value['name'] as String? ?? '',
            identifier: value['identifier'] as String? ?? '',
            locale: value['locale'] as String? ?? '',
            quality: value['quality'] as String? ?? 'default',
          ),
        )
        .where((voice) => voice.identifier.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<void> speakText({
    required String turnId,
    required String text,
    required TtsVoiceSettings settings,
  }) async {
    if (_disposed) throw StateError('Native TTS has been disposed');
    final normalized = text.trim();
    if (normalized.isEmpty) throw ArgumentError.value(text, 'text', 'empty');
    await stop();
    final utteranceId = '$turnId:${++_generation}';
    _activeTurnId = turnId;
    _activeUtteranceId = utteranceId;
    try {
      await _channel.invokeMethod<void>('speak', {
        'utteranceId': utteranceId,
        'text': normalized,
        'language': 'vi-VN',
        'voiceIdentifier': settings.voiceIdentifier,
        'rate': settings.rate.clamp(0.1, 0.65),
        'pitch': settings.pitch.clamp(0.5, 2.0),
        'volume': settings.volume.clamp(0.0, 1.0),
      });
    } catch (_) {
      if (_activeUtteranceId == utteranceId) _clear();
      rethrow;
    }
  }

  @override
  Future<void> add(TtsAudioSegment segment) => Future<void>.error(
    UnsupportedError('iOS native TTS consumes reply text, not server audio'),
  );

  @visibleForTesting
  Future<void> handleNativeEvent(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final values = Map<String, dynamic>.from(arguments);
    final utteranceId = values['utteranceId'] as String?;
    if (utteranceId == null || utteranceId != _activeUtteranceId) return;
    final turnId = _activeTurnId;
    if (turnId == null) return;
    switch (call.method) {
      case 'speechStarted':
        onStarted?.call(turnId);
      case 'speechFinished':
        _clear();
        onFinished?.call(turnId);
      case 'speechCancelled':
        _clear();
        onCancelled?.call(turnId);
      case 'speechFailed':
        _clear();
        onFailed?.call(turnId);
    }
  }

  @override
  Future<void> stop() async {
    final hadActiveSpeech = _activeUtteranceId != null;
    _generation++;
    _clear();
    if (hadActiveSpeech) {
      await _channel.invokeMethod<void>('stop');
    }
  }

  void _clear() {
    _activeTurnId = null;
    _activeUtteranceId = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    _channel.setMethodCallHandler(null);
  }
}
