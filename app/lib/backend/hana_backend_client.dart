import 'package:dio/dio.dart';

import 'sse_client.dart';
import 'turn_models.dart';

abstract interface class BackendTurnClient {
  Future<AcceptedTurn> createTextTurn({
    required String clientId,
    required String text,
    required bool speak,
    required bool supersede,
    String responseMode = 'AUTO',
    bool autoPlayVoice = true,
    String semanticMode = 'daily',
  });

  Future<AcceptedTurn> createVoiceTurn({
    required String clientId,
    required String path,
    required int durationMs,
    required bool speak,
    required bool supersede,
    String responseMode = 'AUTO',
    bool autoPlayVoice = true,
    String semanticMode = 'daily',
  });

  Stream<TurnEventModel> events(AcceptedTurn turn);
  Future<List<int>> audioBytes(String url);
  Future<void> cancel(String turnId);
  Future<Map<String, dynamic>> state(String turnId);
  Future<List<TtsSegmentModel>> speech(String turnId);
}

class HanaBackendClient implements BackendTurnClient {
  HanaBackendClient({required this.dio});

  final Dio dio;
  late final HanaSseClient sse = HanaSseClient(dio);

  @override
  Future<AcceptedTurn> createTextTurn({
    required String clientId,
    required String text,
    required bool speak,
    required bool supersede,
    String responseMode = 'AUTO',
    bool autoPlayVoice = true,
    String semanticMode = 'daily',
  }) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/v1/turns',
      data: {
        'client_id': clientId,
        'text': text,
        'response_mode': responseMode,
        'auto_play_voice': autoPlayVoice,
        'semantic_mode': semanticMode,
        // Kept only for backward-compatible callers. New clients derive the
        // same value from response_mode and auto_play_voice server-side.
        'speak': speak,
        'supersede': supersede,
      },
    );
    return AcceptedTurn.fromJson(response.data!);
  }

  @override
  Future<AcceptedTurn> createVoiceTurn({
    required String clientId,
    required String path,
    required int durationMs,
    required bool speak,
    required bool supersede,
    String responseMode = 'AUTO',
    bool autoPlayVoice = true,
    String semanticMode = 'daily',
  }) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/v1/turns/voice',
      data: FormData.fromMap({
        'client_id': clientId,
        'duration_ms': durationMs,
        'response_mode': responseMode,
        'auto_play_voice': autoPlayVoice,
        'semantic_mode': semanticMode,
        // iOS native speech explicitly disables server synthesis while
        // preserving the user's response mode for persistence/audit.
        'speak': speak,
        'supersede': supersede,
        'audio': await MultipartFile.fromFile(path, filename: '$clientId.m4a'),
      }),
    );
    return AcceptedTurn.fromJson(response.data!);
  }

  @override
  Stream<TurnEventModel> events(AcceptedTurn turn) =>
      sse.turnEvents(turn.eventsUrl);

  @override
  Future<List<int>> audioBytes(String url) async {
    final response = await dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    return response.data!;
  }

  @override
  Future<void> cancel(String turnId) async {
    await dio.post<void>('/v1/turns/$turnId/cancel');
  }

  @override
  Future<Map<String, dynamic>> state(String turnId) async {
    final response = await dio.get<Map<String, dynamic>>('/v1/turns/$turnId');
    return response.data!;
  }

  @override
  Future<List<TtsSegmentModel>> speech(String turnId) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/v1/turns/$turnId/speech',
    );
    final raw = response.data?['segments'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map(
          (item) =>
              TtsSegmentModel.fromJson(turnId, Map<String, dynamic>.from(item)),
        )
        .toList();
  }
}
