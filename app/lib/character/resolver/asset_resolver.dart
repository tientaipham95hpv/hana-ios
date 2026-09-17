import '../manifest/manifest_models.dart';
import '../policy/owner_policy.dart';
import 'random_source.dart';

enum VisualKind { play, poster, silhouette }

class PlayRequest {
  const PlayRequest({
    required this.asset,
    required this.loop,
    required this.crossfadeMs,
    this.playId = 0,
  });

  final CharacterAsset asset;
  final bool loop;
  final int crossfadeMs;
  final int playId;

  PlayRequest withPlayId(int value) => PlayRequest(
    asset: asset,
    loop: loop,
    crossfadeMs: crossfadeMs,
    playId: value,
  );
}

class ResolutionResult {
  const ResolutionResult({
    required this.kind,
    required this.effectiveContext,
    required this.fallbackTrace,
    required this.candidatePoolCount,
    this.playRequest,
    this.posterAsset,
  });

  final VisualKind kind;
  final StageContext effectiveContext;
  final List<String> fallbackTrace;
  final int candidatePoolCount;
  final PlayRequest? playRequest;
  final CharacterAsset? posterAsset;

  String? get assetId => playRequest?.asset.assetId ?? posterAsset?.assetId;

  ResolutionResult withPlayId(int playId) => ResolutionResult(
    kind: kind,
    effectiveContext: effectiveContext,
    fallbackTrace: fallbackTrace,
    candidatePoolCount: candidatePoolCount,
    playRequest: playRequest?.withPlayId(playId),
    posterAsset: posterAsset,
  );
}

class ResolverInput {
  const ResolverInput({
    required this.manifest,
    required this.requestedState,
    required this.stageContext,
    required this.ownerPolicy,
    required this.readyAssetIds,
    required this.readyPosterIds,
    required this.brokenAssetIds,
    required this.recentUsage,
    required this.privateSessionActive,
    this.intensity,
  });

  final CharacterManifest manifest;
  final CoreState requestedState;
  final StageContext stageContext;
  final OwnerPolicy ownerPolicy;
  final Set<String> readyAssetIds;
  final Set<String> readyPosterIds;
  final Set<String> brokenAssetIds;
  final List<String> recentUsage;
  final bool privateSessionActive;
  final Intensity? intensity;
}

class AssetResolver {
  AssetResolver(this.random);

  final RandomSource random;

  ResolutionResult resolve(ResolverInput input) {
    var context = _effectiveContext(input);
    final trace = <String>[];
    if (input.ownerPolicy.discreetStageEnabled) {
      return ResolutionResult(
        kind: VisualKind.silhouette,
        effectiveContext: context,
        fallbackTrace: const ['discreet_stage', 'silhouette'],
        candidatePoolCount: 0,
      );
    }

    final requested = _pool(
      input,
      input.requestedState,
      context,
      requireReady: true,
    );
    final requestedCount = requested.length;
    trace.add('requested:${input.requestedState.name}@$context');
    var selected = _select(requested, input.requestedState, context, input);
    if (selected != null) {
      return _play(selected, context, trace, requestedCount);
    }

    if (input.requestedState != CoreState.idle) {
      trace.add('idle@$context');
      selected = _select(
        _pool(input, CoreState.idle, context, requireReady: true),
        CoreState.idle,
        context,
        input,
      );
      if (selected != null) {
        return _play(selected, context, trace, requestedCount);
      }
    }

    if (context == StageContext.assistant ||
        context == StageContext.relationship) {
      trace.add('daily:${input.requestedState.name}');
      selected = _select(
        _pool(
          input,
          input.requestedState,
          StageContext.daily,
          requireReady: true,
        ),
        input.requestedState,
        StageContext.daily,
        input,
      );
      if (selected == null && input.requestedState != CoreState.idle) {
        trace.add('daily:idle');
        selected = _select(
          _pool(input, CoreState.idle, StageContext.daily, requireReady: true),
          CoreState.idle,
          StageContext.daily,
          input,
        );
      }
      if (selected != null) {
        context = StageContext.daily;
        return _play(selected, context, trace, requestedCount);
      }
    }

    final poster = _posterCandidate(input, context);
    if (poster != null) {
      trace.add('poster');
      return ResolutionResult(
        kind: VisualKind.poster,
        effectiveContext: context,
        fallbackTrace: List.unmodifiable(trace),
        candidatePoolCount: requestedCount,
        posterAsset: poster,
      );
    }
    trace.add('silhouette');
    return ResolutionResult(
      kind: VisualKind.silhouette,
      effectiveContext: context,
      fallbackTrace: List.unmodifiable(trace),
      candidatePoolCount: requestedCount,
    );
  }

  StageContext _effectiveContext(ResolverInput input) {
    if (input.privateSessionActive) return StageContext.private;
    if (input.stageContext == StageContext.private) return StageContext.daily;
    if (input.stageContext == StageContext.relationship &&
        !input.ownerPolicy.relationshipStageEnabled) {
      return StageContext.daily;
    }
    return input.stageContext;
  }

