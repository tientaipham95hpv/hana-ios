import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../character/engine/character_cue.dart';
import '../character/engine/engine_event.dart';
import '../app/character_runtime_controller.dart';
import '../character/manifest/manifest_models.dart';
import '../core/secure_window_coordinator.dart';
import '../core/secure_window_service.dart';
import '../character/engine/clock.dart';
import '../character/engine/timer_driver.dart';
import 'private_session.dart';

class PrivateModeScreen extends ConsumerStatefulWidget {
  const PrivateModeScreen({
    super.key,
    this.clock = const SystemClock(),
    this.timerDriver,
    this.unlockService,
  });

  final Clock clock;
  final TimerDriver? timerDriver;
  final PrivateUnlockService? unlockService;

  @override
  ConsumerState<PrivateModeScreen> createState() => _PrivateModeScreenState();
}

class _PrivateModeScreenState extends ConsumerState<PrivateModeScreen>
    with WidgetsBindingObserver {
  Clock get _clock => widget.clock;
  late final PrivateAutoLockPolicy _autoLock = PrivateAutoLockPolicy(
    clock: _clock,
  );
  late final TimerDriver _timer =
      widget.timerDriver ?? SystemTimerDriver(_clock);
  CharacterRuntimeController? _runtime;
  var _locked = false;
  var _unavailable = false;
  var _privacyOverlay = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  Future<void> _open() async {
    final authorization =
        await (widget.unlockService ??
                DevelopmentPrivateUnlockService(clock: _clock))
            .unlock();
    if (authorization == null || !mounted) {
      if (mounted) setState(() => _unavailable = true);
      return;
    }
    final manifest = ref.read(manifestProvider);
    final policy = ref.read(ownerPolicyProvider);
    await const SecureWindowCoordinator().enterPrivate();
    _runtime = ref.read(characterRuntimeProvider);
    _runtime!.openPrivate(manifest, policy, authorization);
    _autoLock.onPrivateUnlocked();
    _scheduleInactivity();
    _timer.schedule('private_session_expiry', authorization.expiresAt, _lock);
    if (mounted) setState(() {});
  }

  void _scheduleInactivity() {
    final deadline = _autoLock.inactivityDeadline;
    if (deadline == null) return;
    _timer.schedule('private_inactivity', deadline, () {
      if (_autoLock.inactivityReason() != null) {
        _lock();
      } else {
        // A millisecond-granularity timer can fire just before the
        // monotonic clock reaches its deadline. Never lose the lock.
        _scheduleInactivity();
      }
    });
  }

  void _activity() {
    _autoLock.onUserActivity();
    _timer.cancel('private_inactivity');
    _scheduleInactivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive && mounted) {
      setState(() => _privacyOverlay = true);
    } else if (state == AppLifecycleState.paused) {
      _autoLock.onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      final reason = _autoLock.onAppResumed();
      if (reason != null) {
        _lock();
      } else if (mounted) {
        setState(() => _privacyOverlay = false);
      }
    }
  }

  Future<void> _lock() async {
    if (_locked) return;
    _locked = true;
    if (mounted) Navigator.pop(context);
    _timer.cancelAll();
    _autoLock.onPrivateLocked();
    _runtime?.lockPrivate();
    _runtime = null;
    await const SecureWindowService().clearPrivateRuntime();
    await const SecureWindowCoordinator().leavePrivate(
      ref.read(manifestProvider),
      ref.read(ownerPolicyProvider),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer.cancelAll();
    if (!_locked) {
      _runtime?.lockPrivate();
      _autoLock.onPrivateLocked();
      SecureWindowService().clearPrivateRuntime();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final private = _runtime?.privateSession;
    if (_unavailable) {
      return const Scaffold(body: Center(child: Text('Private unavailable')));
    }
    if (private == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (_, result) => _lock(),
      child: Scaffold(
        backgroundColor: const Color(0xFF21141B),
        appBar: AppBar(
          backgroundColor: const Color(0xFF21141B),
          foregroundColor: Colors.white,
          automaticallyImplyLeading: false,
          title: const Text('Private session'),
          actions: [
            TextButton.icon(
              key: const Key('lock-private'),
              onPressed: _lock,
              icon: const Icon(Icons.lock, color: Colors.white),
              label: const Text('Khóa', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
        body: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.privacy_tip_outlined,
                      color: Colors.white,
                      size: 64,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Private engine đang hoạt động',
                      style: TextStyle(color: Colors.white, fontSize: 20),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Context: ${private.state.stageContext.name}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () {
                        _activity();
                        _runtime!.dispatchPrivate(
                          const CueReceived(
                            CharacterCue(
                              emotion: Emotion.shy,
                              intensity: Intensity.medium,
                            ),
                          ),
                        );
                        setState(() {});
                      },
                      child: const Text('Demo private reaction'),
                    ),
                  ],
                ),
              ),
            ),
            if (_privacyOverlay)
              const Positioned.fill(
                child: ColoredBox(
                  key: Key('private-privacy-overlay'),
                  color: Color(0xFF171217),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
