enum CoreState {
  idle,
  listening,
  talking,
  thinking,
  happy,
  shy,
  surprised,
  concerned,
  working,
  sleep,
}

enum Emotion { neutral, happy, shy, surprised, concerned }

enum Intensity { low, medium, high }

enum StageContext { daily, assistant, relationship, private }

enum ContentSensitivity { normal, suggestive, private }

enum Delivery { bundle, vault, privateVault }

enum ManifestKind { bundle, vault, privateVault }

enum TechnicalQuality { good, fair, poor }

enum PlaybackKind { loop, oneshot }

enum PoolRole { primary, shared }

enum LoopGrade { a, b, c, d }

T parseEnum<T extends Enum>(Iterable<T> values, Object? raw, String field) {
  if (raw is! String) {
    throw FormatException('$field must be a string');
  }
  String wireName(T value) {
    if (value is LoopGrade) return value.name.toUpperCase();
    return value.name == 'privateVault' ? 'private_vault' : value.name;
  }

  return values.firstWhere(
    (value) => wireName(value) == raw,
    orElse: () => throw FormatException('invalid $field: $raw'),
  );
}

class CueDefinition {
  const CueDefinition({
    required this.cue,
    required this.allowedModes,
    required this.cooldownSeconds,
    required this.allowedInQuietHours,
    required this.llmSelectable,
  });

  final String cue;
  final Set<StageContext> allowedModes;
  final int cooldownSeconds;
  final bool allowedInQuietHours;
  final bool llmSelectable;
}

class CharacterAsset {
  const CharacterAsset({
    required this.assetId,
    required this.delivery,
    required this.contentSensitivity,
    required this.allowedModes,
    required this.technicalQuality,
    required this.reviewFlag,
    required this.excludedByDefault,
    required this.states,
    required this.cues,
    required this.kind,
    required this.loopGrade,
    required this.loopQuality,
    required this.weight,
    required this.path,
    required this.poster,
    required this.posterBlur,
    required this.durationMs,
    required this.width,
    required this.height,
    required this.renderMode,
    required this.focalX,
    required this.focalY,
    required this.audioStreams,
    required this.sha256,
    required this.bytes,
    this.intensityTags = const <Intensity>{},
  });

  final String assetId;
  final Delivery delivery;
  final ContentSensitivity contentSensitivity;
  final Set<StageContext> allowedModes;
  final TechnicalQuality technicalQuality;
  final bool reviewFlag;
  final bool excludedByDefault;
  final Map<CoreState, PoolRole> states;
  final Set<String> cues;
  final PlaybackKind kind;
  final LoopGrade loopGrade;
  final String loopQuality;
  final double weight;
  final String path;
  final String poster;
  final String posterBlur;
  final int durationMs;
  final int width;
  final int height;
  final String renderMode;
  final double focalX;
  final double focalY;
  final Set<Intensity> intensityTags;
  final int audioStreams;
  final String sha256;
  final int bytes;

  bool supportsState(CoreState state) => states.containsKey(state);
}

class CharacterManifest {
  CharacterManifest({
    required this.schemaVersion,
    required this.manifestKind,
    required this.manifestVersion,
    required List<CharacterAsset> assets,
    required List<CueDefinition> cues,
  }) : assets = List.unmodifiable(assets),
       cues = List.unmodifiable(cues),
       byId = Map.unmodifiable({
         for (final asset in assets) asset.assetId: asset,
       });

  final int schemaVersion;
  final ManifestKind manifestKind;
  final String manifestVersion;
  final List<CharacterAsset> assets;
  final List<CueDefinition> cues;
  final Map<String, CharacterAsset> byId;

  Iterable<CharacterAsset> poolForState(CoreState state) =>
      assets.where((asset) => asset.supportsState(state));

  factory CharacterManifest.empty() => CharacterManifest(
    schemaVersion: 2,
    manifestKind: ManifestKind.vault,
    manifestVersion: 'invalid-fallback',
    assets: const [],
    cues: const [],
  );
}
