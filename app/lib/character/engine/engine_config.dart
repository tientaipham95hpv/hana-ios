class EngineConfig {
  const EngineConfig._();

  static const crossfadeDefault = Duration(milliseconds: 250);
  static const crossfadeListening = Duration(milliseconds: 150);
  static const thinkingMinDwell = Duration(milliseconds: 500);
  static const preSpeechMax = Duration(milliseconds: 1200);
  static const overlayMin = Duration(milliseconds: 1500);
  static const overlayMax = Duration(milliseconds: 4000);
  static const workingMax = Duration(minutes: 2);
  static const idleToSleepQuiet = Duration(minutes: 1);
  static const idleToSleepDay = Duration(minutes: 30);
  static const thinkingVariantRotate = Duration(seconds: 10);
  static const contextHold = Duration(seconds: 90);
  static const ttsWaitTimeout = Duration(seconds: 8);
  // Last-resort recovery if an audio player never reports completion/failure.
  static const ttsPlaybackMax = Duration(minutes: 10);
}
