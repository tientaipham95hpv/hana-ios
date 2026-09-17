import '../manifest/manifest_models.dart';
import '../resolver/asset_resolver.dart';
import '../resolver/random_source.dart';
import 'character_cue.dart';
import 'clock.dart';
import 'engine_config.dart';
import 'engine_effect.dart';
import 'engine_event.dart';
import 'engine_state.dart';

/// Pure state reducer. I/O, timers and player operations are runtime work.
class CharacterEngine {
  CharacterEngine({required this.clock});

  final Clock clock;

  EngineResult reduce(CharacterEngineState state, EngineEvent event) {
    if (state.disposed) return EngineResult(state, const []);
    if (event is AppPaused) {
      if (state.paused) return EngineResult(state, const []);
      final pausedState = state.activity == CoreState.listening
          ? state.copyWith(
              paused: true,
              pausedAt: clock.now(),
              activity: CoreState.idle,
              clearTurnId: true,
              clearPendingCue: true,
            )
          : state.copyWith(paused: true, pausedAt: clock.now());
      return _cancelTimers(
        EngineResult(pausedState, [
          const PauseStage(),
          if (state.activity == CoreState.listening) const StopTts(),
          ..._cancelActivityTimers(),
          const CancelTick('context_hold'),
        ]),
        const ['thinking_variant_rotate'],
      );
    }
    if (event is AppResumed) {
      final longPause =
          state.pausedAt != null &&
          clock.now().difference(state.pausedAt!) >=
              const Duration(seconds: 60);
      final next = state.copyWith(
        paused: false,
        clearPausedAt: true,
        stageContext: longPause && !state.privateSessionActive
            ? StageContext.daily
            : state.stageContext,
        activity: state.activity == CoreState.sleep
            ? CoreState.idle
            : state.activity,
      );
      final shown = switch (next.activity) {
        CoreState.idle => _idle(next),
        CoreState.working => _working(next),
        CoreState.thinking => _schedule(
          _show(next, CoreState.thinking),
          'thinking_variant_rotate',
          EngineConfig.thinkingVariantRotate,
        ),
        CoreState.happy ||
        CoreState.shy ||
        CoreState.surprised ||
        CoreState.concerned => _overlay(next, next.activity),
        _ => _show(next, next.activity),
      };
      return EngineResult(shown.state, [const ResumeStage(), ...shown.effects]);
    }
    // Audio and turn completion continue in the background. Only foreground
    // input and visual callbacks are suspended with the stage.
    if (state.paused &&
        event is! TurnSubmitted &&
        event is! PttUploadFailed &&
        event is! ReplyReady &&
        event is! TtsStarted &&
        event is! TtsFinished &&
        event is! TtsFailed &&
        event is! TurnFailed &&
        event is! TurnCancelled &&
        event is! JobStarted &&
        event is! JobFinished &&
        !(event is Tick && _runsWhilePaused(event.tag))) {
      return EngineResult(state, const []);
    }
    if (event is AppStarted) {
      return _idle(state.copyWith(inQuietHours: event.inQuietHours));
    }
    if (event is PolicyUpdated || event is AssetsAvailabilityChanged) {
      return _show(state, state.activity);
    }
    if (event is UserActivity) {
      if (state.activity == CoreState.sleep ||
          state.activity == CoreState.idle) {
        return _idle(state);
      }
      return EngineResult(state, const []);
    }
    if (event is PttPressed) {
      final shown = _show(
        state.copyWith(clearPendingCue: true, clearTurnId: true),
        CoreState.listening,
      );
      return _cancelTurnTimers(
        EngineResult(shown.state, [
          const StopTts(),
          ..._cancelActivityTimers(),
          ...shown.effects,
        ]),
      );
    }
    if (event is PttReleased && state.activity == CoreState.listening) {
      return event.valid ? _thinking(state) : _idle(state);
    }
    if (event is PttCancelled && state.activity == CoreState.listening) {
      return _idle(state);
    }
    if (event is PttUploadFailed &&
        state.activity == CoreState.thinking &&
        state.currentTurnId == null) {
      final cleared = _cancelTurnTimers(EngineResult(state, const []));
      final overlay = _overlay(cleared.state, CoreState.concerned);
      return EngineResult(overlay.state, [
        ...cleared.effects,
        ...overlay.effects,
      ]);
    }
    if (event is TurnSubmitted &&
        (_canSubmitTurn(state.activity) ||
            state.activity == CoreState.talking ||
            (state.activity == CoreState.thinking &&
                state.currentTurnId == null))) {
      final cleared = _cancelTurnTimers(EngineResult(state, const []));
      final thinking = _thinking(
        cleared.state.copyWith(
          currentTurnId: event.turnId,
          clearPendingCue: true,
        ),
      );
      return EngineResult(thinking.state, [
        if (state.activity == CoreState.talking) const StopTts(),
        ...cleared.effects,
        ...thinking.effects,
      ]);
    }
    if (event is ReplyReady) return _replyReady(state, event);
    if (event is TtsStarted) {
      if (!_activeTurn(state, event.turnId) ||
          !_isThinkingOrReaction(state.activity) ||
          state.pendingCue == null ||
          state.deferredReply != null) {
        return EngineResult(state, const []);
      }
      final shown = _show(state, CoreState.talking);
      final cleared = _cancelTurnTimers(
        EngineResult(shown.state, [
          const CancelTick('overlay_max'),
          ...shown.effects,
        ]),
      );
      return _schedule(
        cleared,
        'tts_playback_max',
        EngineConfig.ttsPlaybackMax,
      );
    }
    if (event is TtsFinished) {
      if (!_activeTurn(state, event.turnId) ||
          state.activity != CoreState.talking) {
        return EngineResult(state, const []);
      }
      final cleared = _cancelTurnTimers(EngineResult(state, const []));
      final next = cleared.state.copyWith(clearTurnId: true);
      final reaction = _reactionState(
        state.pendingCue?.emotion ?? Emotion.neutral,
      );
      if (reaction != null) {
        final overlay = _overlay(
          next.copyWith(clearPendingCue: true),
          reaction,
        );
        return EngineResult(overlay.state, [
          ...cleared.effects,
          ...overlay.effects,
        ]);
      }
      final settled = state.jobActive
          ? _working(next.copyWith(clearPendingCue: true))
          : _idle(next.copyWith(clearPendingCue: true));
      return EngineResult(settled.state, [
        ...cleared.effects,
        ...settled.effects,
      ]);
    }
    if (event is TtsFailed) {
      if (!_activeTurn(state, event.turnId) ||
          (state.activity != CoreState.talking &&
              !_isThinkingOrReaction(state.activity))) {
        return EngineResult(state, const []);
      }
      final cleared = _cancelTurnTimers(EngineResult(state, const []));
      final next = cleared.state.copyWith(
        clearTurnId: true,
        clearPendingCue: true,
      );
      final settled = state.jobActive ? _working(next) : _idle(next);
      return EngineResult(settled.state, [
        ...cleared.effects,
        ...settled.effects,
      ]);
    }
    if (event is TtsStoppedByUser && state.activity == CoreState.talking) {
      final cleared = _cancelTurnTimers(EngineResult(state, const []));
      final next = cleared.state.copyWith(
        clearTurnId: true,
        clearPendingCue: true,
      );
      final settled = state.jobActive ? _working(next) : _idle(next);
      return EngineResult(settled.state, [
        const StopTts(),
        ...cleared.effects,
        ...settled.effects,
      ]);
    }
    if (event is TurnFailed) {
      if (!_activeTurn(state, event.turnId) ||
          state.activity != CoreState.thinking) {
        return EngineResult(state, const []);
      }
      final cleared = _cancelTurnTimers(EngineResult(state, const []));
      final overlay = _overlay(
        cleared.state.copyWith(clearTurnId: true, clearPendingCue: true),
        CoreState.concerned,
      );
      return EngineResult(overlay.state, [
        ...cleared.effects,
        ...overlay.effects,
      ]);
    }
    if (event is TurnCancelled) {
      if (!_activeTurn(state, event.turnId) ||
          (!_isThinkingOrReaction(state.activity) &&
              state.activity != CoreState.talking)) {
        return EngineResult(state, const []);
      }
      final cleared = _cancelTurnTimers(EngineResult(state, const []));
      final idle = _idle(
        cleared.state.copyWith(clearTurnId: true, clearPendingCue: true),
      );
      return EngineResult(idle.state, [...cleared.effects, ...idle.effects]);
    }
    if (event is JobStarted) {
      final jobs = Set<String>.of(state.activeJobIds)..add(event.jobId);
      final next = state.copyWith(activeJobIds: Set.unmodifiable(jobs));
      return state.activity == CoreState.idle
          ? _working(next)
          : EngineResult(next, const []);
    }
    if (event is JobFinished) {
      if (!state.activeJobIds.contains(event.jobId)) {
        return EngineResult(state, const []);
      }
      final jobs = Set<String>.of(state.activeJobIds)..remove(event.jobId);
      final next = state.copyWith(activeJobIds: Set.unmodifiable(jobs));
      if (state.activity != CoreState.working || jobs.isNotEmpty) {
        return EngineResult(next, const []);
      }
      return _idle(next);
    }
    if (event is CueReceived) {
      if (state.activity == CoreState.sleep) {
        final woke = _idle(state);
        return _cue(woke.state, event.cue);
      }
      if (state.activity != CoreState.idle) {
        return EngineResult(state, const []);
      }
      return _cue(state, event.cue);
    }
    if (event is ClipEnded) return _clipEnded(state, event);
    if (event is ClipError) return _clipError(state, event);
    if (event is Tick) return _tick(state, event);
    return EngineResult(state, const []);
  }

