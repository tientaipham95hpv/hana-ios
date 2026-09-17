import 'package:flutter_test/flutter_test.dart';

import 'support/canonical_manifest.dart';

import 'package:hana_app/character/manifest/manifest_models.dart';
import 'package:hana_app/character/policy/owner_policy.dart';
import 'package:hana_app/character/resolver/asset_resolver.dart';
import 'package:hana_app/character/resolver/random_source.dart';

void main() {
  final manifest = canonicalManifest();

  ResolverInput input({
    CoreState state = CoreState.idle,
    StageContext context = StageContext.daily,
    OwnerPolicy policy = const OwnerPolicy(),
    Set<String>? ready,
    Set<String> posters = const {},
    Set<String> broken = const {},
    List<String> recent = const [],
    bool privateSession = false,
  }) => ResolverInput(
    manifest: manifest,
    requestedState: state,
    stageContext: context,
    ownerPolicy: policy,
    readyAssetIds: ready ?? manifest.byId.keys.toSet(),
    readyPosterIds: posters,
    brokenAssetIds: broken,
    recentUsage: recent,
    privateSessionActive: privateSession,
  );

  test('default candidate counts derive to 15/15/41/41', () {
    bool enabled(CharacterAsset asset) => !asset.excludedByDefault;
    int count(StageContext mode) => manifest.assets
        .where((asset) => enabled(asset) && asset.allowedModes.contains(mode))
        .length;
    expect(count(StageContext.daily), 15);
    expect(count(StageContext.assistant), 15);
    expect(count(StageContext.relationship), 41);
    expect(count(StageContext.private), 41);
  });

  test('daily obeys lowest sensitivity tier in the eligible pool', () {
    final privateAsset = manifest.byId['chr_003']!;
    final policy = const OwnerPolicy().setAssetAllowedModes(privateAsset, {
      ...privateAsset.allowedModes,
      StageContext.daily,
    }, confirmSensitive: true);
    final result = AssetResolver(FixedRandomSource([0.5, 0]))
        .resolve(input(policy: policy, ready: {'chr_003', 'chr_018'}));
    expect(
      result.playRequest!.asset.contentSensitivity,
      ContentSensitivity.suggestive,
    );
  });

  test('relationship disabled falls closed to daily behavior', () {
    final result = AssetResolver(FixedRandomSource([0]))
        .resolve(input(context: StageContext.relationship, ready: {'chr_003'}));
    expect(result.effectiveContext, StageContext.daily);
    expect(result.kind, VisualKind.silhouette);
  });

  test('relationship enabled can use relationship candidate', () {
    final result = AssetResolver(FixedRandomSource([0])).resolve(
      input(
        context: StageContext.relationship,
        policy: const OwnerPolicy(relationshipStageEnabled: true),
        ready: {'chr_003'},
      ),
    );
    expect(result.effectiveContext, StageContext.relationship);
    expect(result.assetId, 'chr_003');
  });

  test('private assets require an active private session', () {
    final resolver = AssetResolver(FixedRandomSource([0]));
    expect(
      resolver
          .resolve(input(context: StageContext.private, ready: {'chr_003'}))
          .kind,
      VisualKind.silhouette,
    );
    expect(
      resolver
          .resolve(
            input(
              context: StageContext.private,
              ready: {'chr_003'},
              privateSession: true,
            ),
          )
          .assetId,
      'chr_003',
    );
  });

  test('excluded asset needs an explicit owner override', () {
    final resolver = AssetResolver(FixedRandomSource([0]));
    expect(
      resolver.resolve(input(ready: {'chr_011'})).kind,
      VisualKind.silhouette,
    );
    final policy = const OwnerPolicy().setAssetEnabled('chr_011', true);
    expect(
      resolver.resolve(input(ready: {'chr_011'}, policy: policy)).assetId,
      'chr_011',
    );
  });

  test('review asset remains selectable', () {
    final result = AssetResolver(FixedRandomSource([0]))
        .resolve(input(ready: {'chr_001'}));
    expect(result.assetId, 'chr_001');
    expect(result.playRequest!.asset.reviewFlag, isTrue);
  });

  test('poor oneshot does not displace a healthy primary loop', () {
    final policy = const OwnerPolicy().setAssetEnabled('chr_011', true);
    final result = AssetResolver(FixedRandomSource([0.9, 0]))
        .resolve(input(ready: {'chr_011', 'chr_018'}, policy: policy));
    expect(result.assetId, 'chr_018');
  });

  test('per-clip weight override changes weighted selection', () {
    final policy = const OwnerPolicy().setAssetWeight('chr_018', 0);
    final result = AssetResolver(FixedRandomSource([0.9, 0])).resolve(
      input(
        context: StageContext.relationship,
        policy: policy.copyWith(relationshipStageEnabled: true),
        ready: {'chr_018', 'chr_026'},
      ),
    );
    expect(result.assetId, 'chr_026');
  });

  test('immediate repetition is avoided when another clip is ready', () {
    final result = AssetResolver(FixedRandomSource([0.9, 0])).resolve(
      input(
        context: StageContext.relationship,
        policy: const OwnerPolicy(relationshipStageEnabled: true),
        ready: {'chr_018', 'chr_026'},
        recent: ['chr_018'],
      ),
    );
    expect(result.assetId, 'chr_026');
  });

  test('missing requested state falls back to allowed idle pool', () {
    final result = AssetResolver(FixedRandomSource([0.9, 0]))
        .resolve(input(state: CoreState.surprised, ready: {'chr_018'}));
    expect(result.assetId, 'chr_018');
    expect(result.fallbackTrace, contains('idle@StageContext.daily'));
  });

  test('fallback never crosses into a disallowed mode', () {
    final asset = manifest.byId['chr_018']!;
    final policy = const OwnerPolicy().setAssetAllowedModes(asset, {
      StageContext.daily,
    }, confirmSensitive: true);
    final result = AssetResolver(FixedRandomSource([0])).resolve(
      input(
        context: StageContext.private,
        privateSession: true,
        ready: {'chr_018'},
        posters: {'chr_018'},
        policy: policy,
      ),
    );
    expect(result.kind, VisualKind.silhouette);
  });

  test('missing and corrupt assets fall through without crashing', () {
    final resolver = AssetResolver(FixedRandomSource([0]));
    expect(
      resolver.resolve(input(ready: const {})).kind,
      VisualKind.silhouette,
    );
    expect(
      resolver.resolve(input(ready: {'chr_018'}, broken: {'chr_018'})).kind,
      VisualKind.silhouette,
    );
  });

  test('poster precedes silhouette when a permitted poster exists', () {
    final result = AssetResolver(FixedRandomSource([0])).resolve(
      input(ready: const {}, posters: {'chr_018'}, recent: ['chr_018']),
    );
    expect(result.kind, VisualKind.poster);
    expect(result.assetId, 'chr_018');
  });

  test('discreet stage always resolves to silhouette', () {
    final result = AssetResolver(FixedRandomSource([0]))
        .resolve(input(policy: const OwnerPolicy(discreetStageEnabled: true)));
    expect(result.kind, VisualKind.silhouette);
    expect(result.fallbackTrace.first, 'discreet_stage');
  });

  test('adding sensitive asset to daily requires explicit confirmation', () {
    final asset = manifest.byId['chr_003']!;
    expect(
      () => const OwnerPolicy().setAssetAllowedModes(asset, {
        ...asset.allowedModes,
        StageContext.daily,
      }),
      throwsA(isA<SensitiveModeConfirmationRequired>()),
    );
  });
}
