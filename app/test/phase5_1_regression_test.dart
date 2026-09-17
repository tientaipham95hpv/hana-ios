import 'package:flutter_test/flutter_test.dart';
import 'package:hana_app/app/build_capabilities.dart';
import 'package:hana_app/character/engine/character_cue.dart';
import 'package:hana_app/character/engine/character_engine.dart';
import 'package:hana_app/character/engine/clock.dart';
import 'package:hana_app/character/engine/effect_executor.dart';
import 'package:hana_app/character/engine/engine_effect.dart';
import 'package:hana_app/character/engine/engine_event.dart';
import 'package:hana_app/character/engine/engine_state.dart';
import 'package:hana_app/character/engine/session_manager.dart';
import 'package:hana_app/character/engine/timer_driver.dart';
import 'package:hana_app/character/manifest/manifest_models.dart';
import 'package:hana_app/character/policy/owner_policy.dart';
import 'package:hana_app/character/resolver/asset_resolver.dart';
import 'package:hana_app/character/resolver/random_source.dart';
import 'package:hana_app/character/stage/asset_repository.dart';
import 'package:hana_app/core/secure_window_coordinator.dart';
import 'package:hana_app/core/secure_window_service.dart';
import 'package:hana_app/private_mode/private_session.dart';

import 'support/canonical_manifest.dart';

