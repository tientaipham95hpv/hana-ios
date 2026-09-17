import 'package:flutter_test/flutter_test.dart';
import 'package:hana_app/app/character_runtime_controller.dart';
import 'package:hana_app/character/engine/character_cue.dart';
import 'package:hana_app/character/engine/clock.dart';
import 'package:hana_app/character/engine/effect_executor.dart';
import 'package:hana_app/character/engine/engine_event.dart';
import 'package:hana_app/character/engine/timer_driver.dart';
import 'package:hana_app/character/manifest/manifest_models.dart';
import 'package:hana_app/character/policy/owner_policy.dart';
import 'package:hana_app/character/stage/asset_repository.dart';
import 'package:hana_app/private_mode/private_session.dart';

import 'support/canonical_manifest.dart';

void main() {
  test(
    'private effects/timers execute; normal remains paused until lock',
    () async {
      final clock = FakeClock(DateTime.utc(2026));
      final normalTimers = FakeTimerDriver(clock);
      final privateTimers = FakeTimerDriver(clock);
      var normalGates = 0;
      var privateGates = 0;
      final runtime = CharacterRuntimeController(
        manifest: canonicalManifest(),
        ownerPolicy: const OwnerPolicy(),
        repository: const MockVaultAssetRepository(),
        clock: clock,
        timerDriver: normalTimers,
        privateTimerDriver: privateTimers,
        ports: EngineRuntimePorts(onReleaseTtsGate: () => normalGates++),
        privatePorts: EngineRuntimePorts(
          onReleaseTtsGate: () => privateGates++,
        ),
      );
      addTearDown(runtime.dispose);
      final auth = await DevelopmentPrivateUnlockService(clock: clock).unlock();
      final private = runtime.openPrivate(
        canonicalManifest(),
        const OwnerPolicy(),
        auth!,
      );
      expect(runtime.state.paused, isTrue);
      runtime.dispatch(const AppResumed());
      runtime.dispatch(const PttPressed());
      runtime.dispatch(const TurnSubmitted('normal-while-private'));
      expect(runtime.state.paused, isTrue);
      expect(runtime.state.activity, CoreState.idle);
      expect(runtime.state.currentTurnId, isNull);

      runtime.dispatchPrivate(
        const CueReceived(
          CharacterCue(emotion: Emotion.shy, intensity: Intensity.medium),
        ),
      );
      expect(private.state.activity, CoreState.shy);
      expect(privateTimers.tags, contains('overlay_max'));
      privateTimers.elapse(const Duration(seconds: 4));
      expect(private.state.activity, CoreState.idle);

      runtime.dispatchPrivate(const TurnSubmitted('private-A'));
      privateTimers.elapse(const Duration(milliseconds: 600));
      runtime.dispatchPrivate(
        const ReplyReady(
          turnId: 'private-A',
          cue: CharacterCue(emotion: Emotion.neutral, intensity: Intensity.low),
          willSpeak: true,
        ),
      );
      expect(privateGates, 1);
      expect(normalGates, 0);
      runtime.dispatchPrivate(const TtsStarted('private-A'));
      runtime.dispatchPrivate(const TtsFinished('private-A'));
      expect(private.state.currentTurnId, isNull);

      runtime.lockPrivate();
      expect(private.isDisposed, isTrue);
      expect(privateTimers.tags, isEmpty);
      expect(runtime.privateSession, isNull);
      expect(runtime.state.paused, isFalse);
      expect(runtime.state.activity, CoreState.idle);
      expect(runtime.state.stageContext, StageContext.daily);
      runtime.dispatchPrivate(const TurnSubmitted('late-private'));
      expect(private.state.currentTurnId, isNull);
      runtime.dispatch(const PttPressed());
      expect(runtime.state.activity, CoreState.listening);
    },
  );

  test('invalid private authorization does not pause normal engine', () async {
    final clock = FakeClock(DateTime.utc(2026));
    final runtime = CharacterRuntimeController(
      manifest: canonicalManifest(),
      ownerPolicy: const OwnerPolicy(),
      repository: const MockVaultAssetRepository(),
      clock: clock,
      timerDriver: FakeTimerDriver(clock),
    );
    addTearDown(runtime.dispose);
    final auth = await DevelopmentPrivateUnlockService(clock: clock).unlock();
    clock.advance(const Duration(hours: 1));
    expect(
      () =>
          runtime.openPrivate(canonicalManifest(), const OwnerPolicy(), auth!),
      throwsStateError,
    );
    expect(runtime.privateSession, isNull);
    expect(runtime.state.paused, isFalse);
  });
}
