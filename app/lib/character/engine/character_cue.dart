import '../manifest/manifest_models.dart';

class CharacterCue {
  const CharacterCue({
    required this.emotion,
    required this.intensity,
    this.specialCue,
    this.stageContext,
  });

  factory CharacterCue.fromJson(Map<String, dynamic> json) {
    T safe<T extends Enum>(Iterable<T> values, Object? raw, T fallback) {
      if (raw is! String) return fallback;
      return values.cast<T?>().firstWhere(
            (value) => value?.name == raw,
            orElse: () => null,
          ) ??
          fallback;
    }

    final special = json['special_cue'];
    final context = json['stage_context'];
    return CharacterCue(
      emotion: safe(Emotion.values, json['emotion'], Emotion.neutral),
      intensity: safe(Intensity.values, json['intensity'], Intensity.low),
      specialCue:
          special is String &&
              RegExp(r'^[a-z][a-z0-9_]{1,31}$').hasMatch(special)
          ? special
          : null,
      stageContext: context is String
          ? StageContext.values.cast<StageContext?>().firstWhere(
              (value) => value?.name == context,
              orElse: () => null,
            )
          : null,
    );
  }

  final Emotion emotion;
  final Intensity intensity;
  final String? specialCue;
  final StageContext? stageContext;
}