void main() {
  final manifest = canonicalManifest();

  EngineSession session({
    int seed = 12,
    FakeClock? clock,
    OwnerPolicy? policy,
  }) {
    final actualClock = clock ?? FakeClock(DateTime.utc(2026));
    return EngineSession(
      engine: CharacterEngine(clock: actualClock),
      state: CharacterEngineState(
        manifest: manifest,
        ownerPolicy: policy ?? const OwnerPolicy(),
        privateSessionActive: false,
        randomSeed: seed,
        readyAssetIds: manifest.byId.keys.toSet(),
        readyPosterIds: manifest.byId.keys.toSet(),
      ),
    );
  }

  group('S1 private gate and auto-lock', () {
    test('release capability cannot enable developer/private routes', () {
      expect(
        BuildCapabilities.developerSurfacesFor(
          debugBuild: false,
          explicitlyEnabled: true,
        ),
        isFalse,
      );
    });

    test('production unlock service fails closed', () async {
      expect(await const UnavailablePrivateUnlockService().unlock(), isNull);
    });

    test('expired unlock proof cannot create a private engine', () async {
      final clock = FakeClock(DateTime.utc(2026));
      final auth = await DevelopmentPrivateUnlockService(clock: clock).unlock();
      final manager = CharacterEngineSessionManager(
        normalManifest: manifest,
        ownerPolicy: const OwnerPolicy(),
        clock: clock,
      );
      clock.advance(const Duration(hours: 1));
      expect(
        () => manager.openPrivate(manifest, const OwnerPolicy(), auth!),
        throwsStateError,
      );
      expect(manager.isPrivateOpen, isFalse);
    });

    test('background boundary is 59/60 seconds', () {
      final clock = FakeClock(DateTime.utc(2026));
      final policy = PrivateAutoLockPolicy(clock: clock)..onPrivateUnlocked();
      policy.onAppPaused();
      clock.advance(const Duration(seconds: 59));
      expect(policy.onAppResumed(), isNull);
      policy.onAppPaused();
      clock.advance(const Duration(seconds: 60));
      expect(policy.onAppResumed(), PrivateLockReason.backgroundTimeout);
    });

    test('private inactivity boundary is 14:59/15:00', () {
      final clock = FakeClock(DateTime.utc(2026));
      final policy = PrivateAutoLockPolicy(clock: clock)..onPrivateUnlocked();
      clock.advance(const Duration(minutes: 14, seconds: 59));
      expect(policy.inactivityReason(), isNull);
      clock.advance(const Duration(seconds: 1));
      expect(policy.inactivityReason(), PrivateLockReason.inactivity);
    });

    test('lock destroys private engine and preserves owner policy', () async {
      const owner = OwnerPolicy(relationshipStageEnabled: true);
      final manager = CharacterEngineSessionManager(
        normalManifest: manifest,
        ownerPolicy: owner,
      );
      final auth = await DevelopmentPrivateUnlockService().unlock();
      final private = manager.openPrivate(manifest, owner, auth!);
      manager.lockPrivate();
      expect(manager.privateSession, isNull);
      expect(private.isDisposed, isTrue);
      expect(private.dispatch(const AppStarted()).effects, isEmpty);
      expect(manager.normal.state.activity, CoreState.idle);
      expect(manager.normal.state.stageContext, StageContext.daily);
      expect(manager.normal.state.ownerPolicy.relationshipStageEnabled, isTrue);
    });
  });

  group('event correlation and priority', () {
    test('same state/event replays the same visual without mutable RNG', () {
      final current = session();
      final base = current.state;
      final first = current.engine.reduce(base, const AppStarted());
      final second = current.engine.reduce(base, const AppStarted());
      expect(
        first.state.lastResolution?.assetId,
        second.state.lastResolution?.assetId,
      );
      expect(first.state.randomCounter, second.state.randomCounter);
    });
    test('stale ClipEnded and ClipError cannot replace current play', () {
      final current = session()..dispatch(const AppStarted());
      final old = current.state.lastResolution!.playRequest!;
      current.dispatch(const PttPressed());
      final before = current.state;
      expect(
        current
            .dispatch(ClipEnded(old.asset.assetId, playId: old.playId))
            .state,
        same(before),
      );
      current.dispatch(ClipError(old.asset.assetId, 'old', playId: old.playId));
      expect(current.state.brokenAssetIds, isNot(contains(old.asset.assetId)));
      expect(current.state.activity, CoreState.listening);
    });

    test('slow initialization does not permanently corrupt asset', () {
      final current = session()..dispatch(const AppStarted());
      final play = current.state.lastResolution!.playRequest!;
      current.dispatch(
        ClipError(
          play.asset.assetId,
          'timeout',
          playId: play.playId,
          isPermanent: false,
        ),
      );
      expect(current.state.brokenAssetIds, isNot(contains(play.asset.assetId)));
      expect(current.state.transientAssetIds, contains(play.asset.assetId));
      current.dispatch(
        Tick('retry_asset', current.state.timerTokens['retry_asset']!),
      );
      expect(current.state.transientAssetIds, isEmpty);
    });

    test('cancelled turn ignores late ReplyReady', () {
      final current = session()..dispatch(const TurnSubmitted('A'));
      current.dispatch(const TurnCancelled('A'));
      final result = current.dispatch(
        const ReplyReady(
          turnId: 'A',
          cue: CharacterCue(emotion: Emotion.happy, intensity: Intensity.low),
          willSpeak: true,
        ),
      );
      expect(result.effects, isEmpty);
      expect(result.state.activity, CoreState.idle);
    });

    test('TtsFinished after barge-in cannot end listening', () {
      final clock = FakeClock(DateTime.utc(2026));
      final current = session(clock: clock)..dispatch(const TurnSubmitted('A'));
      current.dispatch(
        const ReplyReady(
          turnId: 'A',
          cue: CharacterCue(emotion: Emotion.neutral, intensity: Intensity.low),
          willSpeak: true,
        ),
      );
      clock.advance(const Duration(milliseconds: 500));
      current.dispatch(
        Tick(
          'thinking_min_dwell',
          current.state.timerTokens['thinking_min_dwell']!,
          turnId: current.state.currentTurnId,
        ),
      );
      current.dispatch(const TtsStarted('A'));
      current.dispatch(const PttPressed());
      current.dispatch(const TtsFinished('A'));
      expect(current.state.activity, CoreState.listening);
    });

    test('JobFinished cannot interrupt talking and tracks job IDs', () {
      final clock = FakeClock(DateTime.utc(2026));
      final current = session(clock: clock)
        ..dispatch(const JobStarted('job'))
        ..dispatch(const TurnSubmitted('A'));
      current.dispatch(
        const ReplyReady(
          turnId: 'A',
          cue: CharacterCue(emotion: Emotion.neutral, intensity: Intensity.low),
          willSpeak: true,
        ),
      );
      clock.advance(const Duration(milliseconds: 500));
      current.dispatch(
        Tick(
          'thinking_min_dwell',
          current.state.timerTokens['thinking_min_dwell']!,
          turnId: current.state.currentTurnId,
        ),
      );
      current.dispatch(const TtsStarted('A'));
      current.dispatch(const JobFinished('job'));
      expect(current.state.activity, CoreState.talking);
      expect(current.state.activeJobIds, isEmpty);
    });

    test('stale timer token is ignored', () {
      final current = session()..dispatch(const AppStarted());
      final token = current.state.timerTokens['idle_to_sleep']!;
      current.dispatch(const UserActivity());
      current.dispatch(Tick('idle_to_sleep', token));
      expect(current.state.activity, CoreState.idle);
    });

    test(
      'paused normal engine ignores foreground input; long resume resets daily',
      () {
        final clock = FakeClock(DateTime.utc(2026));
        final current = session(
          clock: clock,
          policy: const OwnerPolicy(relationshipStageEnabled: true),
        )..dispatch(const AppStarted());
        current.state = current.state.copyWith(
          stageContext: StageContext.relationship,
        );
        current.dispatch(const AppPaused());
        current.dispatch(const PttPressed());
        expect(current.state.activity, CoreState.idle);
        clock.advance(const Duration(seconds: 60));
        current.dispatch(const AppResumed());
        expect(current.state.stageContext, StageContext.daily);
        expect(current.state.activity, CoreState.idle);
        expect(current.state.timerTokens['idle_to_sleep'], isNotNull);
      },
    );
  });

  group('timers, sleep, reaction and runtime', () {
    test('quiet/day sleep deadlines and wake are deterministic', () {
      final clock = FakeClock(DateTime.utc(2026));
      final quiet = session(clock: clock);
      final result = quiet.dispatch(const AppStarted(inQuietHours: true));
      final schedule = result.effects.whereType<ScheduleTick>().singleWhere(
        (effect) => effect.tag == 'idle_to_sleep',
      );
      expect(schedule.at.difference(clock.now()), const Duration(minutes: 1));
      quiet.dispatch(Tick(schedule.tag, schedule.token));
      expect(quiet.state.activity, CoreState.sleep);
      quiet.dispatch(const UserActivity());
      expect(quiet.state.activity, CoreState.idle);

      final day = session(clock: clock).dispatch(const AppStarted());
      final daySchedule = day.effects.whereType<ScheduleTick>().singleWhere(
        (effect) => effect.tag == 'idle_to_sleep',
      );
      expect(
        daySchedule.at.difference(clock.now()),
        const Duration(minutes: 30),
      );
    });

    test('reaction loop always exits on overlay timeout across seeds', () {
      for (var seed = 0; seed < 100; seed++) {
        final clock = FakeClock(DateTime.utc(2026));
        final current = session(
          seed: seed,
          clock: clock,
          policy: const OwnerPolicy(relationshipStageEnabled: true),
        )..dispatch(const TurnSubmitted('t'));
        current.dispatch(
          const ReplyReady(
            turnId: 't',
            cue: CharacterCue(
              emotion: Emotion.shy,
              intensity: Intensity.medium,
              stageContext: StageContext.relationship,
            ),
            willSpeak: false,
          ),
        );
        clock.advance(const Duration(milliseconds: 500));
        current.dispatch(
          Tick(
            'thinking_min_dwell',
            current.state.timerTokens['thinking_min_dwell']!,
            turnId: current.state.currentTurnId,
          ),
        );
        final token = current.state.timerTokens['overlay_max']!;
        current.dispatch(
          Tick('overlay_max', token, turnId: current.state.currentTurnId),
        );
        expect(current.state.activity, CoreState.idle, reason: 'seed $seed');
      }
    });

    test('thinking dwell holds reply for 499 ms and releases at 500 ms', () {
      final clock = FakeClock(DateTime.utc(2026));
      final current = session(clock: clock)
        ..dispatch(const TurnSubmitted('dwell'));
      final deferred = current.dispatch(
        const ReplyReady(
          turnId: 'dwell',
          cue: CharacterCue(
            emotion: Emotion.surprised,
            intensity: Intensity.low,
          ),
          willSpeak: true,
        ),
      );
      expect(deferred.state.activity, CoreState.thinking);
      final tick = deferred.effects.whereType<ScheduleTick>().single;
      clock.advance(const Duration(milliseconds: 499));
      expect(current.state.activity, CoreState.thinking);
      clock.advance(const Duration(milliseconds: 1));
      current.dispatch(Tick(tick.tag, tick.token, turnId: tick.turnId));
      expect(current.state.activity, CoreState.surprised);
    });

    test(
      'pre-speech clip ending early waits min duration then releases TTS gate',
      () {
        final clock = FakeClock(DateTime.utc(2026));
        final current = session(clock: clock)
          ..dispatch(const TurnSubmitted('pre'));
        current.dispatch(
          const ReplyReady(
            turnId: 'pre',
            cue: CharacterCue(
              emotion: Emotion.surprised,
              intensity: Intensity.low,
            ),
            willSpeak: true,
          ),
        );
        clock.advance(const Duration(milliseconds: 500));
        current.dispatch(
          Tick(
            'thinking_min_dwell',
            current.state.timerTokens['thinking_min_dwell']!,
            turnId: current.state.currentTurnId,
          ),
        );
        final play = current.state.lastResolution?.playRequest;
        if (play != null) {
          current.dispatch(ClipEnded(play.asset.assetId, playId: play.playId));
          expect(current.state.activity, CoreState.surprised);
          clock.advance(const Duration(milliseconds: 1500));
          final result = current.dispatch(
            Tick(
              'overlay_min',
              current.state.timerTokens['overlay_min']!,
              turnId: current.state.currentTurnId,
            ),
          );
          expect(result.effects.whereType<ReleaseTtsGate>(), isNotEmpty);
        } else {
          final result = current.dispatch(
            Tick(
              'overlay_max',
              current.state.timerTokens['overlay_max']!,
              turnId: current.state.currentTurnId,
            ),
          );
          expect(result.effects.whereType<ReleaseTtsGate>(), isNotEmpty);
        }
        expect(current.state.activity, CoreState.thinking);
        current.dispatch(const TtsStarted('pre'));
        expect(current.state.activity, CoreState.talking);
      },
    );

    test('effect executor runs timers, TTS gate, stop, pause and log', () {
      final clock = FakeClock(DateTime.utc(2026));
      final timers = FakeTimerDriver(clock);
      final events = <EngineEvent>[];
      var released = 0;
      var stopped = 0;
      var paused = false;
      final logs = <String>[];
      final executor = EngineEffectExecutor(
        timerDriver: timers,
        dispatch: events.add,
        repository: const MockVaultAssetRepository(),
        ports: EngineRuntimePorts(
          onReleaseTtsGate: () => released++,
          onStopTts: () => stopped++,
          onStagePaused: (value) => paused = value,
          onLog: logs.add,
        ),
      );
      executor.execute([
        ScheduleTick(clock.now().add(const Duration(seconds: 1)), 'x', 9),
        const ReleaseTtsGate(),
        const StopTts(),
        const PauseStage(),
        const LogEngine('TEST'),
      ]);
      expect((released, stopped, paused), (1, 1, true));
      expect(logs, ['TEST']);
      timers.elapse(const Duration(milliseconds: 999));
      expect(events, isEmpty);
      timers.elapse(const Duration(milliseconds: 1));
      expect(events.single, isA<Tick>());
      expect((events.single as Tick).token, 9);
    });
  });

  test(
    'audio_streams defense prevents a manually supplied asset candidate',
    () {
      final source = manifest.assets.first;
      final unsafe = CharacterAsset(
        assetId: source.assetId,
        delivery: source.delivery,
        contentSensitivity: source.contentSensitivity,
        allowedModes: source.allowedModes,
        technicalQuality: source.technicalQuality,
        reviewFlag: source.reviewFlag,
        excludedByDefault: false,
        states: const {CoreState.idle: PoolRole.primary},
        cues: source.cues,
        kind: source.kind,
        loopGrade: source.loopGrade,
        loopQuality: source.loopQuality,
        weight: source.weight,
        path: source.path,
        poster: source.poster,
        posterBlur: source.posterBlur,
        durationMs: source.durationMs,
        width: source.width,
        height: source.height,
        renderMode: source.renderMode,
        focalX: source.focalX,
        focalY: source.focalY,
        audioStreams: 1,
        sha256: source.sha256,
        bytes: source.bytes,
      );
      final unsafeManifest = CharacterManifest(
        schemaVersion: 2,
        manifestKind: ManifestKind.vault,
        manifestVersion: 'unsafe-test',
        assets: [unsafe],
        cues: const [],
      );
      final result = AssetResolver(SeededRandomSource(1)).resolve(
        ResolverInput(
          manifest: unsafeManifest,
          requestedState: CoreState.idle,
          stageContext: StageContext.daily,
          ownerPolicy: const OwnerPolicy(),
          readyAssetIds: {unsafe.assetId},
          readyPosterIds: const {},
          brokenAssetIds: const {},
          recentUsage: const [],
          privateSessionActive: false,
        ),
      );
      expect(result.kind, VisualKind.silhouette);
    },
  );

  test('FLAG_SECURE private lifecycle restores exact home policy', () async {
    final port = _RecordingSecureWindow();
    final coordinator = SecureWindowCoordinator(service: port);
    const off = OwnerPolicy(secureWindowMode: SecureWindowMode.off);
    await coordinator.enterPrivate();
    await coordinator.leavePrivate(manifest, off);
    expect(port.values, [true, false]);
    port.values.clear();
    await coordinator.enterPrivate();
    await coordinator.leavePrivate(manifest, const OwnerPolicy());
    expect(port.values, [true, true]);
  });
}

class _RecordingSecureWindow implements SecureWindowPort {
  final values = <bool>[];

  @override
  Future<void> setBlocked(bool enabled) async => values.add(enabled);
}
