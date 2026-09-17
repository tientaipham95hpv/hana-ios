import 'dart:io';

import 'package:video_player/video_player.dart';

abstract interface class VideoControllerPort {
  Future<void> initialize();
  Future<void> setVolume(double volume);
  Future<void> setLooping(bool looping);
  Future<void> play();
  Future<void> pause();
  Future<void> dispose();
  void addListener(void Function() listener);
  void removeListener(void Function() listener);
  bool get isInitialized;
  bool get isCompleted;
  double get aspectRatio;
  VideoPlayerController? get platformController;
}

class VideoPlayerControllerPort implements VideoControllerPort {
  VideoPlayerControllerPort.file(File file)
    : _controller = VideoPlayerController.file(
        file,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

  final VideoPlayerController _controller;

  @override
  Future<void> initialize() => _controller.initialize();

  @override
  Future<void> setVolume(double volume) {
    if (volume != 0) {
      throw ArgumentError.value(volume, 'volume', 'video must remain muted');
    }
    return _controller.setVolume(0.0);
  }

  @override
  Future<void> setLooping(bool looping) => _controller.setLooping(looping);

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> dispose() => _controller.dispose();

  @override
  void addListener(void Function() listener) =>
      _controller.addListener(listener);

  @override
  void removeListener(void Function() listener) =>
      _controller.removeListener(listener);

  @override
  bool get isInitialized => _controller.value.isInitialized;

  @override
  bool get isCompleted => _controller.value.isCompleted;

  @override
  double get aspectRatio => _controller.value.aspectRatio;

  @override
  VideoPlayerController get platformController => _controller;
}

class MutedVideoSession {
  MutedVideoSession(this.controller);

  final VideoControllerPort controller;

  Future<void> initializeAndPlay({required bool looping}) async {
    await controller.initialize();
    await controller.setVolume(0.0);
    await controller.setLooping(looping);
    await controller.play();
  }
}

class ClipCompletionRelay {
  const ClipCompletionRelay._();

  static void Function() attach(
    VideoControllerPort controller,
    void Function() onCompleted,
  ) {
    var sent = false;
    void listener() {
      if (!sent && controller.isCompleted) {
        sent = true;
        onCompleted();
      }
    }

    controller.addListener(listener);
    return () => controller.removeListener(listener);
  }
}
