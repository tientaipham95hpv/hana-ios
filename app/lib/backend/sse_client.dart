import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'turn_models.dart';

class SseProtocolException implements Exception {
  const SseProtocolException(this.message);
  final String message;
}

class HanaSseClient {
  HanaSseClient(this.dio);
  final Dio dio;

  Stream<TurnEventModel> turnEvents(String url) async* {
    String? lastEventId;
    var lastSeq = 0;
    const delays = [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
    ];
    var attempt = 0;
    while (true) {
      try {
        final response = await dio.get<ResponseBody>(
          url,
          options: Options(
            responseType: ResponseType.stream,
            headers: {
              'Accept': 'text/event-stream',
              'Last-Event-ID': ?lastEventId,
            },
          ),
        );
        final lines = response.data!.stream
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        String? id;
        String? type;
        final data = StringBuffer();
        await for (final line in lines) {
          if (line.isEmpty) {
            if (type != null && data.isNotEmpty) {
              final decoded = jsonDecode(data.toString());
              if (decoded is! Map<String, dynamic>) {
                throw const SseProtocolException('SSE data must be an object');
              }
              final seq = decoded['seq'];
              final turnId = decoded['turn_id'];
              if (seq is! int || turnId is! String) {
                throw const SseProtocolException(
                  'SSE event is missing seq/turn_id',
                );
              }
              lastEventId = id ?? lastEventId;
              // Redis expiry produces a REST-backed terminal snapshot whose
              // sequence restarts at 1. It is authoritative after reconnect.
              final logicalSeq = (id?.startsWith('snapshot-') ?? false)
                  ? (seq > lastSeq ? seq : lastSeq + 1)
                  : seq;
              if (logicalSeq > lastSeq) {
                lastSeq = logicalSeq;
                final event = TurnEventModel(
                  id: id ?? '',
                  type: type,
                  turnId: turnId,
                  seq: logicalSeq,
                  payload: decoded,
                );
                yield event;
                if (type == 'turn.completed' ||
                    type == 'turn.failed' ||
                    type == 'turn.cancelled') {
                  return;
                }
              }
            }
            id = null;
            type = null;
            data.clear();
            continue;
          }
          if (line.startsWith(':')) continue;
          final colon = line.indexOf(':');
          if (colon < 0) continue;
          final field = line.substring(0, colon);
          final value = line.substring(colon + 1).trimLeft();
          switch (field) {
            case 'id':
              id = value;
            case 'event':
              type = value;
            case 'data':
              if (data.isNotEmpty) data.write('\n');
              data.write(value);
          }
        }
        throw DioException.connectionError(
          requestOptions: RequestOptions(path: url),
          reason: 'SSE disconnected before terminal event',
        );
      } on SseProtocolException {
        rethrow;
      } on DioException {
        if (attempt >= delays.length) rethrow;
        await Future<void>.delayed(delays[attempt++]);
      }
    }
  }
}
