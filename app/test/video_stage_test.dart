import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hana_app/character/engine/engine_event.dart';
import 'package:hana_app/character/manifest/manifest_models.dart';
import 'package:hana_app/character/resolver/asset_resolver.dart';
import 'package:hana_app/character/stage/asset_repository.dart';
import 'package:hana_app/character/stage/video_controller_port.dart';
import 'package:hana_app/character/stage/video_stage.dart';
import 'package:video_player/video_player.dart';

import 'support/canonical_manifest.dart';

class FakeVideoController implements VideoControllerPort {
  final calls = <String>[];
  final listeners = <void Function()>[];
  bool initialized = false;
  bool completed = false;

  @override
  void addListener(void Function() listener) => listeners.add(listener);

  @override
  void removeListener(void Function() listener) => listeners.remove(listener);

  void complete() {
    completed = true;
    for (final listener in List<void Function()>.of(listeners)) {
      listener();
    }
  }

  @override
  double get aspectRatio => 9 / 16;

  @override
  Future<void> dispose() async => calls.add('dispose');

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    initialized = true;
  }

  @override
  bool get isCompleted => completed;

  @override
  bool get isInitialized => initialized;

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> play() async => calls.add('play');

  @override
  VideoPlayerController? get platformController => null;

  @override
  Future<void> setLooping(bool looping) async => calls.add('loop:$looping');

  @override
  Future<void> setVolume(double volume) async => calls.add('volume:$volume');
}

class ControlledVideoController extends FakeVideoController {
  ControlledVideoController(this.tracker) {
    tracker.live++;
    if (tracker.live > tracker.maxLive) tracker.maxLive = tracker.live;
  }

  final ControllerTracker tracker;
  final initializedCompleter = Completer<void>();
  var disposed = false;

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    await initializedCompleter.future;
    initialized = true;
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    if (!initializedCompleter.isCompleted) {
      initializedCompleter.completeError(StateError('disposed'));
    }
    tracker.live--;
    calls.add('dispose');
  }
}

class ControllerTracker {
  var live = 0;
  var maxLive = 0;
  final controllers = <ControlledVideoController>[];
}

