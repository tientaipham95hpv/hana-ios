import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'tts_queue.dart';

class VoiceLabScreen extends ConsumerStatefulWidget {
  const VoiceLabScreen({super.key});

  @override
  ConsumerState<VoiceLabScreen> createState() => _VoiceLabScreenState();
}

class _VoiceLabScreenState extends ConsumerState<VoiceLabScreen> {
  static const _sample =
      'Chào anh, em là Hana. Hôm nay anh muốn em giúp gì nào?\n'
      'Nếu có chuyện gì muốn nói thì em vẫn ở đây.';

  List<TtsVoice> _voices = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!Platform.isIOS) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Voice Lab cần chạy trên thiết bị hoặc simulator iOS.';
        });
      }
      return;
    }
    try {
      final voices = await ref.read(ttsQueueProvider).availableVoices();
      if (!mounted) return;
      setState(() {
        _voices = voices;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Không thể liệt kê giọng vi-VN trên thiết bị này.';
      });
    }
  }

  Future<void> _preview() async {
    final preferences = ref.read(voicePreferencesProvider);
    try {
      await ref
          .read(ttsQueueProvider)
          .speakText(
            turnId: 'voice-lab',
            text: _sample,
            settings: TtsVoiceSettings(
              voiceIdentifier: preferences.voiceIdentifier,
              rate: preferences.speechRate,
              pitch: preferences.speechPitch,
              volume: preferences.speechVolume,
            ),
          );
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = 'Không thể phát câu thử.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final preferences = ref.read(voicePreferencesProvider);
    return AnimatedBuilder(
      animation: preferences,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('iOS Voice Lab')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!),
              ),
            DropdownButtonFormField<String?>(
              key: const Key('ios-voice-selector'),
              initialValue:
                  _voices.any(
                    (voice) => voice.identifier == preferences.voiceIdentifier,
                  )
                  ? preferences.voiceIdentifier
                  : null,
              decoration: const InputDecoration(
                labelText: 'Giọng vi-VN',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Mặc định hệ thống vi-VN'),
                ),
                ..._voices.map(
                  (voice) => DropdownMenuItem<String?>(
                    value: voice.identifier,
                    child: Text(
                      '${voice.name} · ${voice.locale} · ${voice.quality}',
                    ),
                  ),
                ),
              ],
              onChanged: preferences.setVoiceIdentifier,
            ),
            const SizedBox(height: 16),
            Text('Tốc độ: ${preferences.speechRate.toStringAsFixed(2)}'),
            Slider(
              key: const Key('ios-speech-rate'),
              value: preferences.speechRate,
              min: 0.1,
              max: 0.65,
              onChanged: preferences.setSpeechRate,
            ),
            Text('Cao độ: ${preferences.speechPitch.toStringAsFixed(2)}'),
            Slider(
              key: const Key('ios-speech-pitch'),
              value: preferences.speechPitch,
              min: 0.5,
              max: 2,
              onChanged: preferences.setSpeechPitch,
            ),
            Text('Âm lượng: ${preferences.speechVolume.toStringAsFixed(2)}'),
            Slider(
              key: const Key('ios-speech-volume'),
              value: preferences.speechVolume,
              min: 0,
              max: 1,
              onChanged: preferences.setSpeechVolume,
            ),
            const SizedBox(height: 12),
            const Text(_sample),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  key: const Key('ios-voice-preview'),
                  onPressed: _preview,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Phát câu thử'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const Key('ios-voice-stop'),
                  onPressed: ref.read(ttsQueueProvider).stop,
                  icon: const Icon(Icons.stop),
                  label: const Text('Dừng'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
