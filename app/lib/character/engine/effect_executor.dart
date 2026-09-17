import 'package:flutter/foundation.dart';

import '../resolver/asset_resolver.dart';
import '../stage/asset_repository.dart';
import 'engine_effect.dart';
import 'engine_event.dart';
import 'timer_driver.dart';

class EngineRuntimePorts {
  const EngineRuntimePorts({
    this.onPlay,
    this.onPreload,
    this.onStagePaused,
    this.onStopTts,
    this.onReleaseTtsGate,
    this.onLog,
  });

  final ValueChanged<ResolutionResult>? onPlay;
  final ValueChanged<ResolutionResult>? onPreload;
  final ValueChanged<bool>? onStagePaused;
  final VoidCallback? onStopTts;
  final VoidCallback? onReleaseTtsGate;
  final ValueChanged<String>? onLog;
}

class EngineEffectExecutor {
  EngineEffectExecutor({
    required this.timerDriver,
    required this.dispatch,
    required this.repository,
    this.ports = const EngineRuntimePorts(),
  });

  final TimerDriver timerDriver;
  final ValueChanged<EngineEvent> dispatch;
  final CharacterAssetRepository repository;
  final EngineRuntimePorts ports;

  void execute(Iterable<EngineEffect> effects) {
    for (final effect in effects) {
      switch (effect) {
        case Play():
          ports.onPlay?.call(effect.resolution);
        case Preload():
          ports.onPreload?.call(effect.resolution);
          final asset = effect.resolution.playRequest?.asset;
          if (asset != null) repository.resolve(asset);
        case ScheduleTick():
          timerDriver.schedule(
            effect.tag,
            effect.at,
            () =>
                dispatch(Tick(effect.tag, effect.token, turnId: effect.turnId)),
          );
        case CancelTick():
          timerDriver.cancel(effect.tag);
        case PauseStage():
          ports.onStagePaused?.call(true);
        case ResumeStage():
          ports.onStagePaused?.call(false);
        case StopTts():
          ports.onStopTts?.call();
        case ReleaseTtsGate():
          ports.onReleaseTtsGate?.call();
        case LogEngine():
          (ports.onLog ?? debugPrint).call(effect.code);
      }
    }
  }

  void dispose() => timerDriver.cancelAll();
}