  List<CharacterAsset> _pool(
    ResolverInput input,
    CoreState state,
    StageContext context, {
    required bool requireReady,
  }) {
    final assets = input.manifest.assets.where((asset) {
      if (!asset.supportsState(state)) return false;
      if (!_eligible(input, asset, context)) return false;
      return !requireReady || input.readyAssetIds.contains(asset.assetId);
    }).toList();
    if (context == StageContext.daily || context == StageContext.assistant) {
      if (assets.isEmpty) return assets;
      final minimum = assets
          .map((asset) => asset.contentSensitivity.index)
          .reduce((left, right) => left < right ? left : right);
      return assets
          .where((asset) => asset.contentSensitivity.index == minimum)
          .toList();
    }
    return assets;
  }

  bool _eligible(
    ResolverInput input,
    CharacterAsset asset,
    StageContext context,
  ) {
    if (asset.audioStreams != 0) return false;
    if (input.brokenAssetIds.contains(asset.assetId)) return false;
    if (!input.privateSessionActive &&
        asset.delivery == Delivery.privateVault) {
      return false;
    }
    if (!input.privateSessionActive && context == StageContext.private) {
      return false;
    }
    final override = input.ownerPolicy.overrideFor(asset.assetId);
    final enabled = override?.enabled ?? !asset.excludedByDefault;
    if (!enabled) return false;
    final modes = override?.allowedModes ?? asset.allowedModes;
    if (!modes.contains(context)) return false;
    return _effectiveWeight(asset, override) > 0;
  }

  double _effectiveWeight(
    CharacterAsset asset,
    AssetPolicyOverride? override,
  ) => asset.weight * (override?.weightMultiplier ?? 1);

  CharacterAsset? _select(
    List<CharacterAsset> source,
    CoreState state,
    StageContext context,
    ResolverInput input,
  ) {
    if (source.isEmpty) return null;
    var pool = List<CharacterAsset>.of(source);
    if (_isActivity(state)) {
      final main = pool
          .where(
            (asset) =>
                asset.kind == PlaybackKind.loop &&
                !asset.reviewFlag &&
                asset.technicalQuality != TechnicalQuality.poor,
          )
          .toList();
      final variants = pool.where((asset) => !main.contains(asset)).toList();
      if (main.isNotEmpty) {
        pool = random.nextDouble() < 0.2 && variants.isNotEmpty
            ? variants
            : main;
      }
    }
    if (input.intensity != null) {
      final matching = pool
          .where((asset) => asset.intensityTags.contains(input.intensity))
          .toList();
      if (matching.isNotEmpty) pool = matching;
    }
    final recentWindow = pool.length >= 4 ? 2 : 1;
    final recent = input.recentUsage.reversed.take(recentWindow).toSet();
    final fresh = pool
        .where((asset) => !recent.contains(asset.assetId))
        .toList();
    if (fresh.isNotEmpty) pool = fresh;
    final weights = pool.map((asset) {
      final override = input.ownerPolicy.overrideFor(asset.assetId);
      final fit = asset.states[state] == PoolRole.primary ? 1.0 : 0.5;
      return _effectiveWeight(asset, override) * fit;
    }).toList();
    final total = weights.fold<double>(0, (sum, weight) => sum + weight);
    if (total <= 0) return null;
    var cursor = random.nextDouble() * total;
    for (var index = 0; index < pool.length; index += 1) {
      cursor -= weights[index];
      if (cursor < 0) return pool[index];
    }
    return pool.last;
  }

  CharacterAsset? _posterCandidate(ResolverInput input, StageContext context) {
    for (final assetId in input.recentUsage.reversed) {
      final asset = input.manifest.byId[assetId];
      if (asset != null &&
          input.readyPosterIds.contains(assetId) &&
          _eligible(input, asset, context)) {
        return asset;
      }
    }
    final idle = _pool(input, CoreState.idle, context, requireReady: false);
    for (final asset in idle) {
      if (input.readyPosterIds.contains(asset.assetId)) return asset;
    }
    return null;
  }

  ResolutionResult _play(
    CharacterAsset asset,
    StageContext context,
    List<String> trace,
    int candidateCount,
  ) {
    trace.add('play:${asset.assetId}');
    return ResolutionResult(
      kind: VisualKind.play,
      effectiveContext: context,
      fallbackTrace: List.unmodifiable(trace),
      candidatePoolCount: candidateCount,
      playRequest: PlayRequest(
        asset: asset,
        loop: asset.kind == PlaybackKind.loop,
        crossfadeMs: asset.loopQuality == 'seamless' ? 0 : 250,
      ),
    );
  }

  bool _isActivity(CoreState state) => const {
    CoreState.idle,
    CoreState.listening,
    CoreState.talking,
    CoreState.thinking,
    CoreState.working,
    CoreState.sleep,
  }.contains(state);
}
