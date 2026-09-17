import 'package:flutter_test/flutter_test.dart';
import 'package:hana_app/character/engine/character_cue.dart';
import 'package:hana_app/character/engine/character_engine.dart';
import 'package:hana_app/character/engine/clock.dart';
import 'package:hana_app/character/engine/engine_effect.dart';
import 'package:hana_app/character/engine/engine_event.dart';
import 'package:hana_app/character/engine/engine_state.dart';
import 'package:hana_app/character/engine/session_manager.dart';
import 'package:hana_app/character/manifest/manifest_models.dart';
import 'package:hana_app/character/policy/owner_policy.dart';
import 'package:hana_app/character/resolver/random_source.dart';
import 'package:hana_app/private_mode/private_session.dart';

import 'support/canonical_manifest.dart';

void main() {
  final manifest = canonicalManifest();

  EngineSession session({FakeClock? clock}) {
    final engine = CharacterEngine(
      clock: clock ?? FakeClock(DateTime.utc(2026)),
    );
    return EngineSession(
      engine: engine,
      state: CharacterEngineState(
        manifest: manifest,
        ownerPolicy: const OwnerPolicy(),
        privateSessionActive: false,
        randomSeed: 12,
        readyAssetIds: manifest.byId.keys.toSet(),
        readyPosterIds: manifest.byId.keys.toSet(),
      ),
    );
  }

  test('engine accepts all ten semantic states through events/cues', () {
    final seen = <CoreState>{};
    final clock = FakeClock(DateTime.utc(2026));
    final current = session(clock: clock);
    void fire(EngineEvent event) {
      current.dispatch(event);
      seen.add(current.state.activity);
    }

    fire(const AppStarted());
    fire(const PttPressed());
    fire(const PttReleased(valid: true));
    fire(const TurnSubmitted('turn'));
    fire(
      const ReplyReady(
        turnId: 'turn',
        cue: CharacterCue(emotion: Emotion.neutral, intensity: Intensity.low),
        willSpeak: true,
      ),
    );
    clock.advance(const Duration(milliseconds: 500));
    fire(
      Tick(
        'thinking_min_dwell',
        current.state.timerTokens['thinking_min_dwell']!,
        turnId: current.state.currentTurnId,
      ),
    );
    fire(const TtsStarted('turn'));
    fire(const TtsFinished('turn'));
    fire(const JobStarted('job'));
    fire(const JobFinished('job'));
    fire(const JobStarted('job'));
    fire(const JobFinished('job'));
    var turn = 0;
    for (final emotion in [
      Emotion.happy,
      Emotion.shy,
      Emotion.surprised,
      Emotion.concerned,
    ]) {
      final turnId = 'reaction-${turn++}';
      fire(TurnSubmitted(turnId));
      fire(
        ReplyReady(
          turnId: turnId,
          cue: CharacterCue(emotion: emotion, intensity: Intensity.low),
          willSpeak: false,
        ),
      );
      clock.advance(const Duration(milliseconds: 500));
      fire(
        Tick(
          'thinking_min_dwell',
          current.state.timerTokens['thinking_min_dwell']!,
          turnId: current.state.currentTurnId,
        ),
      );
      final play = current.state.lastResolution!.playRequest!;
      clock.advance(const Duration(milliseconds: 1500));
      fire(ClipEnded(play.asset.assetId, playId: play.playId));
    }
    final sleepToken = current.state.timerTokens['idle_to_sleep']!;
    fire(Tick('idle_to_sleep', sleepToken));
    expect(seen, containsAll(CoreState.values));
  });

  test('PTT barge-in stops TTS and transitions to listening', () {
    final result = session().dispatch(const PttPressed());
    expect(result.state.activity, CoreState.listening);
    expect(result.effects.whereType<StopTts>(), hasLength(1));
  });

  test('PTT release and cancellation follow the transition table', () {
    final current = session();
    current.dispatch(const PttPressed());
    expect(
      current.dispatch(const PttReleased(valid: true)).state.activity,
      CoreState.thinking,
    );
    final cancelled = session()..dispatch(const PttPressed());
    expect(
      cancelled.dispatch(const PttCancelled()).state.activity,
      CoreState.idle,
    );
  });

  test('TTS lifecycle moves talking to reaction and idle', () {
    final clock = FakeClock(DateTime.utc(2026));
    final current = session(clock: clock);
    current.dispatch(const TurnSubmitted('t1'));
    current.dispatch(
      const ReplyReady(
        turnId: 't1',
        cue: CharacterCue(emotion: Emotion.happy, intensity: Intensity.medium),
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
    expect(
      current.dispatch(const TtsStarted('t1')).state.activity,
      CoreState.talking,
    );
    expect(
      current.dispatch(const TtsFinished('t1')).state.activity,
      CoreState.happy,
    );
    clock.advance(const Duration(milliseconds: 1500));
    expect(
      current
          .dispatch(
            ClipEnded(
              current.state.lastResolution!.assetId!,
              playId: current.state.lastResolution!.playRequest!.playId,
            ),
          )
          .state
          .activity,
      CoreState.idle,
    );
  });

  test('TTS failure and cancelled turn fail safely to idle', () {
    final current = session();
    current.dispatch(const TurnSubmitted('t1'));
    expect(
      current.dispatch(const TtsFailed('t1')).state.activity,
      CoreState.idle,
    );
    current.dispatch(const TurnSubmitted('t2'));
    expect(
      current.dispatch(const TurnCancelled('t2')).state.activity,
      CoreState.idle,
    );
  });

  test('stale turn callbacks cannot overwrite the current turn', () {
    final current = session();
    current.dispatch(const TurnSubmitted('new'));
    final result = current.dispatch(const TtsStarted('old'));
    expect(result.state.activity, CoreState.thinking);
    expect(result.effects, isEmpty);
  });

  test('surprised pre-speech reaction uses FakeClock deadline', () {
    final clock = FakeClock(DateTime.utc(2026, 1, 1));
    final current = session(clock: clock);
    current.dispatch(const TurnSubmitted('t1'));
    final deferred = current.dispatch(
      const ReplyReady(
        turnId: 't1',
        cue: CharacterCue(
          emotion: Emotion.surprised,
          intensity: Intensity.high,
        ),
        willSpeak: true,
      ),
    );
    expect(deferred.state.activity, CoreState.thinking);
    clock.advance(const Duration(milliseconds: 500));
    final result = current.dispatch(
      Tick(
        'thinking_min_dwell',
        current.state.timerTokens['thinking_min_dwell']!,
        turnId: current.state.currentTurnId,
      ),
    );
    expect(result.state.activity, CoreState.surprised);
    final tick = result.effects.whereType<ScheduleTick>().singleWhere(
      (effect) => effect.tag == 'pre_speech_max',
    );
    expect(
      tick.at,
      DateTime.utc(2026, 1, 1).add(const Duration(milliseconds: 1700)),
    );
  });

  test('clip errors quarantine the asset and re-resolve', () {
    final current = session();
    current.dispatch(const AppStarted());
    final broken = current.state.lastResolution!.assetId!;
    final result = current.dispatch(
      ClipError(
        broken,
        'decode',
        playId: current.state.lastResolution!.playRequest!.playId,
      ),
    );
    expect(result.state.brokenAssetIds, contains(broken));
    // Old CLIP_ERROR conflated transient initialization timeouts with hard corruption.
    expect(
      result.effects.whereType<LogEngine>().single.code,
      'CLIP_HARD_ERROR',
    );
    expect(result.state.lastResolution?.assetId, isNot(broken));
  });

  test('pause and resume emit stage effects and do not crash', () {
    final current = session();
    final paused = current.dispatch(const AppPaused());
    expect(paused.state.paused, isTrue);
    expect(paused.effects.first, isA<PauseStage>());
    final resumed = current.dispatch(const AppResumed());
    expect(resumed.state.paused, isFalse);
    expect(resumed.effects.first, isA<ResumeStage>());
  });

  test('private engine is isolated and destroyed on lock', () async {
    final manager = CharacterEngineSessionManager(
      normalManifest: manifest,
      ownerPolicy: const OwnerPolicy(),
      seed: 4,
    );
    final normalBefore = manager.normal.state;
    final authorization = await DevelopmentPrivateUnlockService().unlock();
    final private = manager.openPrivate(
      manifest,
      const OwnerPolicy(),
      authorization!,
    );
    private.dispatch(
      const CueReceived(
        CharacterCue(emotion: Emotion.shy, intensity: Intensity.medium),
      ),
    );
    expect(private.state.stageContext, StageContext.private);
    expect(private.state.activity, CoreState.shy);
    expect(manager.normal.state.activity, normalBefore.activity);
    expect(manager.normal.state.stageContext, isNot(StageContext.private));
    manager.lockPrivate();
    expect(manager.privateSession, isNull);
  });

  test('normal engine rejects a backend-requested private context', () {
    final current = session();
    current.dispatch(
      const CueReceived(
        CharacterCue(
          emotion: Emotion.happy,
          intensity: Intensity.low,
          stageContext: StageContext.private,
        ),
      ),
    );
    expect(current.state.stageContext, StageContext.daily);
  });

  test('seeded RNG produces repeatable resolution sequence', () {
    List<String?> run() {
      final current = session();
      return List.generate(8, (_) {
        current.dispatch(const AppStarted());
        return current.state.lastResolution?.assetId;
      });
    }

    expect(run(), run());
  });

  test('semantic cue parser ignores asset/path injection fields', () {
    final cue = CharacterCue.fromJson({
      'emotion': 'happy',
      'intensity': 'high',
      'asset_id': 'chr_001',
      'path': r'C:\secret.mp4',
      'filename': 'source.mp4',
    });
    expect(cue.emotion, Emotion.happy);
    expect(cue.intensity, Intensity.high);
    expect(cue.specialCue, isNull);
  });

  test('random event sequences preserve normal/private isolation', () {
    final current = session();
    final events = <EngineEvent>[
      const AppStarted(),
      const UserActivity(),
      const PttPressed(),
      const PttReleased(valid: true),
      const PttCancelled(),
      const TurnSubmitted('fuzz'),
      const TtsStarted('fuzz'),
      const TtsFinished('fuzz'),
      const TtsFailed('fuzz'),
      const JobStarted('job'),
      const JobFinished('job'),
      const AppPaused(),
      const AppResumed(),
      const ClipEnded('chr_001', playId: -1),
    ];
    final random = SeededRandomSource(88);
    for (var index = 0; index < 500; index++) {
      final selected = (random.nextDouble() * events.length).floor();
      current.dispatch(events[selected]);
      expect(current.state.stageContext, isNot(StageContext.private));
    }
  });
}
