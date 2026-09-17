import '../character/engine/character_cue.dart';

class ChatMessageModel {
  const ChatMessageModel({
    required this.id,
    required this.role,
    required this.text,
    required this.turnId,
    this.cue,
    this.pending = false,
    this.failed = false,
  });

  factory ChatMessageModel.fromJson(Map<String, dynamic> json) =>
      ChatMessageModel(
        id: json['id']?.toString() ?? '',
        role: json['role']?.toString() ?? 'assistant',
        text: json['text']?.toString() ?? '',
        turnId: json['turn_id']?.toString(),
        cue: json['character_cue'] is Map<String, dynamic>
            ? CharacterCue.fromJson(
                json['character_cue'] as Map<String, dynamic>,
              )
            : null,
      );

  final String id;
  final String role;
  final String text;
  final String? turnId;
  final CharacterCue? cue;
  final bool pending;
  final bool failed;
}

class AcceptedTurn {
  const AcceptedTurn({required this.turnId, required this.eventsUrl});
  factory AcceptedTurn.fromJson(Map<String, dynamic> json) => AcceptedTurn(
    turnId: json['turn_id'] as String,
    eventsUrl: json['events_url'] as String,
  );
  final String turnId;
  final String eventsUrl;
}

class TurnEventModel {
  const TurnEventModel({
    required this.id,
    required this.type,
    required this.turnId,
    required this.seq,
    required this.payload,
  });
  final String id;
  final String type;
  final String turnId;
  final int seq;
  final Map<String, dynamic> payload;
}

class TtsSegmentModel {
  const TtsSegmentModel({
    required this.turnId,
    required this.index,
    required this.mediaUrl,
    required this.mime,
    required this.isLast,
  });

  factory TtsSegmentModel.fromEvent(TurnEventModel event) => TtsSegmentModel(
    turnId: event.turnId,
    index: event.payload['index'] as int,
    mediaUrl: event.payload['media_url'] as String,
    mime: event.payload['mime']?.toString() ?? 'audio/mpeg',
    isLast: event.payload['is_last'] == true,
  );

  factory TtsSegmentModel.fromJson(String turnId, Map<String, dynamic> json) =>
      TtsSegmentModel(
        turnId: turnId,
        index: json['index'] as int,
        mediaUrl: json['media_url'] as String,
        mime: json['mime']?.toString() ?? 'audio/mpeg',
        isLast: json['is_last'] == true,
      );

  final String turnId;
  final int index;
  final String mediaUrl;
  final String mime;
  final bool isLast;
}
