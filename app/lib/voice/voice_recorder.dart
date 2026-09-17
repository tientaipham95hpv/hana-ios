import 'package:flutter/services.dart';

class VoiceRecording {
  const VoiceRecording({required this.path, required this.durationMs});
  final String path;
  final int durationMs;
}

enum MicrophonePermissionState { notDetermined, granted, denied, restricted }

abstract interface class VoiceRecorder {
  void Function()? onInterrupted;
  Future<MicrophonePermissionState> permissionStatus();
  Future<bool> openSettings();
  Future<bool> start(String clientId);
  Future<VoiceRecording?> stop();
  Future<void> cancel();
  Future<void> delete(String path);
}

class PlatformVoiceRecorder implements VoiceRecorder {
  PlatformVoiceRecorder() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'recordingInterrupted') onInterrupted?.call();
    });
  }
  static const _channel = MethodChannel('hana/voice_recorder');

  @override
  void Function()? onInterrupted;

  @override
  Future<MicrophonePermissionState> permissionStatus() async {
    try {
      final value = await _channel.invokeMethod<String>('permissionStatus');
      return MicrophonePermissionState.values.firstWhere(
        (state) => state.name == value,
        orElse: () => MicrophonePermissionState.notDetermined,
      );
    } on MissingPluginException {
      return MicrophonePermissionState.notDetermined;
    }
  }

  @override
  Future<bool> openSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openSettings') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> start(String clientId) async =>
      await _channel.invokeMethod<bool>('start', {'clientId': clientId}) ??
      false;

  @override
  Future<VoiceRecording?> stop() async {
    final value = await _channel.invokeMapMethod<String, dynamic>('stop');
    if (value == null) return null;
    return VoiceRecording(
      path: value['path'] as String,
      durationMs: value['durationMs'] as int,
    );
  }

  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');

  @override
  Future<void> delete(String path) =>
      _channel.invokeMethod<void>('delete', {'path': path});
}
