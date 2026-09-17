abstract interface class HanaAudioOutput {
  Future<void> speak(String text);
  Future<void> stop();
}

class NoopHanaAudioOutput implements HanaAudioOutput {
  const NoopHanaAudioOutput();

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}
}