  EngineResult _replyReady(
    CharacterEngineState state,
    ReplyReady event, {
    bool dwellSatisfied = false,
  }) {
    if (!_activeTurn(state, event.turnId) ||
        state.activity != CoreState.thinking) {
      return EngineResult(state, const []);
    }
    final entered = state.thinkingEnteredAt;
    if (!dwellSatisfied && entered != null) {
      final elapsed = clock.now().difference(entered);
      if (elapsed < EngineConfig.thinkingMinDwell) {
        return _schedule(
          EngineResult(state.copyWith(deferredReply: event), const []),
          'thinking_min_dwell',
          EngineConfig.thinkingMinDwell - elapsed,
        );
      }
    }
    state = state.copyWith(clearDeferredReply: true);
    final next = state.copyWith(
      pendingCue: event.cue,
      stageContext: _cueContext(state, event.cue),
    );
    if (!event.willSpeak) {
      final cleared = _cancelTurnTimers(EngineResult(next, const []));
      final settled = cleared.state;
      final reaction = _reactionState(event.cue.emotion);
      final result = reaction == null
          ? _idle(settled.copyWith(clearTurnId: true, clearPendingCue: true))
          : _overlay(
              settled.copyWith(clearTurnId: true, clearPendingCue: true),
              reaction,
              intensity: event.cue.intensity,
            );
      return EngineResult(result.state, [
        ...cleared.effects,
        ...result.effects,
      ]);
    }
    if (event.cue.emotion == Emotion.surprised) {
      final overlay = _overlay(
        next,
        CoreState.surprised,
        intensity: event.cue.intensity,
      );
      return _schedule(
        _schedule(overlay, 'pre_speech_max', EngineConfig.preSpeechMax),
        'tts_wait_timeout',
        EngineConfig.ttsWaitTimeout,
      );
    }
    final waiting = EngineResult(next, const [ReleaseTtsGate()]);
    return _schedule(waiting, 'tts_wait_timeout', EngineConfig.ttsWaitTimeout);
  }

