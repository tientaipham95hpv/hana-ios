import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hana_app/app/character_runtime_controller.dart';
import 'package:hana_app/backend/hana_backend_client.dart';
import 'package:hana_app/backend/sse_client.dart';
import 'package:hana_app/backend/turn_models.dart';
import 'package:hana_app/character/engine/clock.dart';
import 'package:hana_app/character/engine/engine_event.dart';
import 'package:hana_app/character/engine/timer_driver.dart';
import 'package:hana_app/character/manifest/manifest_models.dart';
import 'package:hana_app/character/policy/owner_policy.dart';
import 'package:hana_app/character/stage/asset_repository.dart';
import 'package:hana_app/chat/chat_controller.dart';
import 'package:hana_app/voice/tts_queue.dart';
import 'package:hana_app/voice/voice_preferences.dart';
import 'package:hana_app/voice/voice_recorder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real API adapter sends canonical text turn request', () async {
    late RequestOptions seen;
    final dio = Dio(BaseOptions(baseUrl: 'http://hana.test'))
      ..httpClientAdapter = _Adapter((options, _) {
        seen = options;
        return _jsonResponse({
          'turn_id': 'turn-a',
          'events_url': '/v1/turns/turn-a/events',
        });
      });
    final accepted = await HanaBackendClient(dio: dio).createTextTurn(
      clientId: 'client-a',
      text: 'xin chào',
      speak: true,
      supersede: false,
    );

    expect(seen.method, 'POST');
    expect(seen.path, '/v1/turns');
    expect(seen.data, containsPair('client_id', 'client-a'));
    expect(seen.data, containsPair('text', 'xin chào'));
    expect(accepted.turnId, 'turn-a');
  });

  test(
    'SSE reconnect sends Last-Event-ID and suppresses duplicate seq',
    () async {
      var request = 0;
      final dio = Dio(BaseOptions(baseUrl: 'http://hana.test'))
        ..httpClientAdapter = _Adapter((options, _) {
          request++;
          if (request == 1) {
            expect(options.headers['Last-Event-ID'], isNull);
            return _sseResponse(_sse('1-0', 'turn.progress', 1));
          }
          expect(options.headers['Last-Event-ID'], '1-0');
          return _sseResponse(
            '${_sse('1-0', 'turn.progress', 1)}'
            '${_sse('2-0', 'turn.completed', 2)}',
          );
        });

      final events = await HanaSseClient(dio).turnEvents('/events').toList();
      expect(events.map((event) => event.seq), [1, 2]);
      expect(request, 2);
    },
  );

  test('SSE terminal snapshot after stream expiry is not discarded', () async {
    var request = 0;
    final dio = Dio(BaseOptions(baseUrl: 'http://hana.test'))
      ..httpClientAdapter = _Adapter((options, _) {
        request++;
        if (request == 1) return _sseResponse(_sse('1-0', 'turn.progress', 9));
        expect(options.headers['Last-Event-ID'], '1-0');
        return _sseResponse(_sse('snapshot-1', 'turn.completed', 1));
      });
    final events = await HanaSseClient(dio).turnEvents('/events').toList();
    expect(events.map((event) => event.seq), [9, 10]);
    expect(request, 2);
  });

  test('malformed SSE event fails closed without logical processing', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://hana.test'))
      ..httpClientAdapter = _Adapter(
        (_, _) => _sseResponse(
          'id: 1-0\nevent: reply.ready\ndata: {"turn_id":"a"}\n\n',
        ),
      );

    await expectLater(
      HanaSseClient(dio).turnEvents('/events').toList(),
      throwsA(isA<SseProtocolException>()),
    );
  });

  group('ChatController', () {
    late _FakeBackend backend;
    late _FakeTts tts;
    late _FakeRecorder recorder;
    late FakeClock clock;
    late FakeTimerDriver timers;
    late CharacterRuntimeController runtime;
    late ChatController chat;
    late VoicePreferences preferences;

    setUp(() {
      backend = _FakeBackend();
      tts = _FakeTts();
      recorder = _FakeRecorder();
      clock = FakeClock(DateTime.utc(2026, 1, 1));
      timers = FakeTimerDriver(clock);
      runtime = CharacterRuntimeController(
        manifest: CharacterManifest.empty(),
        ownerPolicy: const OwnerPolicy(),
        repository: const MockVaultAssetRepository(),
        clock: clock,
        timerDriver: timers,
      );
      preferences = VoicePreferences(store: MemoryVoicePreferenceStore());
      chat = ChatController(
        client: backend,
        runtime: runtime,
        tts: tts,
        recorder: recorder,
        preferences: preferences,
        configureAudio: false,
      );
    });

    tearDown(() {
      chat.dispose();
      runtime.dispose();
      backend.dispose();
    });

    test(
      'text flow deduplicates duplicate and rejects wrong-turn event',
      () async {
        await chat.sendText('Chào Hana', speak: false);
        final turn = chat.activeTurnId!;
        backend.emit(turn, _reply(turn, seq: 1, id: 'reply-1'));
        backend.emit(turn, _reply(turn, seq: 1, id: 'reply-1'));
        backend.emit(turn, _reply('stale-turn', seq: 2, id: 'stale'));
        await _flush();

        expect(
          chat.messages.where((message) => message.role == 'assistant'),
          hasLength(1),
        );
        expect(chat.messages.last.text, 'Em đây.');
      },
    );

    test('AUTO typed turn is text-only while PTT requests voice', () async {
      await chat.sendText('Chào Hana');
      expect(backend.lastTextSpeak, false);
      expect(backend.lastResponseMode, 'AUTO');
      final first = chat.activeTurnId!;
      backend.emit(first, _event(first, 'turn.completed', 1));
      await _flush();
      await chat.beginPtt();
      await chat.endPtt();
      expect(backend.lastVoiceAutoPlay, true);
      expect(backend.lastResponseMode, 'AUTO');
    });

    test('iOS native PTT keeps server TTS off and speaks reply text', () async {
      tts.native = true;
      await chat.beginPtt();
      await chat.endPtt();
      final turn = chat.activeTurnId!;
      expect(backend.lastVoiceSpeak, false);
      backend.emit(turn, _reply(turn, seq: 1, id: 'native-reply'));
      backend.emit(turn, _event(turn, 'turn.completed', 2));
      await _flush();

      expect(tts.utterances, [(turn, 'Em đây.')]);
      expect(tts.segments, isEmpty);
      tts.onStarted?.call(turn);
      timers.elapse(const Duration(milliseconds: 600));
      await _flush();
      expect(runtime.state.activity, CoreState.talking);
      tts.onFinished?.call(turn);
      expect(runtime.state.activity, isNot(CoreState.talking));
    });

    test(
      'native speech interruption cannot leave Character Engine talking',
      () async {
        tts.native = true;
        await preferences.setResponseMode(VoiceResponseMode.voiceReply);
        await chat.sendText('Nói bằng giọng');
        final turn = chat.activeTurnId!;
        expect(backend.lastTextSpeak, false);
        backend.emit(turn, _reply(turn, seq: 1, id: 'native-interrupted'));
        await _flush();
        tts.onStarted?.call(turn);
        timers.elapse(const Duration(milliseconds: 600));
        await _flush();
        expect(runtime.state.activity, CoreState.talking);
        tts.onCancelled?.call(turn);
        expect(runtime.state.activity, isNot(CoreState.talking));
      },
    );

    test('background before native didStart settles requested turn', () async {
      tts.native = true;
      await preferences.setResponseMode(VoiceResponseMode.voiceReply);
      await chat.sendText('A');
      final turn = chat.activeTurnId!;
      backend.emit(turn, _reply(turn, seq: 1, id: 'native-before-start'));
      await _flush();
      expect(tts.utterances, isNotEmpty);

      chat.appPaused();
      await _flush();
      expect(runtime.state.activity, isNot(CoreState.thinking));
      expect(runtime.state.activity, isNot(CoreState.talking));
    });

    test(
      'Text only PTT stays silent and manual speaker can play reply',
      () async {
        await preferences.setResponseMode(VoiceResponseMode.textOnly);
        await chat.beginPtt();
        await chat.endPtt();
        expect(backend.lastResponseMode, 'TEXT_ONLY');
        final turn = chat.activeTurnId!;
        backend.emit(turn, _reply(turn, seq: 1, id: 'reply-voice'));
        backend.emit(turn, _event(turn, 'turn.completed', 2));
        await _flush();
        expect(runtime.state.activity, isNot(CoreState.talking));
        await chat.playMessage(chat.messages.last);
        expect(tts.segments, hasLength(1));
        expect(tts.segments.single.turnId, turn);
        tts.onStarted?.call(turn);
        timers.elapse(const Duration(milliseconds: 600));
        await _flush();
        expect(runtime.state.activity, CoreState.talking);
        tts.onFinished?.call(turn);
        expect(runtime.state.activity, isNot(CoreState.talking));
      },
    );

    test(
      'iOS manual speaker uses reply text without backend speech API',
      () async {
        tts.native = true;
        await preferences.setResponseMode(VoiceResponseMode.textOnly);
        await chat.sendText('Chỉ chữ');
        final turn = chat.activeTurnId!;
        backend.emit(turn, _reply(turn, seq: 1, id: 'manual-native'));
        backend.emit(turn, _event(turn, 'turn.completed', 2));
        await _flush();

        await chat.playMessage(chat.messages.last);
        expect(backend.speechRequests, 0);
        expect(tts.utterances, [(turn, 'Em đây.')]);
      },
    );

    test('new turn correlation prevents stale A event mutating B', () async {
      await chat.sendText('A');
      final a = chat.activeTurnId!;
      await chat.sendText('B');
      final b = chat.activeTurnId!;
      expect(b, isNot(a));

      backend.emit(b, _reply(a, seq: 99, id: 'stale-a'));
      backend.emit(b, _reply(b, seq: 1, id: 'reply-b'));
      await _flush();
      expect(chat.messages.any((message) => message.id == 'stale-a'), isFalse);
      expect(chat.messages.any((message) => message.id == 'reply-b'), isTrue);
    });

    test(
      'TTS segment is processed in order before terminal SSE event',
      () async {
        await chat.sendText('Nói đi');
        final turn = chat.activeTurnId!;
        final bytes = Completer<List<int>>();
        backend.pendingAudio = bytes;
        backend.emit(turn, _tts(turn, seq: 1));
        backend.emit(turn, _event(turn, 'turn.completed', 2));
        await _flush();
        expect(chat.activeTurnId, turn);

        bytes.complete([1, 2, 3]);
        await _flush();
        expect(tts.segments, hasLength(1));
        expect(tts.segments.single.turnId, turn);
        expect(chat.activeTurnId, isNull);
      },
    );

    test('barge-in cancels old turn and ignores its later audio', () async {
      await chat.sendText('A');
      final a = chat.activeTurnId!;
      await chat.beginPtt();
      expect(chat.recording, isTrue);
      expect(backend.cancelled, contains(a));
      expect(runtime.state.activity, CoreState.listening);

      backend.emit(a, _tts(a, seq: 1));
      await _flush();
      expect(tts.segments, isEmpty);
    });

    test('denied iOS microphone leaves text chat available', () async {
      recorder.permission = MicrophonePermissionState.denied;
      await chat.beginPtt();
      expect(chat.recording, false);
      expect(backend.voiceRequests, 0);
      expect(chat.microphonePermission, MicrophonePermissionState.denied);

      await chat.sendText('Text vẫn chạy', speak: false);
      expect(chat.activeTurnId, isNotNull);
    });

    test('native recorder interruption settles listening state', () async {
      await chat.beginPtt();
      expect(runtime.state.activity, CoreState.listening);
      recorder.onInterrupted?.call();
      expect(chat.recording, false);
      expect(runtime.state.activity, isNot(CoreState.listening));
    });

    test('voice PTT flows through transcript, reply, and completion', () async {
      await chat.beginPtt();
      await chat.endPtt();
      final turn = chat.activeTurnId!;
      expect(backend.voiceRequests, 1);
      backend.emit(
        turn,
        TurnEventModel(
          id: '1-0',
          type: 'transcript.final',
          turnId: turn,
          seq: 1,
          payload: {
            'user_message': {
              'id': 'voice-user',
              'role': 'user',
              'text': 'xin chào',
              'turn_id': turn,
            },
          },
        ),
      );
      backend.emit(turn, _reply(turn, seq: 2, id: 'voice-reply'));
      backend.emit(turn, _event(turn, 'turn.completed', 3));
      await _flush();
      expect(
        chat.messages.map((message) => message.id),
        containsAll(['voice-user', 'voice-reply']),
      );
      expect(recorder.deleted, contains('voice.m4a'));
    });

    test('cancel is idempotent locally and late terminal is stale', () async {
      await chat.sendText('Hủy giúp');
      final turn = chat.activeTurnId!;
      await chat.cancelTurn();
      backend.emit(turn, _event(turn, 'turn.completed', 9));
      await _flush();
      expect(backend.cancelled, [turn]);
      expect(chat.activeTurnId, isNull);
      expect(runtime.state.currentTurnId, isNull);
    });

    test('paused terminal failure converges and resume is not stuck', () async {
      await chat.sendText('A');
      final turn = chat.activeTurnId!;
      runtime.dispatch(const AppPaused());
      backend.emit(turn, _event(turn, 'turn.failed', 1));
      await _flush();
      expect(runtime.state.currentTurnId, isNull);
      runtime.dispatch(const AppResumed());
      expect(runtime.state.activity, isNot(CoreState.thinking));
    });

    test(
      'SSE failure recovers completed snapshot and settles thinking',
      () async {
        await chat.sendText('A');
        final turn = chat.activeTurnId!;
        backend.snapshots[turn] = {
          'state': 'completed',
          'assistant_message': _reply(
            turn,
            seq: 1,
            id: 'recovered',
          ).payload['assistant_message'],
        };
        backend.failStream(turn);
        await _flush();
        expect(chat.activeTurnId, isNull);
        expect(
          chat.messages.any((message) => message.id == 'recovered'),
          isTrue,
        );
        timers.elapse(const Duration(seconds: 2));
        expect(runtime.state.activity, isNot(CoreState.thinking));
      },
    );

    test('stale snapshot response cannot mutate a newer turn', () async {
      await chat.sendText('A');
      final a = chat.activeTurnId!;
      final delayed = Completer<Map<String, dynamic>>();
      backend.pendingState = delayed;
      backend.failStream(a);
      await _flush();
      await chat.sendText('B');
      final b = chat.activeTurnId!;
      delayed.complete({
        'state': 'completed',
        'assistant_message': _reply(
          a,
          seq: 1,
          id: 'stale-snapshot',
        ).payload['assistant_message'],
      });
      await _flush();
      expect(chat.activeTurnId, b);
      expect(
        chat.messages.any((message) => message.id == 'stale-snapshot'),
        isFalse,
      );
    });

    test(
      'voice upload failure converges from thinking and deletes audio',
      () async {
        backend.failNextVoice = true;
        await chat.beginPtt();
        await chat.endPtt();
        expect(runtime.state.activity, CoreState.concerned);
        expect(recorder.deleted, contains('voice.m4a'));
        expect(chat.activeTurnId, isNull);
      },
    );

    test(
      'network failure retains draft and idempotency key for retry',
      () async {
        backend.failNextText = true;
        await chat.sendText('Đừng mất nội dung');
        final retainedClient = chat.pendingClientId;
        expect(chat.pendingDraft, 'Đừng mất nội dung');
        expect(retainedClient, isNotNull);

        await chat.sendText('Đừng mất nội dung');
        expect(backend.textClientIds, hasLength(2));
        expect(backend.textClientIds.toSet(), {retainedClient});
      },
    );
  });
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

