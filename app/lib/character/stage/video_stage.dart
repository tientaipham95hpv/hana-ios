import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../engine/engine_event.dart';
import '../manifest/manifest_models.dart';
import '../resolver/asset_resolver.dart';
import 'asset_repository.dart';
import 'video_controller_port.dart';

typedef VideoControllerFactory = VideoControllerPort Function(File file);

class StageRenderSpec {
  const StageRenderSpec({
    required this.videoFit,
    required this.alignment,
    required this.usesBlur,
  });

  factory StageRenderSpec.fromAsset(CharacterAsset asset) => StageRenderSpec(
    videoFit: asset.renderMode == 'contain_blur'
        ? BoxFit.contain
        : BoxFit.cover,
    alignment: Alignment(asset.focalX * 2 - 1, asset.focalY * 2 - 1),
    usesBlur: asset.renderMode == 'contain_blur',
  );

  final BoxFit videoFit;
  final Alignment alignment;
  final bool usesBlur;
}

class VideoStage extends StatefulWidget {
  const VideoStage({
    super.key,
    required this.resolution,
    required this.repository,
    required this.onEngineEvent,
    this.controllerFactory,
    this.paused = false,
    this.initializationTimeout = const Duration(milliseconds: 1500),
  });

  final ResolutionResult resolution;
  final CharacterAssetRepository repository;
  final ValueChanged<EngineEvent> onEngineEvent;
  final VideoControllerFactory? controllerFactory;
  final bool paused;
  final Duration initializationTimeout;
  static const maxControllerCount = 3;

  @override
  State<VideoStage> createState() => _VideoStageState();
}

class _VideoStageState extends State<VideoStage> {
  VideoControllerPort? _front;
  VideoControllerPort? _back;
  VideoControllerPort? _preload;
  CharacterAsset? _frontAsset;
  CharacterAsset? _backAsset;
  final Map<VideoControllerPort, void Function()> _listeners = {};
  final Map<VideoControllerPort, String> _controllerAssets = {};
  final Set<VideoControllerPort> _inflight = {};
  final Set<VideoControllerPort> _disposed = {};
  File? _poster;
  File? _posterBlur;
  CharacterAsset? _visualAsset;
  var _generation = 0;
  var _showBack = false;

  @override
  void initState() {
    super.initState();
    unawaited(_apply(widget.resolution));
  }