  EngineResult _cue(CharacterEngineState state, CharacterCue cue) {
    final reaction = _reactionState(cue.emotion);
    if (reaction == null) return EngineResult(state, const []);
    return _overlay(
      state.copyWith(stageContext: _cueContext(state, cue)),
      reaction,
      intensity: cue.intensity,
    );
  }

  EngineResult _clipEnded(CharacterEngineState state, ClipEnded event) {
    if (!_activePlay(state, event.assetId, event.playId)) {
      return EngineResult(state, const []);
    }
    if (_isReaction(state.activity)) {
      final entered = state.overlayEnteredAt;
      if (entered != null) {
        final elapsed = clock.now().difference(entered);
        if (elapsed < EngineConfig.overlayMin) {
          return _schedule(
            EngineResult(
              state.copyWith(overlayCompletionPending: true),
              const [],
            ),
            'overlay_min',
            EngineConfig.overlayMin - elapsed,
          );
        }
      }
      return _exitOverlay(state);
    }
    return _show(state, state.activity);
  }

  EngineResult _clipError(CharacterEngineState state, ClipError event) {
    if (!_activePlay(state, event.assetId, event.playId)) {
      return EngineResult(state, const []);
    }
    var next = state;
    if (event.isPermanent) {
      final broken = Set<String>.of(state.brokenAssetIds)..add(event.assetId);
      next = state.copyWith(brokenAssetIds: Set.unmodifiable(broken));
    } else {
      final transient = Set<String>.of(state.transientAssetIds)
        ..add(event.assetId);
      next = state.copyWith(transientAssetIds: Set.unmodifiable(transient));
    }
    final shown = _show(next, state.activity);
    final result = EngineResult(shown.state, [
      LogEngine(event.isPermanent ? 'CLIP_HARD_ERROR' : 'CLIP_INIT_TIMEOUT'),
      ...shown.effects,
    ]);
    return event.isPermanent
        ? result
        : _schedule(result, 'retry_asset', const Duration(seconds: 5));
  }

