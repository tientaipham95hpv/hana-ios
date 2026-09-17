import 'dart:convert';

import 'manifest_models.dart';

class ManifestLoadResult {
  const ManifestLoadResult._({this.manifest, this.error});

  factory ManifestLoadResult.valid(CharacterManifest manifest) =>
      ManifestLoadResult._(manifest: manifest);

  factory ManifestLoadResult.invalid(Object error) =>
      ManifestLoadResult._(error: error.toString());

  final CharacterManifest? manifest;
  final String? error;

  bool get isValid => manifest != null;
}

class CharacterManifestLoader {
  const CharacterManifestLoader();

  static const _rootFields = {
    'schema_version',
    'manifest_kind',
    'manifest_version',
    'generated_at',
    'cue_registry',
    'assets',
  };
  static const _assetFields = {
    'asset_id',
    'delivery',
    'delivery_class',
    'content_sensitivity',
    'allowed_modes',
    'technical_quality',
    'review_flag',
    'excluded_by_default',
    'states',
    'cues',
    'kind',
    'loop_grade',
    'loop_quality',
    'path',
    'poster',
    'poster_blur',
    'duration_ms',
    'width',
    'height',
    'render_mode',
    'focal_x',
    'focal_y',
    'intensity_tags',
    'weight',
    'audio_streams',
    'subtitle_streams',
    'data_streams',
    'attached_picture_streams',
    'sha256',
    'bytes',
  };
  static const _cueFields = {
    'cue',
    'allowed_modes',
    'cooldown_s',
    'allowed_in_quiet_hours',
    'llm_selectable',
  };

