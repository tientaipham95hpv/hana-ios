import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hana_app/voice/ios_native_tts.dart';
import 'package:hana_app/voice/tts_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('hana/native_tts_test');
  late List<MethodCall> outbound;
  late IosNativeTtsQueue queue;

  setUp(() {
    outbound = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          outbound.add(call);
          if (call.method == 'listVoices') {
            return [
              {
                'name': 'Vietnamese Voice',
                'identifier': 'com.apple.voice.vi-VN.test',
                'locale': 'vi-VN',
                'quality': 'enhanced',
              },
            ];
          }
          return null;
        });
    queue = IosNativeTtsQueue(channel: channel);
  });

  tearDown(() async {
    await queue.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('enumerates Vietnamese voice metadata without selecting one', () async {
    final voices = await queue.availableVoices();
    expect(voices, hasLength(1));
    expect(voices.single.name, 'Vietnamese Voice');
    expect(voices.single.identifier, 'com.apple.voice.vi-VN.test');
    expect(voices.single.locale, 'vi-VN');
    expect(voices.single.quality, 'enhanced');
  });

  test('passes configurable vi-VN voice, rate, pitch and volume', () async {
    await queue.speakText(
      turnId: 'turn-a',
      text: 'Chào anh, em là Hana.',
      settings: const TtsVoiceSettings(
        voiceIdentifier: 'com.apple.voice.vi-VN.test',
        rate: 0.42,
        pitch: 1.1,
        volume: 0.8,
      ),
    );
    final speak = outbound.singleWhere((call) => call.method == 'speak');
    final arguments = Map<String, dynamic>.from(speak.arguments as Map);
    expect(arguments['language'], 'vi-VN');
    expect(arguments['voiceIdentifier'], 'com.apple.voice.vi-VN.test');
    expect(arguments['rate'], 0.42);
    expect(arguments['pitch'], 1.1);
    expect(arguments['volume'], 0.8);
  });

  test('stale native callback cannot mutate a newer utterance', () async {
    final started = <String>[];
    final finished = <String>[];
    queue.onStarted = started.add;
    queue.onFinished = finished.add;
    await queue.speakText(
      turnId: 'turn-a',
      text: 'A',
      settings: const TtsVoiceSettings(),
    );
    final first =
        Map<String, dynamic>.from(
              outbound.lastWhere((call) => call.method == 'speak').arguments
                  as Map,
            )['utteranceId']
            as String;
    await queue.speakText(
      turnId: 'turn-b',
      text: 'B',
      settings: const TtsVoiceSettings(),
    );
    final second =
        Map<String, dynamic>.from(
              outbound.lastWhere((call) => call.method == 'speak').arguments
                  as Map,
            )['utteranceId']
            as String;

    await queue.handleNativeEvent(
      MethodCall('speechFinished', {'utteranceId': first}),
    );
    await queue.handleNativeEvent(
      MethodCall('speechStarted', {'utteranceId': second}),
    );
    await queue.handleNativeEvent(
      MethodCall('speechFinished', {'utteranceId': second}),
    );
    expect(started, ['turn-b']);
    expect(finished, ['turn-b']);
  });

  test('interruption reports cancellation for the correlated turn', () async {
    final cancelled = <String>[];
    queue.onCancelled = cancelled.add;
    await queue.speakText(
      turnId: 'turn-a',
      text: 'A',
      settings: const TtsVoiceSettings(),
    );
    final utteranceId =
        Map<String, dynamic>.from(
              outbound.lastWhere((call) => call.method == 'speak').arguments
                  as Map,
            )['utteranceId']
            as String;
    await queue.handleNativeEvent(
      MethodCall('speechCancelled', {'utteranceId': utteranceId}),
    );
    expect(cancelled, ['turn-a']);
  });
}