  EngineResult _tick(CharacterEngineState state, Tick event) {
    if (state.timerTokens[event.tag] != event.token) {
      return EngineResult(state, const []);
    }
    if (_isTurnTimer(event.tag) && event.turnId != state.currentTurnId) {
      return EngineResult(state, const []);
    }
    switch (event.tag) {
      case 'idle_to_sleep':
        return state.activity == CoreState.idle
            ? _show(state, CoreState.sleep)
            : EngineResult(state, const []);
      case 'working_max':
        return state.activity == CoreState.working
            ? _idle(state)
            : EngineResult(state, const []);
      case 'overlay_max':
        return _isReaction(state.activity)
            ? _exitOverlay(state)
            : EngineResult(state, const []);
      case 'overlay_min':
        return _isReaction(state.activity) && state.overlayCompletionPending
            ? _exitOverlay(state)
            : EngineResult(state, const []);
      case 'thinking_min_dwell':
        final reply = state.deferredReply;
        return reply == null
            ? EngineResult(state, const [])
            : _replyReady(state, reply, dwellSatisfied: true);
      case 'retry_asset':
        if (state.transientAssetIds.isEmpty) {
          return EngineResult(state, const []);
        }
        return _show(
          state.copyWith(transientAssetIds: const <String>{}),
          state.activity,
        );
      case 'pre_speech_max':
        return _isThinkingOrReaction(state.activity) &&
                state.currentTurnId != null &&
                state.pendingCue != null
            ? EngineResult(state, const [ReleaseTtsGate()])
            : EngineResult(state, const []);
      case 'tts_wait_timeout':
        if (state.currentTurnId == null ||
            state.pendingCue == null ||
            state.activity == CoreState.talking) {
          return EngineResult(state, const []);
        }
        final cleared = _cancelTurnTimers(EngineResult(state, const []));
        final idle = _idle(
          cleared.state.copyWith(clearTurnId: true, clearPendingCue: true),
        );
        return EngineResult(idle.state, [...cleared.effects, ...idle.effects]);
      case 'tts_playback_max':
        return state.currentTurnId != null &&
                state.activity == CoreState.talking
            ? reduce(state, TtsFailed(state.currentTurnId!))
            : EngineResult(state, const []);
      case 'thinking_variant_rotate':
        if (state.activity != CoreState.thinking) {
          return EngineResult(state, const []);
        }
        return _schedule(
          _show(state, CoreState.thinking),
          'thinking_variant_rotate',
          EngineConfig.thinkingVariantRotate,
        );
      case 'context_hold':
        if (state.activity != CoreState.idle ||
            state.stageContext == StageContext.daily) {
          return EngineResult(state, const []);
        }
        return _idle(state.copyWith(stageContext: StageContext.daily));
    }
    return EngineResult(state, const []);
  }

