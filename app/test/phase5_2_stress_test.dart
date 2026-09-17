import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hana_app/character/engine/character_cue.dart';
import 'package:hana_app/character/engine/character_engine.dart';
import 'package:hana_app/character/engine/clock.dart';
import 'package:hana_app/character/engine/engine_event.dart';
import 'package:hana_app/character/engine/engine_state.dart';
import 'package:hana_app/character/engine/session_manager.dart';
import 'package:hana_app/character/manifest/manifest_models.dart';
import 'package:hana_app/character/policy/owner_policy.dart';
import 'package:hana_app/private_mode/private_session.dart';

import 'support/canonical_manifest.dart';

void main() {
  test(
    '10,000 adversarial turn/timer/lifecycle events preserve invariants',
    () {
      final random = Random(5202026);
      final clock = FakeClock(DateTime.utc(2026));
      final session = EngineSession(
        engine: CharacterEngine(clock: clock),
        state: CharacterEngineState(
          manifest: canonicalManifest(),
          ownerPolicy: const OwnerPolicy(),
          privateSessionActive: false,
          readyAssetIds: canonicalManifest().byId.keys.toSet(),
          readyPosterIds: canonicalManifest().byId.keys.toSet(),
        ),
      );
      session.dispatch(const AppStarted());
      var nextTurn = 0;

      for (var step = 0; step < 10000; step++) {
        clock.advance(Duration(milliseconds: random.nextInt(25)));
        final active = session.state.currentTurnId;
        final action = random.nextInt(16);
        if (action == 0) {
          session.dispatch(const AppPaused());
        } else if (action == 1) {
          session.dispatch(const AppResumed());
        } else if (action == 2 && active == null) {
          session.dispatch(TurnSubmitted('turn-${nextTurn++}'));
        } else if (action == 3 && active != null) {
          session.dispatch(
            ReplyReady(
              turnId: active,
              cue: CharacterCue(
                emotion: Emotion.values[random.nextInt(Emotion.values.length)],
                intensity:
                    Intensity.values[random.nextInt(Intensity.values.length)],
              ),
              willSpeak: random.nextBool(),
            ),
          );
        } else if (action == 4 && active != null) {
          session.dispatch(TtsStarted(active));
        } else if (action == 5 && active != null) {
          session.dispatch(TtsFinished(active));
        } else if (action == 6 && active != null) {
          session.dispatch(TtsFailed(active));
        } else if (action == 7 && active != null) {
          session.dispatch(TurnFailed(active));
        } else if (action == 8 && active != null) {
          session.dispatch(TurnCancelled(active));
        } else if (action == 9) {
          session.dispatch(JobStarted('job-${random.nextInt(8)}'));
        } else if (action == 10) {
          session.dispatch(JobFinished('job-${random.nextInt(8)}'));
        } else if (action == 11) {
          session.dispatch(const PttPressed());
        } else if (action == 12) {
          session.dispatch(const PttCancelled());
        } else if (action == 13) {
          final before = session.state;
          session.dispatch(TtsFinished('stale-${random.nextInt(100)}'));
          expect(
            session.state,
            same(before),
            reason: 'wrong turn at step $step',
          );
        } else if (action == 14 && active != null) {
          final tag = _turnTags[random.nextInt(_turnTags.length)];
          final currentGeneration = session.state.timerTokens[tag] ?? 1;
          final before = session.state;
          session.dispatch(Tick(tag, currentGeneration - 1, turnId: active));
          expect(
            session.state,
            same(before),
            reason: 'stale token at step $step',
          );
        } else if (action == 15) {
          final before = session.state;
          final tag = _turnTags[random.nextInt(_turnTags.length)];
          session.dispatch(
            Tick(
              tag,
              session.state.timerTokens[tag] ?? 0,
              turnId: 'foreign-${random.nextInt(100)}',
            ),
          );
          expect(
            session.state,
            same(before),
            reason: 'foreign timer at step $step',
          );
        }

        expect(session.state.disposed, isFalse);
        if (session.state.currentTurnId == null) {
          expect(session.state.activity, isNot(CoreState.talking));
        }
      }

      // Every reachable live activity has a deterministic terminal escape.
      session.dispatch(const AppResumed());
      final active = session.state.currentTurnId;
      if (active != null) {
        session.dispatch(TtsFailed(active));
        session.dispatch(TurnCancelled(active));
      }
      if (session.state.activity == CoreState.listening) {
        session.dispatch(const PttCancelled());
      }
      expect(session.state.currentTurnId, isNull);
      expect(session.state.activity, isNot(CoreState.talking));
      expect(session.state.activity, isNot(CoreState.thinking));
    },
  );

  test(
    '300 private sessions tolerate early/late jitter and activity resets',
    () {
      final random = Random(152026);
      for (var iteration = 0; iteration < 300; iteration++) {
        final clock = FakeClock(DateTime.utc(2026));
        final policy = PrivateAutoLockPolicy(clock: clock)..onPrivateUnlocked();
        final resetCount = random.nextInt(8);
        for (var reset = 0; reset < resetCount; reset++) {
          clock.advance(Duration(seconds: 1 + random.nextInt(14 * 60)));
          policy.onUserActivity();
        }
        final deadline = policy.inactivityDeadline!;
        final jitterMs = random.nextInt(10001) - 5000;
        final wakeAt = deadline.add(Duration(milliseconds: jitterMs));
        clock.advance(wakeAt.difference(clock.now()));
        final first = policy.inactivityReason();
        if (jitterMs < 0) {
          expect(first, isNull, reason: 'early iteration $iteration');
          clock.advance(deadline.difference(clock.now()));
        }
        expect(
          policy.inactivityReason(),
          PrivateLockReason.inactivity,
          reason: 'deadline iteration $iteration',
        );
        policy.onPrivateLocked();
        expect(policy.inactivityDeadline, isNull);
      }
    },
  );
}

const _turnTags = <String>[
  'tts_wait_timeout',
  'tts_playback_max',
  'pre_speech_max',
  'thinking_min_dwell',
  'thinking_variant_rotate',
  'overlay_max',
  'overlay_min',
];
