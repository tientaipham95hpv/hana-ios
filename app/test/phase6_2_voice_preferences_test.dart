import 'package:flutter_test/flutter_test.dart';
import 'package:hana_app/voice/voice_preferences.dart';

void main() {
  test('AUTO makes typed text silent and PTT voiced by default', () {
    final preferences = VoicePreferences(store: MemoryVoicePreferenceStore());
    expect(preferences.responseMode, VoiceResponseMode.auto);
    expect(preferences.shouldSpeak(voiceInput: false), false);
    expect(preferences.shouldSpeak(voiceInput: true), true);
  });

  test('preference persists and Text only never requests TTS', () async {
    final store = MemoryVoicePreferenceStore();
    final first = VoicePreferences(store: store);
    await first.setResponseMode(VoiceResponseMode.textOnly);
    await first.setAutoPlayVoice(false);
    final reloaded = VoicePreferences(store: store);
    await reloaded.load();
    expect(reloaded.responseMode, VoiceResponseMode.textOnly);
    expect(reloaded.autoPlayVoice, false);
    expect(reloaded.shouldSpeak(voiceInput: false), false);
    expect(reloaded.shouldSpeak(voiceInput: true), false);
  });

  test('Voice reply can be manual only when autoplay disabled', () async {
    final preferences = VoicePreferences(store: MemoryVoicePreferenceStore());
    await preferences.setResponseMode(VoiceResponseMode.voiceReply);
    expect(preferences.shouldSpeak(voiceInput: false), true);
    await preferences.setAutoPlayVoice(false);
    expect(preferences.shouldSpeak(voiceInput: false), false);
    expect(preferences.shouldSpeak(voiceInput: true), false);
  });

  test('iOS voice selection and tuning persist with safe bounds', () async {
    final store = MemoryVoicePreferenceStore();
    final first = VoicePreferences(store: store);
    await first.setVoiceIdentifier('com.apple.voice.vi-VN.test');
    await first.setSpeechRate(2);
    await first.setSpeechPitch(0.1);
    await first.setSpeechVolume(-1);

    final reloaded = VoicePreferences(store: store);
    await reloaded.load();
    expect(reloaded.voiceIdentifier, 'com.apple.voice.vi-VN.test');
    expect(reloaded.speechRate, 0.65);
    expect(reloaded.speechPitch, 0.5);
    expect(reloaded.speechVolume, 0);
  });
}