  EngineResult _thinking(CharacterEngineState state) => _schedule(
    _show(
      state.copyWith(thinkingEnteredAt: clock.now(), clearDeferredReply: true),
      CoreState.thinking,
    ),
    'thinking_variant_rotate',
    EngineConfig.thinkingVariantRotate,
  );

  EngineResult _exitOverlay(CharacterEngineState state) {
    if (state.currentTurnId != null && state.pendingCue != null) {
      final shown = _show(
        state.copyWith(
          clearOverlayEnteredAt: true,
          overlayCompletionPending: false,
        ),
        CoreState.thinking,
      );
      return EngineResult(shown.state, [
        const CancelTick('pre_speech_max'),
        const ReleaseTtsGate(),
        ...shown.effects,
      ]);
    }
    return state.jobActive ? _working(state) : _idle(state);
  }

  EngineResult _working(CharacterEngineState state) => _schedule(
    _show(state, CoreState.working),
    'working_max',
    EngineConfig.workingMax,
  );

  EngineResult _overlay(
    CharacterEngineState state,
    CoreState reaction, {
    Intensity? intensity,
  }) {
    final shown = _show(
      state.copyWith(
        overlayEnteredAt: clock.now(),
        overlayCompletionPending: false,
      ),
      reaction,
      intensity: intensity,
    );
    final durationMs =
        shown.state.lastResolution?.playRequest?.asset.durationMs;
    final max = durationMs == null
        ? EngineConfig.overlayMax
        : Duration(
            milliseconds: durationMs.clamp(
              EngineConfig.overlayMin.inMilliseconds,
              EngineConfig.overlayMax.inMilliseconds,
            ),
          );
    return _schedule(shown, 'overlay_max', max);
  }

  EngineResult _idle(CharacterEngineState state) {
    var result = _show(state, CoreState.idle);
    result = _schedule(
      result,
      'idle_to_sleep',
      state.inQuietHours
          ? EngineConfig.idleToSleepQuiet
          : EngineConfig.idleToSleepDay,
    );
    if (state.stageContext != StageContext.daily) {
      result = _schedule(result, 'context_hold', EngineConfig.contextHold);
    }
    return result;
  }

  EngineResult _schedule(EngineResult result, String tag, Duration delay) {
    final token = (result.state.timerTokens[tag] ?? 0) + 1;
    final tokens = Map<String, int>.of(result.state.timerTokens)..[tag] = token;
    return EngineResult(
      result.state.copyWith(timerTokens: Map.unmodifiable(tokens)),
      [
        ...result.effects,
        ScheduleTick(
          clock.now().add(delay),
          tag,
          token,
          turnId: result.state.currentTurnId,
        ),
      ],
    );
  }

  EngineResult _cancelTurnTimers(EngineResult result) {
    const tags = [
      'tts_wait_timeout',
      'tts_playback_max',
      'pre_speech_max',
      'thinking_min_dwell',
      'thinking_variant_rotate',
      'overlay_max',
      'overlay_min',
    ];
    return _cancelTimers(result, tags);
  }

  EngineResult _cancelTimers(EngineResult result, List<String> tags) {
    final tokens = Map<String, int>.of(result.state.timerTokens);
    for (final tag in tags) {
      tokens[tag] = (tokens[tag] ?? 0) + 1;
    }
    return EngineResult(
      result.state.copyWith(timerTokens: Map.unmodifiable(tokens)),
      [...result.effects, for (final tag in tags) CancelTick(tag)],
    );
  }

