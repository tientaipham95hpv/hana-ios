import 'dart:convert';
import 'dart:io';

const runtimeManifestFields = {
  'schema_version',
  'manifest_kind',
  'manifest_version',
  'generated_at',
  'cue_registry',
  'assets',
};

const runtimeAssetFields = {
  'asset_id',
  'delivery',
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

Map<String, dynamic> sanitizePhase4Manifest(Map<String, dynamic> decoded) {
  if (decoded['manifest_kind'] != 'master' ||
      (decoded['assets'] as List).length != 43 ||
      (decoded['assets'] as List).any(
        (asset) => asset['delivery'] != 'vault',
      )) {
    throw StateError('Unexpected Phase 4 master manifest');
  }
  return <String, dynamic>{
    for (final entry in decoded.entries)
      if (runtimeManifestFields.contains(entry.key)) entry.key: entry.value,
    'manifest_kind': 'vault',
    'assets': [
      for (final raw in decoded['assets'] as List)
        <String, dynamic>{
          for (final entry in (raw as Map<String, dynamic>).entries)
            if (runtimeAssetFields.contains(entry.key)) entry.key: entry.value,
        },
    ],
  };
}

void main() {
  final source = File('../../assets_processed/hana/character_manifest.json');
  final target = File('assets/character/character_manifest.json');
  final decoded = sanitizePhase4Manifest(
    jsonDecode(source.readAsStringSync()) as Map<String, dynamic>,
  );
  target.parent.createSync(recursive: true);
  target.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(decoded)}\n',
  );
}