TurnEventModel _reply(String turn, {required int seq, required String id}) =>
    TurnEventModel(
      id: '$seq-0',
      type: 'reply.ready',
      turnId: turn,
      seq: seq,
      payload: {
        'assistant_message': {
          'id': id,
          'role': 'assistant',
          'text': 'Em đây.',
          'turn_id': turn,
          'character_cue': {'emotion': 'neutral', 'intensity': 'low'},
        },
      },
    );

TurnEventModel _tts(String turn, {required int seq}) => TurnEventModel(
  id: '$seq-0',
  type: 'tts.segment',
  turnId: turn,
  seq: seq,
  payload: {
    'index': 0,
    'media_url': '/v1/media/audio',
    'mime': 'audio/wav',
    'is_last': true,
  },
);

TurnEventModel _event(String turn, String type, int seq) => TurnEventModel(
  id: '$seq-0',
  type: type,
  turnId: turn,
  seq: seq,
  payload: const {},
);

String _sse(String id, String type, int seq) {
  final data = jsonEncode({'turn_id': 'turn-a', 'seq': seq});
  return 'id: $id\nevent: $type\ndata: $data\n\n';
}

ResponseBody _jsonResponse(Map<String, Object?> body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      202,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

ResponseBody _sseResponse(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/event-stream'],
  },
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final ResponseBody Function(RequestOptions, Stream<Uint8List>?) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options, requestStream);

  @override
  void close({bool force = false}) {}
}