  @override
  void didUpdateWidget(covariant VideoStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolution != widget.resolution) {
      unawaited(_apply(widget.resolution));
    }
    if (oldWidget.paused != widget.paused) {
      final active = _showBack ? _back : _front;
      unawaited(widget.paused ? active?.pause() : active?.play());
    }
  }

  Future<void> _apply(ResolutionResult resolution) async {
    final generation = ++_generation;
    await _cancelInflight();
    if (generation != _generation || !mounted) return;
    final requestedAssetId = resolution.assetId;
    final currentAssetId = (_showBack ? _backAsset : _frontAsset)?.assetId;
    if (currentAssetId != null && currentAssetId != requestedAssetId) {
      // A changed policy may have revoked the old asset. Cut it before async
      // resolution/initialization; do not leave an ineligible frame visible.
      await _clearPlayback();
      if (generation != _generation || !mounted) return;
    }
    if (resolution.kind == VisualKind.silhouette) {
      await _clearPlayback();
      if (mounted) {
        setState(() {
          _poster = null;
          _posterBlur = null;
          _visualAsset = null;
        });
      }
      return;
    }
    final asset = resolution.playRequest?.asset ?? resolution.posterAsset;
    if (asset == null) return;
    final posters = await Future.wait<File?>([
      widget.repository.resolvePoster(asset),
      widget.repository.resolvePosterBlur(asset),
    ]);
    if (generation != _generation) return;
    if (mounted) {
      setState(() {
        _poster = posters[0];
        _posterBlur = posters[1];
        _visualAsset = asset;
      });
    }
    if (resolution.kind != VisualKind.play) {
      await _clearPlayback();
      return;
    }
    final media = await widget.repository.resolve(asset);
    if (generation != _generation) return;
    if (media == null) {
      await _clearPlayback();
      return;
    }
    if (mounted && media.posterBlur != null) {
      setState(() => _posterBlur = media.posterBlur);
    }
    if (_front != null && _back != null) {
      // The previous crossfade was superseded. Evict its inactive slot before
      // allocating another controller (including one still initializing).
      final inactive = _showBack ? _front : _back;
      if (_showBack) {
        _front = null;
        _frontAsset = null;
      } else {
        _back = null;
        _backAsset = null;
      }
      await _disposeController(inactive);
      if (generation != _generation || !mounted) return;
    }
    final factory = widget.controllerFactory ?? VideoPlayerControllerPort.file;
    if (generation != _generation || !mounted) return;
    final incoming = factory(media.video);
    if (widget.repository is CharacterAssetLifecycle) {
      final lifecycle = widget.repository as CharacterAssetLifecycle;
      lifecycle.protect(asset.assetId);
      _controllerAssets[incoming] = asset.assetId;
    }
    _inflight.add(incoming);
    assert(_liveControllerCount <= VideoStage.maxControllerCount);
    try {
      await MutedVideoSession(incoming)
          .initializeAndPlay(looping: resolution.playRequest!.loop)
          .timeout(widget.initializationTimeout);
      if (widget.paused) await incoming.pause();
      _inflight.remove(incoming);
      if (generation != _generation || !mounted) {
        await _disposeController(incoming);
        return;
      }
      if (!resolution.playRequest!.loop) {
        _listeners[incoming] = ClipCompletionRelay.attach(
          incoming,
          () => widget.onEngineEvent(
            ClipEnded(asset.assetId, playId: resolution.playRequest!.playId),
          ),
        );
      }
      final outgoing = _showBack ? _back : _front;
      final outgoingWasBack = _showBack;
      if (_showBack) {
        _front = incoming;
        _frontAsset = asset;
      } else {
        _back = incoming;
        _backAsset = asset;
      }
      if (mounted) setState(() => _showBack = !_showBack);
      await Future<void>.delayed(
        Duration(milliseconds: resolution.playRequest!.crossfadeMs),
      );
      if (generation != _generation || !mounted) return;
      await _disposeController(outgoing);
      if (outgoingWasBack && identical(_back, outgoing)) {
        _back = null;
        _backAsset = null;
      } else if (!outgoingWasBack && identical(_front, outgoing)) {
        _front = null;
        _frontAsset = null;
      }
      assert(_liveControllerCount <= VideoStage.maxControllerCount);
    } on TimeoutException catch (error) {
      _inflight.remove(incoming);
      await _disposeController(incoming);
      if (generation == _generation && mounted) {
        widget.onEngineEvent(
          ClipError(
            asset.assetId,
            error.toString(),
            playId: resolution.playRequest!.playId,
            isPermanent: false,
          ),
        );
      }
    } on Object catch (error) {
      _inflight.remove(incoming);
      await _disposeController(incoming);
      if (generation == _generation && mounted) {
        widget.onEngineEvent(
          ClipError(
            asset.assetId,
            error.toString(),
            playId: resolution.playRequest!.playId,
          ),
        );
      }
    }
  }

  Future<void> _disposeController(VideoControllerPort? controller) async {
    if (controller == null || !_disposed.add(controller)) return;
    _inflight.remove(controller);
    final listener = _listeners.remove(controller);
    listener?.call();
    final assetId = _controllerAssets.remove(controller);
    if (assetId != null && widget.repository is CharacterAssetLifecycle) {
      final lifecycle = widget.repository as CharacterAssetLifecycle;
      lifecycle.release(assetId);
    }
    await controller.dispose();
  }

  Future<void> _clearPlayback() async {
    await _cancelInflight();
    final front = _front;
    final back = _back;
    final preload = _preload;
    _front = null;
    _back = null;
    _preload = null;
    _frontAsset = null;
    _backAsset = null;
    await Future.wait<void>([
      _disposeController(front),
      _disposeController(back),
      _disposeController(preload),
    ]);
    if (mounted) setState(() => _showBack = false);
  }

  int get _controllerCount => [
    _front,
    _back,
    _preload,
  ].where((controller) => controller != null).length;

  int get _liveControllerCount => _controllerCount + _inflight.length;

  Future<void> _cancelInflight() async {
    final stale = List<VideoControllerPort>.of(_inflight);
    await Future.wait(stale.map(_disposeController));
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_clearPlayback());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final front = _front?.platformController;
    final back = _back?.platformController;
    return AspectRatio(
      aspectRatio: 9 / 16,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _Backdrop(
              poster: _poster,
              posterBlur: _posterBlur,
              asset: _visualAsset,
            ),
            AnimatedOpacity(
              opacity: _showBack ? 0 : 1,
              duration: const Duration(milliseconds: 250),
              child: _video(front, _frontAsset),
            ),
            AnimatedOpacity(
              opacity: _showBack ? 1 : 0,
              duration: const Duration(milliseconds: 250),
              child: _video(back, _backAsset),
            ),
            Positioned(
              left: 12,
              bottom: 10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Text(
                    widget.resolution.kind == VisualKind.play
                        ? 'Hana'
                        : 'Đang chờ thư viện vault',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _video(VideoPlayerController? controller, CharacterAsset? asset) {
    if (controller == null ||
        asset == null ||
        !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final render = StageRenderSpec.fromAsset(asset);
    return FittedBox(
      fit: render.videoFit,
      alignment: render.alignment,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: controller.value.size.width,
        height: controller.value.size.height,
        child: VideoPlayer(controller),
      ),
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({
    required this.poster,
    required this.posterBlur,
    required this.asset,
  });
  final File? poster;
  final File? posterBlur;
  final CharacterAsset? asset;

  @override
  Widget build(BuildContext context) {
    if (poster != null) {
      final render = asset == null ? null : StageRenderSpec.fromAsset(asset!);
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            posterBlur ?? poster!,
            fit: BoxFit.cover,
            alignment: render?.alignment ?? Alignment.center,
            gaplessPlayback: true,
          ),
          if (render?.usesBlur ?? false)
            Image.file(poster!, fit: BoxFit.contain, gaplessPlayback: true),
        ],
      );
    }
    return CustomPaint(
      painter: _SilhouettePainter(
        background: Theme.of(context).colorScheme.surfaceContainerHighest,
        foreground: Theme.of(context).colorScheme.primary
            .withValues(alpha: 0.35),
      ),
    );
  }
}

class _SilhouettePainter extends CustomPainter {
  const _SilhouettePainter({
    required this.background,
    required this.foreground,
  });
  final Color background;
  final Color foreground;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final paint = Paint()..color = foreground;
    canvas.drawCircle(
      Offset(size.width / 2, size.height * 0.28),
      size.width * 0.16,
      paint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height * 0.68),
        width: size.width * 0.62,
        height: size.height * 0.72,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _SilhouettePainter oldDelegate) =>
      oldDelegate.background != background ||
      oldDelegate.foreground != foreground;
}