  ManifestLoadResult load(
    String source, {
    int expectedAssetCount = 43,
    Set<ManifestKind> allowedKinds = const {
      ManifestKind.bundle,
      ManifestKind.vault,
    },
  }) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('manifest root must be an object');
      }
      return ManifestLoadResult.valid(
        parse(
          decoded,
          expectedAssetCount: expectedAssetCount,
          allowedKinds: allowedKinds,
        ),
      );
    } on Object catch (error) {
      return ManifestLoadResult.invalid(error);
    }
  }

  CharacterManifest parse(
    Map<String, dynamic> json, {
    int expectedAssetCount = 43,
    Set<ManifestKind> allowedKinds = const {
      ManifestKind.bundle,
      ManifestKind.vault,
    },
  }) {
    _requireKnownFields(json, _rootFields);
    _rejectForbiddenFields(json, const {
      'source_file',
      'notes',
      'hard_block',
      'sensitivity_source',
    });
    final schemaVersion = _integer(json['schema_version'], 'schema_version');
    if (schemaVersion != 2) {
      throw FormatException('unsupported schema_version: $schemaVersion');
    }
    final manifestKind = parseEnum(
      ManifestKind.values,
      json['manifest_kind'],
      'manifest_kind',
    );
    if (!allowedKinds.contains(manifestKind)) {
      throw FormatException(
        'manifest_kind not allowed in this engine: ${json['manifest_kind']}',
      );
    }
    final rawAssets = json['assets'];
    if (rawAssets is! List || rawAssets.length != expectedAssetCount) {
      throw FormatException(
        'manifest must contain exactly $expectedAssetCount assets',
      );
    }
    final assets = <CharacterAsset>[];
    final ids = <String>{};
    for (final raw in rawAssets) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('asset must be an object');
      }
      final asset = _asset(raw);
      if (!ids.add(asset.assetId)) {
        throw FormatException('duplicate asset_id: ${asset.assetId}');
      }
      assets.add(asset);
      _validateManifestAssociation(manifestKind, asset);
    }
    for (var index = 0; index < assets.length; index++) {
      final expected = 'chr_${(index + 1).toString().padLeft(3, '0')}';
      if (assets[index].assetId != expected) {
        throw FormatException(
          'asset IDs must be sequential: expected $expected',
        );
      }
    }
    final rawCues = json['cue_registry'];
    final cues = <CueDefinition>[];
    final cueNames = <String>{};
    if (rawCues != null) {
      if (rawCues is! List) {
        throw const FormatException('cue_registry must be an array');
      }
      for (final raw in rawCues) {
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('cue must be an object');
        }
        final cue = _cue(raw);
        if (!cueNames.add(cue.cue)) {
          throw FormatException('duplicate cue: ${cue.cue}');
        }
        cues.add(cue);
      }
    }
    return CharacterManifest(
      schemaVersion: schemaVersion,
      manifestKind: manifestKind,
      manifestVersion: _string(json['manifest_version'], 'manifest_version'),
      assets: assets,
      cues: cues,
    );
  }

  CharacterAsset _asset(Map<String, dynamic> json) {
    _requireKnownFields(json, _assetFields);
    _rejectForbiddenFields(json, const {
      'source_file',
      'notes',
      'hard_block',
      'sensitivity_source',
    });
    final assetId = _string(json['asset_id'], 'asset_id');
    if (!RegExp(r'^chr_\d{3}$').hasMatch(assetId)) {
      throw FormatException('invalid asset_id: $assetId');
    }
    final modes = _enumSet(
      json['allowed_modes'],
      StageContext.values,
      'allowed_modes',
    );
    if (modes.isEmpty) {
      throw const FormatException('allowed_modes must not be empty');
    }
    final states = <CoreState, PoolRole>{};
    final rawStates = json['states'];
    if (rawStates is Map<String, dynamic>) {
      for (final entry in rawStates.entries) {
        final state = parseEnum(CoreState.values, entry.key, 'states key');
        states[state] = parseEnum(PoolRole.values, entry.value, 'states value');
      }
    } else {
      throw const FormatException('states must be an object');
    }
    if (states.isEmpty) {
      throw const FormatException('states must not be empty');
    }
    final kindRaw = json['kind'];
    final qualityRaw = json['technical_quality'];
    final loopGrade = _string(json['loop_grade'], 'loop_grade');
    final loopQuality = _string(json['loop_quality'], 'loop_quality');
    if (loopQuality != 'seamless' && loopQuality != 'crossfade') {
      throw const FormatException('invalid loop_quality');
    }
    final delivery = parseEnum(Delivery.values, json['delivery'], 'delivery');
    final sensitivity = parseEnum(
      ContentSensitivity.values,
      json['content_sensitivity'],
      'content_sensitivity',
    );
    final expectedPrefix = delivery == Delivery.privateVault
        ? 'private_vault'
        : delivery.name;
    final path = _exactPath(
      json['path'],
      'path',
      assetId,
      expectedPrefix,
      '.mp4',
    );
    final poster = _exactPath(
      json['poster'],
      'poster',
      assetId,
      expectedPrefix,
      '.poster.jpg',
    );
    final posterBlur = _exactPath(
      json['poster_blur'],
      'poster_blur',
      assetId,
      expectedPrefix,
      '.blur.jpg',
    );
    final audioStreams = _integer(
      json['audio_streams'],
      'audio_streams',
      minimum: 0,
    );
    if (audioStreams != 0) {
      throw const FormatException('audio_streams must equal 0');
    }
    for (final field in [
      'subtitle_streams',
      'data_streams',
      'attached_picture_streams',
    ]) {
      if (json[field] != null &&
          _integer(json[field], field, minimum: 0) != 0) {
        throw FormatException('$field must equal 0');
      }
    }
    if (json['delivery_class'] != null &&
        json['delivery_class'] != json['delivery']) {
      throw const FormatException('delivery_class must match delivery');
    }
    return CharacterAsset(
      assetId: assetId,
      delivery: delivery,
      contentSensitivity: sensitivity,
      allowedModes: modes,
      technicalQuality: parseEnum(
        TechnicalQuality.values,
        qualityRaw,
        'technical_quality',
      ),
      reviewFlag: _boolean(json['review_flag'], 'review_flag'),
      excludedByDefault: _boolean(
        json['excluded_by_default'],
        'excluded_by_default',
      ),
      states: Map.unmodifiable(states),
      cues: Set.unmodifiable(
        _strings(json['cues'] ?? const <Object>[], 'cues'),
      ),
      kind: parseEnum(PlaybackKind.values, kindRaw, 'kind'),
      loopGrade: parseEnum(LoopGrade.values, loopGrade, 'loop_grade'),
      loopQuality: loopQuality,
      weight: _number(json['weight'], 'weight', minimum: 0.05, maximum: 10),
      path: path,
      poster: poster,
      posterBlur: posterBlur,
      durationMs: _integer(
        json['duration_ms'],
        'duration_ms',
        minimum: 1,
        maximum: 60000,
      ),
      width: _integer(json['width'], 'width', minimum: 1, maximum: 1280),
      height: _integer(json['height'], 'height', minimum: 1, maximum: 1280),
      renderMode: _renderMode(json['render_mode']),
      focalX: _number(json['focal_x'], 'focal_x', minimum: 0, maximum: 1),
      focalY: _number(json['focal_y'], 'focal_y', minimum: 0, maximum: 1),
      intensityTags: _enumSet(
        json['intensity_tags'] ?? const <Object>[],
        Intensity.values,
        'intensity_tags',
      ),
      audioStreams: audioStreams,
      sha256: _sha256(json['sha256']),
      bytes: _integer(json['bytes'], 'bytes', minimum: 1),
    );
  }

  CueDefinition _cue(Map<String, dynamic> json) {
    _requireKnownFields(json, _cueFields);
    final modes = _enumSet(
      json['allowed_modes'],
      StageContext.values,
      'cue.allowed_modes',
    );
    if (modes.isEmpty) throw const FormatException('cue.allowed_modes empty');
    return CueDefinition(
      cue: _cueName(json['cue']),
      allowedModes: modes,
      cooldownSeconds: _integer(json['cooldown_s'], 'cooldown_s', minimum: 0),
      allowedInQuietHours: _boolean(
        json['allowed_in_quiet_hours'],
        'allowed_in_quiet_hours',
      ),
      llmSelectable: _boolean(json['llm_selectable'], 'llm_selectable'),
    );
  }

  void _requireKnownFields(Map<String, dynamic> json, Set<String> allowed) {
    final unknown = json.keys.where((key) => !allowed.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException('unknown manifest fields: ${unknown.join(',')}');
    }
  }

  String _exactPath(
    Object? raw,
    String field,
    String assetId,
    String prefix,
    String suffix,
  ) {
    final value = _string(raw, field);
    if (value.contains('\\') ||
        value.contains(':') ||
        value.startsWith('/') ||
        value
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw FormatException('unsafe $field for $assetId');
    }
    if (value != '$prefix/$assetId$suffix') {
      throw FormatException('invalid $field for $assetId');
    }
    return value;
  }

  void _validateManifestAssociation(ManifestKind kind, CharacterAsset asset) {
    switch (kind) {
      case ManifestKind.bundle:
        if (asset.delivery != Delivery.bundle ||
            asset.contentSensitivity != ContentSensitivity.normal ||
            (asset.allowedModes.length == 1 &&
                asset.allowedModes.contains(StageContext.private))) {
          throw const FormatException('bundle manifest invariant violated');
        }
      case ManifestKind.vault:
        final normalMode = asset.allowedModes.any(
          (mode) => mode != StageContext.private,
        );
        if (asset.delivery != Delivery.vault ||
            asset.contentSensitivity == ContentSensitivity.normal ||
            !normalMode) {
          throw const FormatException('vault manifest invariant violated');
        }
      case ManifestKind.privateVault:
        if (asset.delivery != Delivery.privateVault ||
            asset.allowedModes.length != 1 ||
            !asset.allowedModes.contains(StageContext.private)) {
          throw const FormatException(
            'private_vault manifest invariant violated',
          );
        }
    }
  }

  void _rejectForbiddenFields(Map<String, dynamic> json, Set<String> fields) {
    final found = json.keys.where(fields.contains).toList();
    if (found.isNotEmpty) {
      throw FormatException('forbidden manifest fields: ${found.join(',')}');
    }
  }

  String _renderMode(Object? raw) {
    final value = _string(raw, 'render_mode');
    if (value != 'cover' && value != 'contain_blur') {
      throw FormatException('invalid render_mode: $value');
    }
    return value;
  }

  String _sha256(Object? raw) {
    final value = _string(raw, 'sha256');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw const FormatException('invalid sha256');
    }
    return value;
  }

  String _cueName(Object? raw) {
    final value = _string(raw, 'cue');
    if (!RegExp(r'^[a-z][a-z0-9_]{1,31}$').hasMatch(value)) {
      throw FormatException('invalid cue: $value');
    }
    return value;
  }

  Set<T> _enumSet<T extends Enum>(
    Object? raw,
    Iterable<T> values,
    String field,
  ) {
    if (raw is! List) {
      throw FormatException('$field must be an array');
    }
    return Set.unmodifiable(
      raw.map((value) => parseEnum(values, value, field)),
    );
  }

  List<String> _strings(Object? raw, String field) {
    if (raw is! List || raw.any((value) => value is! String)) {
      throw FormatException('$field must be a string array');
    }
    return raw.cast<String>();
  }

  String _string(Object? raw, String field) {
    if (raw is! String || raw.isEmpty) {
      throw FormatException('$field must be a non-empty string');
    }
    return raw;
  }

  bool _boolean(Object? raw, String field) {
    if (raw is! bool) {
      throw FormatException('$field must be a boolean');
    }
    return raw;
  }

  int _integer(Object? raw, String field, {int? minimum, int? maximum}) {
    if (raw is! num || raw.toInt() != raw) {
      throw FormatException('$field must be an integer');
    }
    final value = raw.toInt();
    if (minimum != null && value < minimum) {
      throw FormatException('$field is below minimum');
    }
    if (maximum != null && value > maximum) {
      throw FormatException('$field is above maximum');
    }
    return value;
  }

  double _number(
    Object? raw,
    String field, {
    required double minimum,
    required double maximum,
  }) {
    if (raw is! num || !raw.toDouble().isFinite) {
      throw FormatException('$field must be a finite number');
    }
    final value = raw.toDouble();
    if (value < minimum || value > maximum) {
      throw FormatException('$field is outside range');
    }
    return value;
  }
}
