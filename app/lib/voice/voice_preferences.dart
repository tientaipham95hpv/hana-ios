import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/secure_store.dart';

enum VoiceResponseMode { auto, textOnly, voiceReply }

extension VoiceResponseModeValue on VoiceResponseMode {
  String get apiValue => switch (this) {
    VoiceResponseMode.auto => 'AUTO',
    VoiceResponseMode.textOnly => 'TEXT_ONLY',
    VoiceResponseMode.voiceReply => 'VOICE_REPLY',
  };
}

abstract interface class VoicePreferenceStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureVoicePreferenceStore implements VoicePreferenceStore {
  const SecureVoicePreferenceStore(this.secureStore);
  final HanaSecureStore secureStore;

  @override
  Future<String?> read(String key) => secureStore.storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      secureStore.storage.write(key: key, value: value);
}

class MemoryVoicePreferenceStore implements VoicePreferenceStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class VoicePreferences extends ChangeNotifier {
  VoicePreferences({required this.store});

  static const _modeKey = 'voice.response_mode.v1';
  static const _autoPlayKey = 'voice.auto_play.v1';
  static const _voiceIdentifierKey = 'voice.ios.identifier.v1';
  static const _rateKey = 'voice.ios.rate.v1';
  static const _pitchKey = 'voice.ios.pitch.v1';
  static const _volumeKey = 'voice.ios.volume.v1';
  final VoicePreferenceStore store;

  VoiceResponseMode responseMode = VoiceResponseMode.auto;
  bool autoPlayVoice = true;
  String? voiceIdentifier;
  double speechRate = 0.5;
  double speechPitch = 1;
  double speechVolume = 1;
  bool loaded = false;

  Future<void> load() async {
    final storedMode = await store.read(_modeKey);
    responseMode = VoiceResponseMode.values.firstWhere(
      (mode) => mode.apiValue == storedMode,
      orElse: () => VoiceResponseMode.auto,
    );
    autoPlayVoice = await store.read(_autoPlayKey) != 'false';
    final storedVoice = await store.read(_voiceIdentifierKey);
    voiceIdentifier = storedVoice == null || storedVoice.isEmpty
        ? null
        : storedVoice;
    speechRate = _storedDouble(await store.read(_rateKey), 0.5, 0.1, 0.65);
    speechPitch = _storedDouble(await store.read(_pitchKey), 1, 0.5, 2);
    speechVolume = _storedDouble(await store.read(_volumeKey), 1, 0, 1);
    loaded = true;
    notifyListeners();
  }

  Future<void> setResponseMode(VoiceResponseMode value) async {
    responseMode = value;
    notifyListeners();
    await store.write(_modeKey, value.apiValue);
  }

  Future<void> setAutoPlayVoice(bool value) async {
    autoPlayVoice = value;
    notifyListeners();
    await store.write(_autoPlayKey, value.toString());
  }

  Future<void> setVoiceIdentifier(String? value) async {
    voiceIdentifier = value == null || value.isEmpty ? null : value;
    notifyListeners();
    await store.write(_voiceIdentifierKey, voiceIdentifier ?? '');
  }

  Future<void> setSpeechRate(double value) async {
    speechRate = value.clamp(0.1, 0.65);
    notifyListeners();
    await store.write(_rateKey, speechRate.toString());
  }

  Future<void> setSpeechPitch(double value) async {
    speechPitch = value.clamp(0.5, 2);
    notifyListeners();
    await store.write(_pitchKey, speechPitch.toString());
  }

  Future<void> setSpeechVolume(double value) async {
    speechVolume = value.clamp(0, 1);
    notifyListeners();
    await store.write(_volumeKey, speechVolume.toString());
  }

  static double _storedDouble(
    String? raw,
    double fallback,
    double minimum,
    double maximum,
  ) => (double.tryParse(raw ?? '') ?? fallback).clamp(minimum, maximum);

  bool shouldSpeak({required bool voiceInput}) {
    if (!autoPlayVoice || responseMode == VoiceResponseMode.textOnly) {
      return false;
    }
    return responseMode == VoiceResponseMode.voiceReply || voiceInput;
  }
}
