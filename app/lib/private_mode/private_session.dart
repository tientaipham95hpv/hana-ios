import 'package:flutter/foundation.dart';

import '../character/engine/clock.dart';

class PrivateSessionAuthorization {
  PrivateSessionAuthorization._({required this.expiresAt, required this.nonce});

  final DateTime expiresAt;
  final String nonce;

  bool isValidAt(DateTime now) => nonce.isNotEmpty && now.isBefore(expiresAt);
}

abstract interface class PrivateUnlockService {
  Future<PrivateSessionAuthorization?> unlock();
}

class UnavailablePrivateUnlockService implements PrivateUnlockService {
  const UnavailablePrivateUnlockService();

  @override
  Future<PrivateSessionAuthorization?> unlock() async => null;
}

/// Debug-only credential issuer. The constant branch is removed from release AOT.
class DevelopmentPrivateUnlockService implements PrivateUnlockService {
  DevelopmentPrivateUnlockService({this.clock = const SystemClock()});

  final Clock clock;

  @override
  Future<PrivateSessionAuthorization?> unlock() async {
    if (!kDebugMode) return null;
    return PrivateSessionAuthorization._(
      expiresAt: clock.now().add(const Duration(hours: 1)),
      nonce: 'debug-session',
    );
  }
}

enum PrivateLockReason { manual, backgroundTimeout, inactivity, sessionError }

class PrivateAutoLockPolicy {
  PrivateAutoLockPolicy({required this.clock});

  static const backgroundLimit = Duration(seconds: 60);
  static const inactivityLimit = Duration(minutes: 15);

  final Clock clock;
  DateTime? _pausedAt;
  DateTime? _lastActivityAt;
  bool _unlocked = false;

  void onPrivateUnlocked() {
    _unlocked = true;
    _pausedAt = null;
    _lastActivityAt = clock.now();
  }

  void onPrivateLocked() {
    _unlocked = false;
    _pausedAt = null;
    _lastActivityAt = null;
  }

  void onAppPaused() {
    if (_unlocked) _pausedAt = clock.now();
  }

  PrivateLockReason? onAppResumed() {
    if (!_unlocked) return null;
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt != null &&
        clock.now().difference(pausedAt) >= backgroundLimit) {
      return PrivateLockReason.backgroundTimeout;
    }
    return inactivityReason();
  }

  void onUserActivity() {
    if (_unlocked) _lastActivityAt = clock.now();
  }

  DateTime? get inactivityDeadline => _unlocked && _lastActivityAt != null
      ? _lastActivityAt!.add(inactivityLimit)
      : null;

  PrivateLockReason? inactivityReason() {
    final last = _lastActivityAt;
    if (!_unlocked || last == null) return null;
    return clock.now().difference(last) >= inactivityLimit
        ? PrivateLockReason.inactivity
        : null;
  }
}
