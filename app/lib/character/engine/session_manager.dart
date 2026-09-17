import '../manifest/manifest_models.dart';
import '../policy/owner_policy.dart';
import 'character_engine.dart';
import 'clock.dart';
import 'engine_event.dart';
import 'engine_state.dart';
import '../../private_mode/private_session.dart';

class EngineSession {
  EngineSession({required this.engine, required this.state});
  final CharacterEngine engine;
  CharacterEngineState state;

  bool get isDisposed => state.disposed;

  EngineResult dispatch(EngineEvent event) {
    final result = engine.reduce(state, event);
    state = result.state;
    return result;
  }

  void dispose() {
    state = state.copyWith(
      disposed: true,
      clearTurnId: true,
      clearPendingCue: true,
      activeJobIds: const <String>{},
      readyAssetIds: const <String>{},
      readyPosterIds: const <String>{},
      timerTokens: const <String, int>{},
    );
  }
}

class CharacterEngineSessionManager {
  CharacterEngineSessionManager({
    required CharacterManifest normalManifest,
    required OwnerPolicy ownerPolicy,
    Clock clock = const SystemClock(),
    int seed = 42,
  }) : _clock = clock,
       _seed = seed,
       normal = _create(normalManifest, ownerPolicy, false, clock, seed);

  final Clock _clock;
  final int _seed;
  final EngineSession normal;
  EngineSession? _private;

  EngineSession? get privateSession => _private;
  bool get isPrivateOpen => _private != null;

  EngineSession openPrivate(
    CharacterManifest privateManifest,
    OwnerPolicy policy,
    PrivateSessionAuthorization authorization,
  ) {
    if (!authorization.isValidAt(_clock.now())) {
      throw StateError('PRIVATE_SESSION_REQUIRED');
    }
    if (_private != null) throw StateError('private session already open');
    normal.dispatch(const AppPaused());
    _private = _create(privateManifest, policy, true, _clock, _seed + 1);
    _private!.dispatch(const AppStarted());
    return _private!;
  }

  void lockPrivate() {
    _private?.dispose();
    _private = null;
    normal.state = normal.state.copyWith(
      activity: CoreState.idle,
      stageContext: StageContext.daily,
      clearTurnId: true,
      clearPendingCue: true,
    );
    normal.dispatch(const AppResumed());
  }

  static EngineSession _create(
    CharacterManifest manifest,
    OwnerPolicy policy,
    bool privateSession,
    Clock clock,
    int seed,
  ) {
    final engine = CharacterEngine(clock: clock);
    return EngineSession(
      engine: engine,
      state: CharacterEngineState(
        manifest: manifest,
        ownerPolicy: policy,
        privateSessionActive: privateSession,
        randomSeed: seed,
        stageContext: privateSession
            ? StageContext.private
            : StageContext.daily,
      ),
    );
  }
}
