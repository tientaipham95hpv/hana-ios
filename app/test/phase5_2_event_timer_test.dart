import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hana_app/app/character_runtime_controller.dart';
import 'package:hana_app/app/providers.dart';
import 'package:hana_app/character/engine/character_cue.dart';
import 'package:hana_app/character/engine/character_engine.dart';
import 'package:hana_app/character/engine/clock.dart';
import 'package:hana_app/character/engine/effect_executor.dart';
import 'package:hana_app/character/engine/engine_effect.dart';
import 'package:hana_app/character/engine/engine_event.dart';
import 'package:hana_app/character/engine/timer_driver.dart';
import 'package:hana_app/character/manifest/manifest_loader.dart';
import 'package:hana_app/character/manifest/manifest_models.dart';
import 'package:hana_app/character/policy/owner_policy.dart';
import 'package:hana_app/character/stage/asset_repository.dart';
import 'package:hana_app/private_mode/private_mode_screen.dart';

import 'support/canonical_manifest.dart';

const _replyA = ReplyReady(
  turnId: 'A',
  cue: CharacterCue(emotion: Emotion.neutral, intensity: Intensity.low),
  willSpeak: true,
);
const _replyB = ReplyReady(
  turnId: 'B',
  cue: CharacterCue(emotion: Emotion.neutral, intensity: Intensity.low),
  willSpeak: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final close in ['cancelled', 'tts failed', 'turn failed']) {
    test('old TTS timeout cannot cancel next turn after $close', () {
      final clock = FakeClock(DateTime.utc(2026));
      final timers = FakeTimerDriver(clock);
      var gates = 0;
      final runtime = CharacterRuntimeController(
        manifest: canonicalManifest(),
        ownerPolicy: const OwnerPolicy(),
        repository: const MockVaultAssetRepository(),
        clock: clock,
        timerDriver: timers,
        ports: EngineRuntimePorts(onReleaseTtsGate: () => gates++),
      );
      addTearDown(runtime.dispose);
      runtime.dispatch(const TurnSubmitted('A'));
      timers.elapse(const Duration(milliseconds: 600));
      runtime.dispatch(_replyA);
      final oldToken = runtime.state.timerTokens['tts_wait_timeout']!;
      if (close == 'cancelled') {
        runtime.dispatch(const TurnCancelled('A'));
      } else if (close == 'tts failed') {
        runtime.dispatch(const TtsFailed('A'));
      } else {
        runtime.dispatch(const TurnFailed('A'));
        timers.elapse(const Duration(seconds: 4));
      }
      expect(timers.tags, isNot(contains('tts_wait_timeout')));
      expect(timers.tags, isNot(contains('pre_speech_max')));
      expect(timers.tags, isNot(contains('thinking_min_dwell')));
      expect(timers.tags, isNot(contains('thinking_variant_rotate')));
      runtime.dispatch(const TurnSubmitted('B'));
      runtime.dispatch(Tick('tts_wait_timeout', oldToken, turnId: 'A'));
      expect(runtime.state.currentTurnId, 'B');
      timers.elapse(
        close == 'turn failed'
            ? const Duration(seconds: 4)
            : const Duration(seconds: 8),
      );
      expect(runtime.state.currentTurnId, 'B');
      runtime.dispatch(_replyB);
      timers.elapse(const Duration(milliseconds: 500));
      expect(gates, 2);
      runtime.dispatch(const TtsStarted('B'));
      expect(runtime.state.activity, CoreState.talking);
      runtime.dispatch(const TtsFinished('B'));
      expect(runtime.state.currentTurnId, isNull);
    });
  }

  test(
    'turn timers carry owner and generation; foreign timeout is ignored',
    () {
      final clock = FakeClock(DateTime.utc(2026));
      final timers = FakeTimerDriver(clock);
      final runtime = CharacterRuntimeController(
        manifest: canonicalManifest(),
        ownerPolicy: const OwnerPolicy(),
        repository: const MockVaultAssetRepository(),
        clock: clock,
        timerDriver: timers,
      );
      addTearDown(runtime.dispose);
      runtime.dispatch(const TurnSubmitted('A'));
      timers.elapse(const Duration(milliseconds: 600));
      runtime.dispatch(_replyA);
      runtime.dispatch(const TurnCancelled('A'));
      runtime.dispatch(const TurnSubmitted('B'));
      timers.elapse(const Duration(milliseconds: 600));
      runtime.dispatch(_replyB);
      final bToken = runtime.state.timerTokens['tts_wait_timeout']!;
      final before = runtime.state;
      runtime.dispatch(Tick('tts_wait_timeout', bToken, turnId: 'A'));
      expect(runtime.state, same(before));
      expect(runtime.state.currentTurnId, 'B');
    },
  );

  test('stale pre-speech tick cannot release gate for another turn', () {
    final clock = FakeClock(DateTime.utc(2026));
    final timers = FakeTimerDriver(clock);
    var gates = 0;
    final runtime = CharacterRuntimeController(
      manifest: canonicalManifest(),
      ownerPolicy: const OwnerPolicy(),
      repository: const MockVaultAssetRepository(),
      clock: clock,
      timerDriver: timers,
      ports: EngineRuntimePorts(onReleaseTtsGate: () => gates++),
    );
    addTearDown(runtime.dispose);
    runtime.dispatch(const TurnSubmitted('A'));
    timers.elapse(const Duration(milliseconds: 600));
    runtime.dispatch(
      const ReplyReady(
        turnId: 'A',
        cue: CharacterCue(emotion: Emotion.surprised, intensity: Intensity.low),
        willSpeak: true,
      ),
    );
    final aToken = runtime.state.timerTokens['pre_speech_max']!;
    runtime.dispatch(const TurnCancelled('A'));
    runtime.dispatch(const TurnSubmitted('B'));
    timers.elapse(const Duration(milliseconds: 600));
    const replyB = ReplyReady(
      turnId: 'B',
      cue: CharacterCue(emotion: Emotion.surprised, intensity: Intensity.low),
      willSpeak: true,
    );
    final preview = CharacterEngine(clock: clock).reduce(runtime.state, replyB);
    final schedule = preview.effects.whereType<ScheduleTick>().singleWhere(
      (effect) => effect.tag == 'pre_speech_max',
    );
    runtime.dispatch(replyB);
    expect(schedule.turnId, 'B');
    expect(schedule.token, isNot(aToken));
    runtime.dispatch(Tick('pre_speech_max', aToken, turnId: 'A'));
    runtime.dispatch(Tick('pre_speech_max', schedule.token, turnId: 'A'));
    expect(gates, 0);
    expect(runtime.state.currentTurnId, 'B');
    runtime.dispatch(Tick('pre_speech_max', schedule.token, turnId: 'B'));
    expect(gates, 1);
  });

  test('rapid A/B/C sequence ignores both earlier turn callbacks', () {
    final clock = FakeClock(DateTime.utc(2026));
    final timers = FakeTimerDriver(clock);
    final runtime = CharacterRuntimeController(
      manifest: canonicalManifest(),
      ownerPolicy: const OwnerPolicy(),
      repository: const MockVaultAssetRepository(),
      clock: clock,
      timerDriver: timers,
    );
    addTearDown(runtime.dispose);
    final stale = <Tick>[];
    for (final id in ['A', 'B']) {
      runtime.dispatch(TurnSubmitted(id));
      timers.elapse(const Duration(milliseconds: 600));
      runtime.dispatch(
        ReplyReady(
          turnId: id,
          cue: const CharacterCue(
            emotion: Emotion.neutral,
            intensity: Intensity.low,
          ),
          willSpeak: true,
        ),
      );
      stale.add(
        Tick(
          'tts_wait_timeout',
          runtime.state.timerTokens['tts_wait_timeout']!,
          turnId: id,
        ),
      );
      runtime.dispatch(TurnCancelled(id));
    }
    runtime.dispatch(const TurnSubmitted('C'));
    timers.elapse(const Duration(milliseconds: 600));
    runtime.dispatch(
      const ReplyReady(
        turnId: 'C',
        cue: CharacterCue(emotion: Emotion.neutral, intensity: Intensity.low),
        willSpeak: true,
      ),
    );
    for (final tick in stale) {
      runtime.dispatch(tick);
    }
    runtime.dispatch(
      Tick(
        'tts_wait_timeout',
        runtime.state.timerTokens['tts_wait_timeout']!,
        turnId: 'A',
      ),
    );
    expect(runtime.state.currentTurnId, 'C');
    expect(runtime.state.activity, CoreState.thinking);
  });

  test('reused turn ID still rejects an earlier generation', () {
    final clock = FakeClock(DateTime.utc(2026));
    final timers = FakeTimerDriver(clock);
    final runtime = CharacterRuntimeController(
      manifest: canonicalManifest(),
      ownerPolicy: const OwnerPolicy(),
      repository: const MockVaultAssetRepository(),
      clock: clock,
      timerDriver: timers,
    );
    addTearDown(runtime.dispose);
    runtime.dispatch(const TurnSubmitted('A'));
    timers.elapse(const Duration(milliseconds: 600));
    runtime.dispatch(_replyA);
    final oldGeneration = runtime.state.timerTokens['tts_wait_timeout']!;
    runtime.dispatch(const TurnCancelled('A'));
    runtime.dispatch(const TurnSubmitted('A'));
    timers.elapse(const Duration(milliseconds: 600));
    runtime.dispatch(_replyA);
    runtime.dispatch(Tick('tts_wait_timeout', oldGeneration, turnId: 'A'));
    expect(runtime.state.currentTurnId, 'A');
    expect(runtime.state.timerTokens['tts_wait_timeout'], isNot(oldGeneration));
  });

  for (final finishBeforePause in [false, true]) {
    test(
      'background TTS completion is kept (started before pause: $finishBeforePause)',
      () {
        final clock = FakeClock(DateTime.utc(2026));
        final timers = FakeTimerDriver(clock);
        var gates = 0;
        final runtime = CharacterRuntimeController(
          manifest: canonicalManifest(),
          ownerPolicy: const OwnerPolicy(),
          repository: const MockVaultAssetRepository(),
          clock: clock,
          timerDriver: timers,
          ports: EngineRuntimePorts(onReleaseTtsGate: () => gates++),
        );
        addTearDown(runtime.dispose);
        runtime.dispatch(const TurnSubmitted('A'));
        timers.elapse(const Duration(milliseconds: 600));
        runtime.dispatch(_replyA);
        if (finishBeforePause) runtime.dispatch(const TtsStarted('A'));
        runtime.dispatch(const AppPaused());
        if (!finishBeforePause) runtime.dispatch(const TtsStarted('A'));
        runtime.dispatch(const TtsFinished('A'));
        expect(runtime.state.currentTurnId, isNull);
        runtime.dispatch(const AppResumed());
        runtime.dispatch(const TurnSubmitted('B'));
        timers.elapse(const Duration(milliseconds: 600));
        runtime.dispatch(_replyB);
        expect(runtime.state.currentTurnId, 'B');
        expect(gates, 2);
        runtime.dispatch(const TtsStarted('B'));
        runtime.dispatch(const TtsFinished('B'));
        expect(runtime.state.activity, CoreState.idle);
      },
    );
  }

  test('background TtsFinished retains post-speech reaction on resume', () {
    final clock = FakeClock(DateTime.utc(2026));
    final timers = FakeTimerDriver(clock);
    final runtime = CharacterRuntimeController(
      manifest: canonicalManifest(),
      ownerPolicy: const OwnerPolicy(),
      repository: const MockVaultAssetRepository(),
      clock: clock,
      timerDriver: timers,
    );
    addTearDown(runtime.dispose);
    runtime.dispatch(const TurnSubmitted('A'));
    timers.elapse(const Duration(milliseconds: 600));
    runtime.dispatch(
      const ReplyReady(
        turnId: 'A',
        cue: CharacterCue(emotion: Emotion.happy, intensity: Intensity.low),
        willSpeak: true,
      ),
    );
    runtime.dispatch(const TtsStarted('A'));
    runtime.dispatch(const AppPaused());
    runtime.dispatch(const TtsFinished('A'));
    expect(runtime.state.currentTurnId, isNull);
    expect(runtime.state.activity, CoreState.happy);
    final beforeResume = runtime.state.playbackGeneration;
    runtime.dispatch(const AppResumed());
    expect(runtime.state.activity, CoreState.happy);
    expect(runtime.state.playbackGeneration, greaterThan(beforeResume));
    timers.elapse(const Duration(seconds: 4));
    expect(runtime.state.activity, CoreState.idle);
  });

  test(
    'thinking -> pause -> TurnFailed -> resume renders terminal reaction',
    () {
      final clock = FakeClock(DateTime.utc(2026));
      final timers = FakeTimerDriver(clock);
      final runtime = CharacterRuntimeController(
        manifest: canonicalManifest(),
        ownerPolicy: const OwnerPolicy(),
        repository: const MockVaultAssetRepository(),
        clock: clock,
        timerDriver: timers,
      );
      addTearDown(runtime.dispose);
      runtime.dispatch(const TurnSubmitted('A'));
      runtime.dispatch(const AppPaused());
      runtime.dispatch(const TurnFailed('A'));
      expect(runtime.state.currentTurnId, isNull);
      expect(runtime.state.activity, CoreState.concerned);
      final beforeResume = runtime.state.playbackGeneration;
      runtime.dispatch(const AppResumed());
      expect(runtime.state.activity, CoreState.concerned);
      expect(runtime.state.playbackGeneration, greaterThan(beforeResume));
      timers.elapse(const Duration(seconds: 4));
      expect(runtime.state.activity, CoreState.idle);
    },
  );

  test('talking -> pause for two hours -> resume cannot stay talking', () {
    final clock = FakeClock(DateTime.utc(2026));
    final timers = FakeTimerDriver(clock);
    final runtime = CharacterRuntimeController(
      manifest: canonicalManifest(),
      ownerPolicy: const OwnerPolicy(),
      repository: const MockVaultAssetRepository(),
      clock: clock,
      timerDriver: timers,
    );
    addTearDown(runtime.dispose);
    runtime.dispatch(const TurnSubmitted('A'));
    timers.elapse(const Duration(milliseconds: 600));
    runtime.dispatch(_replyA);
    runtime.dispatch(const TtsStarted('A'));
    runtime.dispatch(const AppPaused());
    timers.elapse(const Duration(hours: 2));
    runtime.dispatch(const AppResumed());
    expect(runtime.state.currentTurnId, isNull);
    expect(runtime.state.activity, CoreState.idle);
    runtime.dispatch(const TurnSubmitted('B'));
    expect(runtime.state.currentTurnId, 'B');
  });

  test('pause -> TurnCancelled -> resume does not revive the old turn', () {
    final clock = FakeClock(DateTime.utc(2026));
    final timers = FakeTimerDriver(clock);
    final runtime = CharacterRuntimeController(
      manifest: canonicalManifest(),
      ownerPolicy: const OwnerPolicy(),
      repository: const MockVaultAssetRepository(),
      clock: clock,
      timerDriver: timers,
    );
    addTearDown(runtime.dispose);
    runtime.dispatch(const TurnSubmitted('A'));
    runtime.dispatch(const AppPaused());
    runtime.dispatch(const TurnCancelled('A'));
    runtime.dispatch(const AppResumed());
    runtime.dispatch(_replyA);
    expect(runtime.state.currentTurnId, isNull);
    expect(runtime.state.activity, CoreState.idle);
    runtime.dispatch(const TurnSubmitted('B'));
    expect(runtime.state.currentTurnId, 'B');
  });

  test('multiple stale background events cannot reopen a completed turn', () {
    final clock = FakeClock(DateTime.utc(2026));
    final timers = FakeTimerDriver(clock);
    final runtime = CharacterRuntimeController(
      manifest: canonicalManifest(),
      ownerPolicy: const OwnerPolicy(),
      repository: const MockVaultAssetRepository(),
      clock: clock,
      timerDriver: timers,
    );
    addTearDown(runtime.dispose);
    runtime.dispatch(const TurnSubmitted('A'));
    timers.elapse(const Duration(milliseconds: 600));
    runtime.dispatch(_replyA);
    final oldToken = runtime.state.timerTokens['tts_wait_timeout']!;
    runtime.dispatch(const TtsStarted('A'));
    runtime.dispatch(const AppPaused());
    runtime.dispatch(const TtsFinished('A'));
    for (final stale in <EngineEvent>[
      const TtsFinished('A'),
      const TtsStarted('A'),
      const TtsFailed('A'),
      const TurnFailed('A'),
      const TurnCancelled('A'),
      Tick('tts_wait_timeout', oldToken, turnId: 'A'),
    ]) {
      runtime.dispatch(stale);
      expect(runtime.state.currentTurnId, isNull);
      expect(runtime.state.activity, CoreState.idle);
    }
    runtime.dispatch(const AppResumed());
    runtime.dispatch(const TurnSubmitted('B'));
    expect(runtime.state.currentTurnId, 'B');
  });

  test('missing TTS completion is recovered by playback watchdog', () {
    final clock = FakeClock(DateTime.utc(2026));
    final timers = FakeTimerDriver(clock);
    final runtime = CharacterRuntimeController(
      manifest: canonicalManifest(),
      ownerPolicy: const OwnerPolicy(),
      repository: const MockVaultAssetRepository(),
      clock: clock,
      timerDriver: timers,
    );
    addTearDown(runtime.dispose);
    runtime.dispatch(const TurnSubmitted('A'));
    timers.elapse(const Duration(milliseconds: 600));
    runtime.dispatch(_replyA);
    runtime.dispatch(const TtsStarted('A'));
    runtime.dispatch(const AppPaused());
    timers.elapse(const Duration(minutes: 10));
    expect(runtime.state.currentTurnId, isNull);
    runtime.dispatch(const AppResumed());
    runtime.dispatch(const TurnSubmitted('B'));
    expect(runtime.state.currentTurnId, 'B');
  });

  test('TTS start timeout still expires during background pause', () {
    final clock = FakeClock(DateTime.utc(2026));
    final timers = FakeTimerDriver(clock);
    final runtime = CharacterRuntimeController(
      manifest: canonicalManifest(),
      ownerPolicy: const OwnerPolicy(),
      repository: const MockVaultAssetRepository(),
      clock: clock,
      timerDriver: timers,
    );
    addTearDown(runtime.dispose);
    runtime.dispatch(const TurnSubmitted('A'));
    timers.elapse(const Duration(milliseconds: 600));
    runtime.dispatch(_replyA);
    runtime.dispatch(const AppPaused());
    expect(timers.tags, contains('tts_wait_timeout'));
    timers.elapse(const Duration(seconds: 8));
    expect(runtime.state.currentTurnId, isNull);
    runtime.dispatch(const AppResumed());
    runtime.dispatch(const TurnSubmitted('B'));
    expect(runtime.state.currentTurnId, 'B');
  });

  testWidgets('private lock retries an early timer and locks at 15 minutes', (
    tester,
  ) async {
    final clock = FakeClock(DateTime.now());
    final timer = _EarlyTimerDriver(clock);
    await _pumpPrivate(tester, clock, timer);
    expect(find.byKey(const Key('lock-private')), findsOneWidget);
    clock.advance(const Duration(minutes: 14, seconds: 59, milliseconds: 999));
    timer.fireEarly('private_inactivity');
    await tester.pump();
    expect(find.byKey(const Key('lock-private')), findsOneWidget);
    expect(timer.tags, contains('private_inactivity'));
    timer.elapse(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lock-private')), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets(
    'private inactivity timer reschedules after a five-second early wake',
    (tester) async {
      final clock = FakeClock(DateTime.now());
      final timer = _EarlyTimerDriver(clock);
      await _pumpPrivate(tester, clock, timer);
      final deadline = timer.deadlines['private_inactivity']!;
      clock.advance(const Duration(minutes: 14, seconds: 55));
      timer.fireEarly('private_inactivity');
      await tester.pump();
      expect(find.byKey(const Key('lock-private')), findsOneWidget);
      expect(timer.deadlines['private_inactivity'], deadline);
      timer.elapse(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lock-private')), findsNothing);
    },
  );

  testWidgets('300 seeded early timer wakes still lock at the deadline', (
    tester,
  ) async {
    final clock = FakeClock(DateTime.now());
    final timer = _EarlyTimerDriver(clock);
    await _pumpPrivate(tester, clock, timer);
    final deadline = timer.deadlines['private_inactivity']!;
    final random = Random(20260916);
    clock.advance(const Duration(minutes: 14));
    for (var i = 0; i < 300; i++) {
      clock.advance(Duration(microseconds: 1 + random.nextInt(2000)));
      timer.fireEarly('private_inactivity');
      expect(
        timer.deadlines['private_inactivity'],
        deadline,
        reason: 'wake $i',
      );
    }
    expect(find.byKey(const Key('lock-private')), findsOneWidget);
    timer.elapse(deadline.difference(clock.now()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lock-private')), findsNothing);
  });

  testWidgets('activity at 14:59 cancels old timer and resets deadline', (
    tester,
  ) async {
    final clock = FakeClock(DateTime.now());
    final timer = _EarlyTimerDriver(clock);
    await _pumpPrivate(tester, clock, timer);
    final firstDeadline = timer.deadlines['private_inactivity']!;
    clock.advance(const Duration(minutes: 14, seconds: 59));
    final cancelsBefore = timer.inactivityCancels;
    await tester.tap(find.text('Demo private reaction'));
    await tester.pump();
    expect(timer.inactivityCancels, greaterThan(cancelsBefore));
    expect(
      timer.deadlines['private_inactivity'],
      clock.now().add(const Duration(minutes: 15)),
    );
    timer.elapse(firstDeadline.difference(clock.now()));
    await tester.pump();
    expect(find.byKey(const Key('lock-private')), findsOneWidget);
    timer.elapse(const Duration(minutes: 14, seconds: 59));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lock-private')), findsNothing);
  });

  testWidgets('one hour without private activity is certainly locked', (
    tester,
  ) async {
    final clock = FakeClock(DateTime.now());
    final timer = _EarlyTimerDriver(clock);
    await _pumpPrivate(tester, clock, timer);
    timer.elapse(const Duration(hours: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lock-private')), findsNothing);
    expect(timer.tags, isEmpty);
  });

  testWidgets('private lifecycle locks at 60 seconds, not 59', (tester) async {
    final clock = FakeClock(DateTime.now());
    final timer = _EarlyTimerDriver(clock);
    await _pumpPrivate(tester, clock, timer);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    clock.advance(const Duration(seconds: 59));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byKey(const Key('lock-private')), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    clock.advance(const Duration(seconds: 60));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lock-private')), findsNothing);
  });
}

Future<void> _pumpPrivate(
  WidgetTester tester,
  FakeClock clock,
  TimerDriver timer,
) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('hana/secure_window'),
        (_) async => null,
      );
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('hana/secure_window'),
          null,
        ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        manifestLoadResultProvider.overrideWithValue(
          ManifestLoadResult.valid(canonicalManifest()),
        ),
      ],
      child: MaterialApp(
        routes: {
          '/': (_) => Scaffold(
            appBar: AppBar(title: const Text('Home')),
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.pushNamed(context, '/private'),
                child: const Text('Open'),
              ),
            ),
          ),
          '/private': (_) =>
              PrivateModeScreen(clock: clock, timerDriver: timer),
        },
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

class _EarlyTimerDriver extends FakeTimerDriver {
  _EarlyTimerDriver(super.clock);
  final Map<String, void Function()> _callbacks = {};
  final Map<String, DateTime> deadlines = {};
  var inactivityCancels = 0;

  @override
  void schedule(String tag, DateTime at, void Function() callback) {
    _callbacks[tag] = callback;
    deadlines[tag] = at;
    super.schedule(tag, at, callback);
  }

  void fireEarly(String tag) {
    final callback = _callbacks[tag]!;
    cancel(tag);
    callback();
  }

  @override
  void cancel(String tag) {
    _callbacks.remove(tag);
    deadlines.remove(tag);
    if (tag == 'private_inactivity') inactivityCancels++;
    super.cancel(tag);
  }

  @override
  void cancelAll() {
    _callbacks.clear();
    deadlines.clear();
    super.cancelAll();
  }
}
