import 'character_cue.dart';

sealed class EngineEvent {
  const EngineEvent();
}

class AppStarted extends EngineEvent {
  const AppStarted({this.inQuietHours = false});
  final bool inQuietHours;
}

class UserActivity extends EngineEvent {
  const UserActivity();
}

class PolicyUpdated extends EngineEvent {
  const PolicyUpdated();
}

class AssetsAvailabilityChanged extends EngineEvent {
  const AssetsAvailabilityChanged();
}

class PttPressed extends EngineEvent {
  const PttPressed();
}

class PttReleased extends EngineEvent {
  const PttReleased({required this.valid});
  final bool valid;
}

class PttCancelled extends EngineEvent {
  const PttCancelled();
}

class PttUploadFailed extends EngineEvent {
  const PttUploadFailed();
}

class TurnSubmitted extends EngineEvent {
  const TurnSubmitted(this.turnId);
  final String turnId;
}

class ReplyReady extends EngineEvent {
  const ReplyReady({
    required this.turnId,
    required this.cue,
    required this.willSpeak,
  });
  final String turnId;
  final CharacterCue cue;
  final bool willSpeak;
}

class TtsStarted extends EngineEvent {
  const TtsStarted(this.turnId);
  final String turnId;
}

class TtsFinished extends EngineEvent {
  const TtsFinished(this.turnId);
  final String turnId;
}

class TtsFailed extends EngineEvent {
  const TtsFailed(this.turnId);
  final String turnId;
}

class TtsStoppedByUser extends EngineEvent {
  const TtsStoppedByUser();
}

class TurnFailed extends EngineEvent {
  const TurnFailed(this.turnId);
  final String turnId;
}

class TurnCancelled extends EngineEvent {
  const TurnCancelled(this.turnId);
  final String turnId;
}

class JobStarted extends EngineEvent {
  const JobStarted(this.jobId);
  final String jobId;
}

class JobFinished extends EngineEvent {
  const JobFinished(this.jobId);
  final String jobId;
}

class CueReceived extends EngineEvent {
  const CueReceived(this.cue);
  final CharacterCue cue;
}

class AppPaused extends EngineEvent {
  const AppPaused();
}

class AppResumed extends EngineEvent {
  const AppResumed();
}

class ClipEnded extends EngineEvent {
  const ClipEnded(this.assetId, {required this.playId});
  final String assetId;
  final int playId;
}

class ClipError extends EngineEvent {
  const ClipError(
    this.assetId,
    this.message, {
    required this.playId,
    this.isPermanent = true,
  });
  final String assetId;
  final String message;
  final int playId;
  final bool isPermanent;
}

class Tick extends EngineEvent {
  const Tick(this.tag, this.token, {this.turnId});
  final String tag;
  final int token;
  final String? turnId;
}
