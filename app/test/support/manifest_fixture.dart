Map<String, Object?> validAsset(
  int index, [
  Map<String, Object?> overrides = const {},
]) {
  final id = 'chr_${index.toString().padLeft(3, '0')}';
  return {
    'asset_id': id,
    'delivery': 'vault',
    'content_sensitivity': 'suggestive',
    'allowed_modes': ['daily', 'assistant', 'relationship', 'private'],
    'technical_quality': 'good',
    'review_flag': false,
    'excluded_by_default': false,
    'states': {'idle': 'primary'},
    'cues': <String>[],
    'kind': 'loop',
    'loop_grade': 'A',
    'loop_quality': 'seamless',
    'weight': 1.0,
    'path': 'vault/$id.mp4',
    'poster': 'vault/$id.poster.jpg',
    'poster_blur': 'vault/$id.blur.jpg',
    'duration_ms': 1000,
    'width': 720,
    'height': 1280,
    'render_mode': 'cover',
    'focal_x': 0.5,
    'focal_y': 0.5,
    'intensity_tags': <String>[],
    'audio_streams': 0,
    'sha256': index.toRadixString(16).padLeft(64, '0'),
    'bytes': 1000,
    ...overrides,
  };
}

Map<String, Object?> validManifest({int count = 1}) => {
  'schema_version': 2,
  'manifest_kind': 'vault',
  'manifest_version': 'test-v1',
  'assets': [for (var index = 1; index <= count; index++) validAsset(index)],
  'cue_registry': <Object>[],
};
