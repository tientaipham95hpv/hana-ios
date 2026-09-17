import '../character/manifest/manifest_loader.dart';
import '../character/manifest/manifest_models.dart';

class DemoManifestFactory {
  const DemoManifestFactory._();

  static CharacterManifest create() {
    const suggestive = <int>{
      1,
      2,
      6,
      9,
      10,
      11,
      18,
      19,
      20,
      22,
      29,
      30,
      33,
      35,
      40,
      42,
      43,
    };
    const review = <int>{
      1,
      4,
      5,
      9,
      10,
      12,
      16,
      19,
      20,
      21,
      23,
      24,
      25,
      28,
      29,
      31,
      33,
      34,
      36,
    };
    const poor = <int>{11, 22};
    const loops = <int>{13, 15, 16, 18, 23, 26, 29, 41};
    const grades = <int, String>{
      13: 'B',
      15: 'B',
      16: 'B',
      18: 'B',
      23: 'B',
      26: 'A',
      29: 'B',
      41: 'A',
    };
    const stateOverrides = <int, Map<String, String>>{
      2: {'talking': 'primary'},
      6: {'happy': 'primary'},
      8: {'sleep': 'primary'},
      12: {'surprised': 'primary'},
      17: {'concerned': 'primary'},
      18: {'idle': 'primary', 'listening': 'shared', 'talking': 'shared'},
      26: {'idle': 'primary', 'listening': 'shared', 'thinking': 'shared'},
      27: {'working': 'primary'},
      30: {'thinking': 'primary'},
      37: {'shy': 'primary'},
      39: {'working': 'primary'},
      40: {'shy': 'primary'},
      41: {'idle': 'primary', 'listening': 'shared', 'thinking': 'shared'},
      42: {'happy': 'primary'},
      43: {'happy': 'shared'},
    };
    final assets = <Map<String, Object?>>[];
    for (var index = 1; index <= 43; index += 1) {
      final id = 'chr_${index.toString().padLeft(3, '0')}';
      final isSuggestive = suggestive.contains(index);
      final isPoor = poor.contains(index);
      final isLoop = loops.contains(index);
      assets.add({
        'asset_id': id,
        'delivery': 'vault',
        'content_sensitivity': isSuggestive ? 'suggestive' : 'private',
        'allowed_modes': isSuggestive
            ? ['daily', 'assistant', 'relationship', 'private']
            : ['relationship', 'private'],
        'technical_quality': isPoor ? 'poor' : 'good',
        'review_flag': review.contains(index),
        'excluded_by_default': isPoor,
        'states': stateOverrides[index] ?? {'idle': 'shared'},
        'cues': index == 43
            ? ['greeting']
            : index == 7
            ? ['playful']
            : <String>[],
        'kind': isLoop ? 'loop' : 'oneshot',
        'loop_quality': grades[index] == 'A' ? 'seamless' : 'crossfade',
        'loop_grade': grades[index] ?? (isPoor ? 'D' : 'C'),
        'path': 'vault/$id.mp4',
        'poster': 'vault/$id.poster.jpg',
        'poster_blur': 'vault/$id.blur.jpg',
        'duration_ms': isSuggestive ? 6042 : 10042,
        'width': isSuggestive ? 544 : 720,
        'height': isSuggestive ? 544 : 1280,
        'render_mode': isSuggestive ? 'contain_blur' : 'cover',
        'focal_x': 0.5,
        'focal_y': 0.5,
        'intensity_tags': <String>[],
        'weight': isPoor
            ? 0.2
            : review.contains(index)
            ? 0.5
            : 1.0,
        'audio_streams': 0,
        'sha256': index.toRadixString(16).padLeft(64, '0'),
        'bytes': 1000 + index,
      });
    }
    return const CharacterManifestLoader().parse({
      'schema_version': 2,
      'manifest_kind': 'vault',
      'manifest_version': 'phase5-demo-v1',
      'cue_registry': [
        {
          'cue': 'greeting',
          'allowed_modes': ['daily', 'relationship', 'private'],
          'cooldown_s': 600,
          'allowed_in_quiet_hours': false,
          'llm_selectable': false,
        },
        {
          'cue': 'playful',
          'allowed_modes': ['relationship', 'private'],
          'cooldown_s': 600,
          'allowed_in_quiet_hours': false,
          'llm_selectable': false,
        },
      ],
      'assets': assets,
    });
  }
}