class _FakeBackend implements BackendTurnClient {
  final _streams = <String, StreamController<TurnEventModel>>{};
  final cancelled = <String>[];
  final textClientIds = <String>[];
  var voiceRequests = 0;
  var speechRequests = 0;
  var _counter = 0;
  var failNextText = false;
  var failNextVoice = false;
  bool? lastTextSpeak;
  bool? lastVoiceSpeak;
  bool? lastVoiceAutoPlay;
  String? lastResponseMode;
  final snapshots = <String, Map<String, dynamic>>{};
  Completer<Map<String, dynamic>>? pendingState;
  Completer<List<int>>? pendingAudio;

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
    lastTextSpeak = speak;
    lastResponseMode = responseMode;
    textClientIds.add(clientId);
    if (failNextText) {
      failNextText = false;
      throw DioException.connectionError(
        requestOptions: RequestOptions(path: '/v1/turns'),
        reason: 'offline',
      );
    }
    return _accepted();
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
    lastVoiceSpeak = speak;
    lastVoiceAutoPlay = autoPlayVoice;
    lastResponseMode = responseMode;
    voiceRequests++;
    if (failNextVoice) throw StateError('offline');
    return _accepted();
  }

  AcceptedTurn _accepted() {
    final id = 'turn-${++_counter}';
    _streams[id] = StreamController<TurnEventModel>.broadcast();
    return AcceptedTurn(turnId: id, eventsUrl: '/events/$id');
  }

  @override
  Stream<TurnEventModel> events(AcceptedTurn turn) =>
      _streams[turn.turnId]!.stream;

  void emit(String streamTurn, TurnEventModel event) =>
      _streams[streamTurn]?.add(event);

  void failStream(String turn) =>
      _streams[turn]?.addError(StateError('offline'));

  @override
  Future<List<int>> audioBytes(String url) =>
      pendingAudio?.future ?? Future.value([1]);

  @override
  Future<void> cancel(String turnId) async {
    cancelled.add(turnId);
  }

  @override
  Future<Map<String, dynamic>> state(String turnId) async =>
      pendingState?.future ??
      snapshots[turnId] ??
      {'id': turnId, 'state': 'processing'};

  @override
  Future<List<TtsSegmentModel>> speech(String turnId) async {
    speechRequests++;
    return [
      TtsSegmentModel(
        turnId: turnId,
        index: 0,
        mediaUrl: '/v1/media/manual',
        mime: 'audio/mpeg',
        isLast: true,
      ),
    ];
  }

  void dispose() {
    for (final stream in _streams.values) {
      stream.close();
    }
  }
}

