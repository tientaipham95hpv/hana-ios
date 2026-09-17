import '../resolver/asset_resolver.dart';

sealed class EngineEffect {
  const EngineEffect();
}

class Play extends EngineEffect {
  const Play(this.resolution);
  final ResolutionResult resolution;
}

class Preload extends EngineEffect {
  const Preload(this.resolution);
  final ResolutionResult resolution;
}

class PauseStage extends EngineEffect {
  const PauseStage();
}

class ResumeStage extends EngineEffect {
  const ResumeStage();
}

class StopTts extends EngineEffect {
  const StopTts();
}

class ReleaseTtsGate extends EngineEffect {
  const ReleaseTtsGate();
}

class ScheduleTick extends EngineEffect {
  const ScheduleTick(this.at, this.tag, this.token, {this.turnId});
  final DateTime at;
  final String tag;
  final int token;
  final String? turnId;
}

class CancelTick extends EngineEffect {
  const CancelTick(this.tag);
  final String tag;
}

class LogEngine extends EngineEffect {
  const LogEngine(this.code);
  final String code;
}
