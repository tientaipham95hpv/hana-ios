import 'dart:async';

import 'package:flutter/foundation.dart';

import '../character/engine/clock.dart';
import '../character/engine/effect_executor.dart';
import '../character/engine/character_cue.dart';
import '../character/engine/engine_event.dart';
import '../character/engine/engine_effect.dart';
import '../character/engine/engine_state.dart';
import '../character/engine/session_manager.dart';
import '../character/engine/timer_driver.dart';
import '../character/manifest/manifest_models.dart';
import '../character/policy/owner_policy.dart';
import '../character/stage/asset_repository.dart';
import '../private_mode/private_session.dart';

class CharacterRuntimeController extends ChangeNotifier {
  CharacterRuntimeController({
    required CharacterManifest manifest,
    required OwnerPolicy ownerPolicy,
    required this.repository,
    Clock clock = const SystemClock(),
    TimerDriver? timerDriver,
    TimerDriver? privateTimerDriver,
    EngineRuntimePorts ports = const EngineRuntimePorts(),
    EngineRuntimePorts privatePorts = const EngineRuntimePorts(),
    int seed = 42,
  }) : _manager = CharacterEngineSessionManager(
         normalManifest: manifest,
         ownerPolicy: ownerPolicy,
         clock: clock,
         seed: seed,
       ),
       _timerDriver = timerDriver ?? SystemTimerDriver(clock) {
    _clock = clock;
    _privateTimerDriver = privateTimerDriver;
    _privatePorts = privatePorts;
    _executor = EngineEffectExecutor(
      timerDriver: _timerDriver,
      dispatch: dispatch,
      repository: repository,
      ports: EngineRuntimePorts(
        onPlay: (_) => notifyListeners(),
        onPreload: ports.onPreload,
        onStagePaused: (value) {
          stagePaused = value;
          ports.onStagePaused?.call(value);
          notifyListeners();
        },
        onStopTts: ports.onStopTts,
        onReleaseTtsGate: ports.onReleaseTtsGate,
        onLog: ports.onLog,
      ),
    );
    dispatch(const AppStarted());
  }

  final CharacterAssetRepository repository;
  final CharacterEngineSessionManager _manager;
  final TimerDriver _timerDriver;
  late final Clock _clock;
  TimerDriver? _privateTimerDriver;
  late final EngineRuntimePorts _privatePorts;
  late final EngineEffectExecutor _executor;
  EngineEffectExecutor? _privateExecutor;
  bool stagePaused = false;

  CharacterEngineState get state => _manager.normal.state;
  EngineSession? get privateSession => _manager.privateSession;

  EngineSession openPrivate(
    CharacterManifest manifest,
    OwnerPolicy policy,
    PrivateSessionAuthorization authorization,
  ) {
    if (!authorization.isValidAt(_clock.now())) {
      throw StateError('PRIVATE_SESSION_REQUIRED');
    }
    if (_manager.isPrivateOpen) {
      throw StateError('private session already open');
    }
    dispatch(const AppPaused());
    final private = _manager.openPrivate(manifest, policy, authorization);
    _privateExecutor = EngineEffectExecutor(
      timerDriver: _privateTimerDriver ??= SystemTimerDriver(_clock),
      dispatch: dispatchPrivate,
      repository: repository,
      ports: EngineRuntimePorts(
        onPlay: (_) => notifyListeners(),
        onPreload: _privatePorts.onPreload,
        onStagePaused: _privatePorts.onStagePaused,
        onStopTts: _privatePorts.onStopTts,
        onReleaseTtsGate: _privatePorts.onReleaseTtsGate,
        onLog: _privatePorts.onLog,
      ),
    );
    dispatchPrivate(const AppStarted());
    notifyListeners();
    return private;
  }

  void dispatchPrivate(EngineEvent event) {
    final private = _manager.privateSession;
    if (private == null) return;
    final result = private.dispatch(event);
    _privateExecutor?.execute(result.effects);
    notifyListeners();
  }

  void lockPrivate() {
    if (!_manager.isPrivateOpen) return;
    _privateExecutor?.dispose();
    _privateExecutor = null;
    _manager.lockPrivate();
    _executor.execute(const [ResumeStage()]);
    dispatch(const AppStarted());
  }

  void dispatch(EngineEvent event) {
    if (_manager.isPrivateOpen) return;
    final result = _manager.normal.dispatch(event);
    _executor.execute(result.effects);
    notifyListeners();
  }

  void updateOwnerPolicy(OwnerPolicy policy) {
    _manager.normal.state = state.copyWith(ownerPolicy: policy);
    dispatch(const PolicyUpdated());
  }

  Future<void> refreshVaultAvailability() async {
    final readyVideos = <String>{};
    final readyPosters = <String>{};
    for (final asset in state.manifest.assets) {
      final results = await Future.wait([
        repository.resolve(asset),
        repository.resolvePoster(asset),
      ]);
      if (results[0] != null) readyVideos.add(asset.assetId);
      if (results[1] != null) readyPosters.add(asset.assetId);
    }
    _manager.normal.state = state.copyWith(
      readyAssetIds: Set.unmodifiable(readyVideos),
      readyPosterIds: Set.unmodifiable(readyPosters),
    );
    dispatch(const AssetsAvailabilityChanged());
  }

  Future<void> runConversationDemo() async {
    dispatch(const PttPressed());
    await Future<void>.delayed(const Duration(milliseconds: 350));
    dispatch(const PttReleased(valid: true));
    dispatch(const TurnSubmitted('demo-turn'));
    dispatch(
      const ReplyReady(
        turnId: 'demo-turn',
        cue: CharacterCue(emotion: Emotion.neutral, intensity: Intensity.low),
        willSpeak: true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 550));
    dispatch(const TtsStarted('demo-turn'));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    dispatch(const TtsFinished('demo-turn'));
    dispatch(
      const CueReceived(
        CharacterCue(emotion: Emotion.happy, intensity: Intensity.medium),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final play = state.lastResolution?.playRequest;
    if (play != null) {
      dispatch(ClipEnded(play.asset.assetId, playId: play.playId));
    }
  }

  Future<void> runWorkDemo() async {
    dispatch(const JobStarted('demo-job'));
    await Future<void>.delayed(const Duration(milliseconds: 700));
    dispatch(const JobFinished('demo-job'));
  }

  @override
  void dispose() {
    _privateExecutor?.dispose();
    _executor.dispose();
    super.dispose();
  }
}
