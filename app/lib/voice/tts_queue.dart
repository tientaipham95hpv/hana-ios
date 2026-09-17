// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

class TtsAudioSegment {
  const TtsAudioSegment({
    required this.turnId,
    required this.index,
    required this.bytes,
    required this.mime,
    required this.isLast,
  });
  final String turnId;
  final int index;
  final Uint8List bytes;
  final String mime;
  final bool isLast;
}

class TtsVoice {
  const TtsVoice({
    required this.name,
    required this.identifier,
    required this.locale,
    required this.quality,
  });

  final String name;
  final String identifier;
  final String locale;
  final String quality;
}

class TtsVoiceSettings {
  const TtsVoiceSettings({
    this.voiceIdentifier,
    this.rate = 0.5,
    this.pitch = 1,
    this.volume = 1,
  });

  final String? voiceIdentifier;
  final double rate;
  final double pitch;
  final double volume;
}

abstract interface class TtsQueue {
  bool get usesNativeText;
  void Function(String turnId)? onStarted;
  void Function(String turnId)? onFinished;
  void Function(String turnId)? onCancelled;
  void Function(String turnId)? onFailed;

  Future<void> configure();
  Future<List<TtsVoice>> availableVoices();
  Future<void> speakText({
    required String turnId,
    required String text,
    required TtsVoiceSettings settings,
  });
  Future<void> add(TtsAudioSegment segment);
  Future<void> stop();
  Future<void> dispose();
}

class HanaTtsQueue implements TtsQueue {
  HanaTtsQueue({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;
  final Map<int, TtsAudioSegment> _pending = {};
  int _nextIndex = 0;
  int _generation = 0;
  bool _draining = false;
  bool _started = false;
  String? _turnId;

  @override
  bool get usesNativeText => false;

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
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
  }

  @override
  Future<List<TtsVoice>> availableVoices() async => const [];

  @override
  Future<void> speakText({
    required String turnId,
    required String text,
    required TtsVoiceSettings settings,
  }) => Future<void>.error(
    UnsupportedError('This queue plays server audio rather than native text'),
  );

  @override
  Future<void> add(TtsAudioSegment segment) async {
    if (_turnId != null && _turnId != segment.turnId) {
      await stop();
    }
    _turnId = segment.turnId;
    _pending[segment.index] = segment;
    if (!_draining) unawaited(_drain(_generation));
  }

  Future<void> _drain(int generation) async {
    _draining = true;
    try {
      while (generation == _generation) {
        final segment = _pending.remove(_nextIndex);
        if (segment == null) break;
        final session = await AudioSession.instance;
        if (generation != _generation) return;
        await session.setActive(true);
        if (generation != _generation) return;
        await _player.setAudioSource(
          _MemoryAudioSource(segment.bytes, segment.mime),
        );
        if (generation != _generation) return;
        if (!_started) {
          _started = true;
          onStarted?.call(segment.turnId);
        }
        await _player.play();
        if (generation != _generation) return;
        _nextIndex++;
        if (segment.isLast) {
          await session.setActive(false);
          onFinished?.call(segment.turnId);
          _reset();
          return;
        }
      }
    } catch (_) {
      final turn = _turnId;
      if (turn != null && generation == _generation) onFailed?.call(turn);
      if (generation == _generation) _reset();
    } finally {
      _draining = false;
      if (_pending.containsKey(_nextIndex)) {
        unawaited(_drain(_generation));
      }
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    await _player.stop();
    await (await AudioSession.instance).setActive(false);
    _reset();
  }

  void _reset() {
    _pending.clear();
    _nextIndex = 0;
    _turnId = null;
    _started = false;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }
}

class _MemoryAudioSource extends StreamAudioSource {
  _MemoryAudioSource(this.bytes, this.mime);
  final Uint8List bytes;
  final String mime;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final first = start ?? 0;
    final last = end ?? bytes.length;
    final slice = bytes.sublist(first, last);
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: slice.length,
      offset: first,
      contentType: mime,
      stream: Stream.value(slice),
    );
  }
}
