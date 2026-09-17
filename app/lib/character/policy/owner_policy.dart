import '../manifest/manifest_models.dart';

enum SecureWindowMode { auto, always, off }

class SensitiveModeConfirmationRequired implements Exception {
  const SensitiveModeConfirmationRequired(this.assetId);

  final String assetId;

  @override
  String toString() => 'SensitiveModeConfirmationRequired($assetId)';
}

class AssetPolicyOverride {
  const AssetPolicyOverride({
    this.enabled,
    this.allowedModes,
    this.weightMultiplier = 1,
  });

  final bool? enabled;
  final Set<StageContext>? allowedModes;
  final double weightMultiplier;

  AssetPolicyOverride copyWith({
    bool? enabled,
    bool clearEnabled = false,
    Set<StageContext>? allowedModes,
    bool clearAllowedModes = false,
    double? weightMultiplier,
  }) => AssetPolicyOverride(
    enabled: clearEnabled ? null : enabled ?? this.enabled,
    allowedModes: clearAllowedModes ? null : allowedModes ?? this.allowedModes,
    weightMultiplier: weightMultiplier ?? this.weightMultiplier,
  );
}

class OwnerPolicy {
  const OwnerPolicy({
    this.relationshipStageEnabled = false,
    this.discreetStageEnabled = false,
    this.secureWindowMode = SecureWindowMode.auto,
    this.overrides = const <String, AssetPolicyOverride>{},
  });

  final bool relationshipStageEnabled;
  final bool discreetStageEnabled;
  final SecureWindowMode secureWindowMode;
  bool get blockScreenshots => secureWindowMode != SecureWindowMode.off;
  final Map<String, AssetPolicyOverride> overrides;

  AssetPolicyOverride? overrideFor(String assetId) => overrides[assetId];

  OwnerPolicy copyWith({
    bool? relationshipStageEnabled,
    bool? discreetStageEnabled,
    SecureWindowMode? secureWindowMode,
    Map<String, AssetPolicyOverride>? overrides,
  }) => OwnerPolicy(
    relationshipStageEnabled:
        relationshipStageEnabled ?? this.relationshipStageEnabled,
    discreetStageEnabled: discreetStageEnabled ?? this.discreetStageEnabled,
    secureWindowMode: secureWindowMode ?? this.secureWindowMode,
    overrides: Map.unmodifiable(overrides ?? this.overrides),
  );

  OwnerPolicy setAssetEnabled(String assetId, bool enabled) => _replaceOverride(
    assetId,
    (current) => current.copyWith(enabled: enabled),
  );

  OwnerPolicy setAssetWeight(String assetId, double multiplier) {
    if (multiplier < 0 || multiplier > 4) {
      throw RangeError.range(multiplier, 0, 4, 'multiplier');
    }
    return _replaceOverride(
      assetId,
      (current) => current.copyWith(weightMultiplier: multiplier),
    );
  }

  OwnerPolicy setAssetAllowedModes(
    CharacterAsset asset,
    Set<StageContext> modes, {
    bool confirmSensitive = false,
  }) {
    if (modes.isEmpty) {
      throw ArgumentError.value(modes, 'modes', 'must not be empty');
    }
    final addsDaily = modes.any(
      (mode) => mode == StageContext.daily || mode == StageContext.assistant,
    );
    final labelsAlreadyAllow = asset.allowedModes.any(
      (mode) => mode == StageContext.daily || mode == StageContext.assistant,
    );
    if (asset.contentSensitivity != ContentSensitivity.normal &&
        addsDaily &&
        !labelsAlreadyAllow &&
        !confirmSensitive) {
      throw SensitiveModeConfirmationRequired(asset.assetId);
    }
    return _replaceOverride(
      asset.assetId,
      (current) => current.copyWith(allowedModes: Set.unmodifiable(modes)),
    );
  }

  OwnerPolicy _replaceOverride(
    String assetId,
    AssetPolicyOverride Function(AssetPolicyOverride current) update,
  ) {
    final next = Map<String, AssetPolicyOverride>.of(overrides);
    next[assetId] = update(next[assetId] ?? const AssetPolicyOverride());
    return copyWith(overrides: next);
  }
}
