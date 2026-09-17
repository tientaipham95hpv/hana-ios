import 'package:flutter/services.dart';

abstract interface class SecureWindowPort {
  Future<void> setBlocked(bool enabled);
}

class SecureWindowService implements SecureWindowPort {
  const SecureWindowService();
  static const _channel = MethodChannel('hana/secure_window');

  @override
  Future<void> setBlocked(bool enabled) =>
      _channel.invokeMethod<void>('setSecure', {'enabled': enabled});

  Future<void> clearPrivateRuntime() =>
      _channel.invokeMethod<void>('clearPrivateRuntime');
}