  bool _isTurnTimer(String tag) => const {
    'tts_wait_timeout',
    'tts_playback_max',
    'pre_speech_max',
    'thinking_min_dwell',
    'thinking_variant_rotate',
    'overlay_max',
    'overlay_min',
  }.contains(tag);

  bool _runsWhilePaused(String tag) => const {
    'tts_wait_timeout',
    'tts_playback_max',
    'pre_speech_max',
    'thinking_min_dwell',
  }.contains(tag);

  EngineResult _show(
    CharacterEngineState state,
    CoreState requested, {
    Intensity? intensity,
  }) {
    final context = requested == CoreState.working
        ? StageContext.assistant
        : requested == CoreState.sleep
        ? StageContext.daily
        : state.stageContext;
    final raw =
        AssetResolver(
          SeededRandomSource(state.randomSeed + state.randomCounter),
        ).resolve(
          ResolverInput(
            manifest: state.manifest,
            requestedState: requested,
            stageContext: context,
            ownerPolicy: state.ownerPolicy,
            readyAssetIds: state.readyAssetIds,
            readyPosterIds: state.readyPosterIds,
            brokenAssetIds: {
              ...state.brokenAssetIds,
              ...state.transientAssetIds,
            },
            recentUsage: state.recentUsage,
            privateSessionActive: state.privateSessionActive,
            intensity: intensity,
          ),
        );
    final generation = state.playbackGeneration + 1;
    final resolution = raw.withPlayId(generation);
    final recent = List<String>.of(state.recentUsage);
    if (resolution.assetId != null && resolution.kind == VisualKind.play) {
      recent.add(resolution.assetId!);
      if (recent.length > 20) recent.removeAt(0);
    }
    return EngineResult(
      state.copyWith(
        activity: requested,
        stageContext: resolution.effectiveContext,
        recentUsage: List.unmodifiable(recent),
        lastResolution: resolution,
        playbackGeneration: generation,
        randomCounter: state.randomCounter + 1,
      ),
      [Play(resolution)],
    );
  }

  List<EngineEffect> _cancelActivityTimers() => const [
    CancelTick('overlay_max'),
    CancelTick('working_max'),
    CancelTick('overlay_min'),
  ];

  bool _activeTurn(CharacterEngineState state, String turnId) =>
      state.currentTurnId != null && state.currentTurnId == turnId;

  bool _activePlay(CharacterEngineState state, String assetId, int playId) =>
      state.lastResolution?.assetId == assetId &&
      state.lastResolution?.playRequest?.playId == playId;

  bool _canSubmitTurn(CoreState state) => const {
    CoreState.idle,
    CoreState.sleep,
    CoreState.working,
    CoreState.happy,
    CoreState.shy,
    CoreState.surprised,
    CoreState.concerned,
  }.contains(state);

  bool _isThinkingOrReaction(CoreState state) =>
      state == CoreState.thinking || _isReaction(state);

  bool _isReaction(CoreState state) => const {
    CoreState.happy,
    CoreState.shy,
    CoreState.surprised,
    CoreState.concerned,
  }.contains(state);

  StageContext _cueContext(CharacterEngineState state, CharacterCue cue) {
    if (state.privateSessionActive) return StageContext.private;
    if (cue.stageContext == StageContext.private) return StageContext.daily;
    if (cue.stageContext == StageContext.relationship &&
        !state.ownerPolicy.relationshipStageEnabled) {
      return StageContext.daily;
    }
    return cue.stageContext ?? state.stageContext;
  }

  CoreState? _reactionState(Emotion emotion) => switch (emotion) {
    Emotion.happy => CoreState.happy,
    Emotion.shy => CoreState.shy,
    Emotion.surprised => CoreState.surprised,
    Emotion.concerned => CoreState.concerned,
    Emotion.neutral => null,
  };
}
