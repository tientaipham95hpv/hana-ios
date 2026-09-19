import '../manifest/manifest_models.dart';
import '../policy/owner_policy.dart';
import '../resolver/asset_resolver.dart';
import 'character_cue.dart';
import 'engine_effect.dart';
import 'engine_event.dart';

class CharacterEngineState {
  const CharacterEngineState({
    required this.manifest,
    required this.ownerPolicy,
    required this.privateSessionActive,
    this.activity = CoreState.idle,
    this.stageContext = StageContext.daily,
    this.readyAssetIds = const <String>{},
    this.readyPosterIds = const <String>{},
    this.brokenAssetIds = const <String>{},
    this.transientAssetIds = const <String>{},
    this.recentUsage = const <String>[],
    this.paused = false,
    this.pausedAt,
    this.activeJobIds = const <String>{},
    this.currentTurnId,
    this.pendingCue,
    this.lastResolution,
    this.playbackGeneration = 0,
    this.randomSeed = 42,
    this.randomCounter = 0,
    this.timerTokens = const <String, int>{},
    this.inQuietHours = false,
    this.disposed = false,
    this.thinkingEnteredAt,
    this.deferredReply,
    this.overlayEnteredAt,
    this.overlayCompletionPending = false,
  });

  final CharacterManifest manifest;
  final OwnerPolicy ownerPolicy;
  final bool privateSessionActive;
  final CoreState activity;
  final StageContext stageContext;
  final Set<String> readyAssetIds;
  final Set<String> readyPosterIds;
  final Set<String> brokenAssetIds;
  final Set<String> transientAssetIds;
  final List<String> recentUsage;
  final bool paused;
  final DateTime? pausedAt;
  final Set<String> activeJobIds;
  bool get jobActive => activeJobIds.isNotEmpty;
  final String? currentTurnId;
  final CharacterCue? pendingCue;
  final ResolutionResult? lastResolution;
  final int playbackGeneration;
  final int randomSeed;
  final int randomCounter;
  final Map<String, int> timerTokens;
  final bool inQuietHours;
  final bool disposed;
  final DateTime? thinkingEnteredAt;
  final ReplyReady? deferredReply;
  final DateTime? overlayEnteredAt;
  final bool overlayCompletionPending;

  CharacterEngineState copyWith({
    CharacterManifest? manifest,
    OwnerPolicy? ownerPolicy,
    CoreState? activity,
    StageContext? stageContext,
    Set<String>? readyAssetIds,
    Set<String>? readyPosterIds,
    Set<String>? brokenAssetIds,
    Set<String>? transientAssetIds,
    List<String>? recentUsage,
    bool? paused,
    DateTime? pausedAt,
    bool clearPausedAt = false,
    Set<String>? activeJobIds,
    String? currentTurnId,
    bool clearTurnId = false,
    CharacterCue? pendingCue,
    bool clearPendingCue = false,
    ResolutionResult? lastResolution,
    int? playbackGeneration,
    int? randomSeed,
    int? randomCounter,
    Map<String, int>? timerTokens,
    bool? inQuietHours,
    bool? disposed,
    DateTime? thinkingEnteredAt,
    bool clearThinkingEnteredAt = false,
    ReplyReady? deferredReply,
    bool clearDeferredReply = false,
    DateTime? overlayEnteredAt,
    bool clearOverlayEnteredAt = false,
    bool? overlayCompletionPending,
  }) => CharacterEngineState(
    manifest: manifest ?? this.manifest,
    ownerPolicy: ownerPolicy ?? this.ownerPolicy,
    privateSessionActive: privateSessionActive,
    activity: activity ?? this.activity,
    stageContext: stageContext ?? this.stageContext,
    readyAssetIds: readyAssetIds ?? this.readyAssetIds,
    readyPosterIds: readyPosterIds ?? this.readyPosterIds,
    brokenAssetIds: brokenAssetIds ?? this.brokenAssetIds,
    transientAssetIds: transientAssetIds ?? this.transientAssetIds,
    recentUsage: recentUsage ?? this.recentUsage,
    paused: paused ?? this.paused,
    pausedAt: clearPausedAt ? null : pausedAt ?? this.pausedAt,
    activeJobIds: activeJobIds ?? this.activeJobIds,
    currentTurnId: clearTurnId ? null : currentTurnId ?? this.currentTurnId,
    pendingCue: clearPendingCue ? null : pendingCue ?? this.pendingCue,
    lastResolution: lastResolution ?? this.lastResolution,
    playbackGeneration: playbackGeneration ?? this.playbackGeneration,
    randomSeed: randomSeed ?? this.randomSeed,
    randomCounter: randomCounter ?? this.randomCounter,
    timerTokens: timerTokens ?? this.timerTokens,
    inQuietHours: inQuietHours ?? this.inQuietHours,
    disposed: disposed ?? this.disposed,
    thinkingEnteredAt: clearThinkingEnteredAt
        ? null
        : thinkingEnteredAt ?? this.thinkingEnteredAt,
    deferredReply: clearDeferredReply
        ? null
        : deferredReply ?? this.deferredReply,
    overlayEnteredAt: clearOverlayEnteredAt
        ? null
        : overlayEnteredAt ?? this.overlayEnteredAt,
    overlayCompletionPending:
        overlayCompletionPending ?? this.overlayCompletionPending,
  );
}

class EngineResult {
  const EngineResult(this.state, this.effects);
  final CharacterEngineState state;
  final List<EngineEffect> effects;
}