void main() {
  test('muted session sets volume zero before play', () async {
    final controller = FakeVideoController();
    await MutedVideoSession(controller).initializeAndPlay(looping: true);
    expect(controller.calls, ['initialize', 'volume:0.0', 'loop:true', 'play']);
    expect(controller.calls, isNot(contains('volume:1.0')));
  });

  test('platform adapter rejects every non-zero volume', () {
    final controller = VideoPlayerControllerPort.file(File('unused.mp4'));
    expect(() => controller.setVolume(0.1), throwsArgumentError);
  });

  test('source contains no stage call that enables video audio', () {
    final source = File('lib/character/stage/video_stage.dart')
        .readAsStringSync();
    expect(source, isNot(contains('setVolume(')));
    final session = File('lib/character/stage/video_controller_port.dart')
        .readAsStringSync();
    expect(session, contains('setVolume(0.0)'));
    expect(RegExp(r'setVolume\((?:1|0\.[1-9])').hasMatch(session), isFalse);
  });

  test('oneshot completion relay emits exactly one ClipEnded', () {
    final fake = FakeVideoController();
    final events = <EngineEvent>[];
    final detach = ClipCompletionRelay.attach(
      fake,
      () => events.add(const ClipEnded('chr_001', playId: 7)),
    );
    fake.complete();
    fake.complete();
    expect(events.whereType<ClipEnded>().single.assetId, 'chr_001');
    detach();
    expect(fake.listeners, isEmpty);
  });

  testWidgets('VideoStage displays silhouette without local vault media', (
    tester,
  ) async {
    const result = ResolutionResult(
      kind: VisualKind.silhouette,
      effectiveContext: StageContext.daily,
      fallbackTrace: ['silhouette'],
      candidatePoolCount: 0,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VideoStage(
            resolution: result,
            repository: MockVaultAssetRepository(),
            onEngineEvent: _ignoreEvent,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Đang chờ thư viện vault'), findsOneWidget);
  });

  test('render spec applies contain_blur and manifest focal point', () {
    final asset = canonicalManifest().assets.firstWhere(
      (item) => item.renderMode == 'contain_blur',
    );
    final spec = StageRenderSpec.fromAsset(asset);
    expect(spec.videoFit, BoxFit.contain);
    expect(spec.usesBlur, isTrue);
    expect(
      spec.alignment,
      Alignment(asset.focalX * 2 - 1, asset.focalY * 2 - 1),
    );
  });

  testWidgets('silhouette transition disposes active video playback', (
    tester,
  ) async {
    final asset = canonicalManifest().assets.first;
    final fake = FakeVideoController();
    final repository = MockVaultAssetRepository(
      available: {
        asset.assetId: LocalCharacterMedia(video: File('unused.mp4')),
      },
    );
    final play = ResolutionResult(
      kind: VisualKind.play,
      effectiveContext: StageContext.daily,
      fallbackTrace: const ['play'],
      candidatePoolCount: 1,
      playRequest: PlayRequest(asset: asset, loop: true, crossfadeMs: 0),
    );
    Widget stage(ResolutionResult result) => MaterialApp(
      home: Scaffold(
        body: VideoStage(
          key: const ValueKey('stage'),
          resolution: result,
          repository: repository,
          controllerFactory: (_) => fake,
          onEngineEvent: _ignoreEvent,
        ),
      ),
    );
    await tester.pumpWidget(stage(play));
    await tester.pumpAndSettle();
    expect(fake.calls, contains('play'));

    const silhouette = ResolutionResult(
      kind: VisualKind.silhouette,
      effectiveContext: StageContext.daily,
      fallbackTrace: ['silhouette'],
      candidatePoolCount: 0,
    );
    await tester.pumpWidget(stage(silhouette));
    await tester.pumpAndSettle();
    expect(fake.calls, contains('dispose'));
  });

  testWidgets('50 rapid Play requests never exceed controller hard cap', (
    tester,
  ) async {
    final asset = canonicalManifest().assets.first;
    final tracker = ControllerTracker();
    final repository = MockVaultAssetRepository(
      available: {
        asset.assetId: LocalCharacterMedia(video: File('unused.mp4')),
      },
    );
    ResolutionResult play(int id) => ResolutionResult(
      kind: VisualKind.play,
      effectiveContext: StageContext.daily,
      fallbackTrace: const ['play'],
      candidatePoolCount: 1,
      playRequest: PlayRequest(
        asset: asset,
        loop: true,
        crossfadeMs: 0,
        playId: id,
      ),
    );
    Widget stage(int id) => MaterialApp(
      home: VideoStage(
        key: const ValueKey('rapid-stage'),
        resolution: play(id),
        repository: repository,
        onEngineEvent: _ignoreEvent,
        controllerFactory: (_) {
          final controller = ControlledVideoController(tracker);
          tracker.controllers.add(controller);
          return controller;
        },
      ),
    );

    await tester.pumpWidget(stage(0));
    await tester.pump();
    for (var index = 1; index < 50; index++) {
      await tester.pumpWidget(stage(index));
      await tester.pump();
    }
    expect(tracker.maxLive, lessThanOrEqualTo(VideoStage.maxControllerCount));
    expect(tracker.live, lessThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tracker.live, 0);
  });

  testWidgets('initialization timeout is reported as transient', (
    tester,
  ) async {
    final asset = canonicalManifest().assets.first;
    final tracker = ControllerTracker();
    final events = <EngineEvent>[];
    final repository = MockVaultAssetRepository(
      available: {
        asset.assetId: LocalCharacterMedia(video: File('unused.mp4')),
      },
    );
    final result = ResolutionResult(
      kind: VisualKind.play,
      effectiveContext: StageContext.daily,
      fallbackTrace: const ['play'],
      candidatePoolCount: 1,
      playRequest: PlayRequest(
        asset: asset,
        loop: true,
        crossfadeMs: 0,
        playId: 77,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: VideoStage(
          resolution: result,
          repository: repository,
          initializationTimeout: const Duration(milliseconds: 10),
          onEngineEvent: events.add,
          controllerFactory: (_) {
            final controller = ControlledVideoController(tracker);
            tracker.controllers.add(controller);
            return controller;
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 11));
    final error = events.whereType<ClipError>().single;
    expect(error.playId, 77);
    expect(error.isPermanent, isFalse);
  });
}

void _ignoreEvent(EngineEvent event) {}