class _FakeTts implements TtsQueue {
  final segments = <TtsAudioSegment>[];
  final utterances = <(String, String)>[];
  var stops = 0;
  var native = false;

  @override
  bool get usesNativeText => native;

  @override
  void Function(String turnId)? onStarted;
  @override
  void Function(String turnId)? onFinished;
  @override
  void Function(String turnId)? onCancelled;
  @override
  void Function(String turnId)? onFailed;

  @override
  Future<List<TtsVoice>> availableVoices() async => const [];

  @override
  Future<void> speakText({
    required String turnId,
    required String text,
    required TtsVoiceSettings settings,
  }) async {
    utterances.add((turnId, text));
  }

  @override
  Future<void> add(TtsAudioSegment segment) async {
    segments.add(segment);
  }

  @override
  Future<void> configure() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> stop() async {
    stops++;
  }
}

class _FakeRecorder implements VoiceRecorder {
  final deleted = <String>[];
  var permission = MicrophonePermissionState.granted;

  @override
  void Function()? onInterrupted;

  @override
  Future<MicrophonePermissionState> permissionStatus() async => permission;

  @override
  Future<bool> openSettings() async => true;

  @override
  Future<bool> start(String clientId) async => true;

  @override
  Future<VoiceRecording?> stop() async =>
      const VoiceRecording(path: 'voice.m4a', durationMs: 900);

  @override
  Future<void> cancel() async {}

  @override
  Future<void> delete(String path) async {
    deleted.add(path);
  }
}
