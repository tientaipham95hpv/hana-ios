import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../character/engine/engine_event.dart';
import '../character/manifest/manifest_models.dart';
import '../character/resolver/asset_resolver.dart';
import '../character/stage/asset_repository.dart';
import '../character/stage/video_controller_port.dart';
import '../character/stage/video_stage.dart';

/// Full-bleed character backdrop for the home screen.
/// Reuses the same muted-video guarantees and resolver semantics as
/// [VideoStage] but renders edge-to-edge without the 9:16 card crop.
class CharacterStageBackground extends StatefulWidget {
  const CharacterStageBackground({
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
  static const maxControllerCount = VideoStage.maxControllerCount;

  @override
  State<CharacterStageBackground> createState() =>
      _CharacterStageBackgroundState();
}

class _CharacterStageBackgroundState extends State<CharacterStageBackground> {
  VideoControllerPort? _front;
  VideoControllerPort? _back;
  CharacterAsset? _frontAsset;
  CharacterAsset? _backAsset;
  final Map<VideoControllerPort, void Function()> _listeners = {};
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
  void didUpdateWidget(covariant CharacterStageBackground oldWidget) {
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
    final outgoing = _showBack ? _back : _front;
    final outgoingWasBack = _showBack;
    if (_front != null && _back != null) {
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
    _inflight.add(incoming);
    assert(_liveControllerCount <= CharacterStageBackground.maxControllerCount);
    try {
      await MutedVideoSession(incoming)
          .initializeAndPlay(looping: resolution.playRequest!.loop)
          .timeout(widget.initializationTimeout);
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
    final remove = _listeners.remove(controller);
    remove?.call();
    await controller.dispose();
  }

  Future<void> _clearPlayback() async {
    await _cancelInflight();
    final front = _front;
    final back = _back;
    _front = null;
    _back = null;
    _frontAsset = null;
    _backAsset = null;
    await Future.wait<void>([
      _disposeController(front),
      _disposeController(back),
    ]);
    if (mounted) setState(() => _showBack = false);
  }

  int get _liveControllerCount {
    var count = _inflight.length;
    if (_front != null) count++;
    if (_back != null) count++;
    return count;
  }

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
    final isSilhouette = widget.resolution.kind == VisualKind.silhouette;
    return Stack(
      fit: StackFit.expand,
      children: [
        _FullBleedBackdrop(
          poster: _poster,
          posterBlur: _posterBlur,
          asset: _visualAsset,
          isSilhouette: isSilhouette,
        ),
        AnimatedOpacity(
          opacity: _showBack ? 0 : 1,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          child: _fullVideo(front, _frontAsset),
        ),
        AnimatedOpacity(
          opacity: _showBack ? 1 : 0,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          child: _fullVideo(back, _backAsset),
        ),
        // Subtle center label so vault-empty states still feel intentional.
        Positioned(
          left: 16,
          right: 16,
          bottom: 18,
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.42),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
                child: Text(
                  widget.resolution.kind == VisualKind.play
                      ? 'Hana · ${widget.resolution.effectiveContext.name}'
                      : 'Đang chờ thư viện vault',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fullVideo(VideoPlayerController? controller, CharacterAsset? asset) {
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

class _FullBleedBackdrop extends StatelessWidget {
  const _FullBleedBackdrop({
    required this.poster,
    required this.posterBlur,
    required this.asset,
    required this.isSilhouette,
  });
  final File? poster;
  final File? posterBlur;
  final CharacterAsset? asset;
  final bool isSilhouette;

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
          // Soft vignette to keep text legible over bright posters.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.center,
                colors: [
                  Colors.black.withValues(alpha: 0.18),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ],
      );
    }
    return CustomPaint(
      painter: _SilhouettePainter(
        background: const Color(0xFF1A1220),
        foreground: Theme.of(context).colorScheme.primary
            .withValues(alpha: 0.28),
        accent: Colors.white.withValues(alpha: 0.06),
      ),
    );
  }
}

class _SilhouettePainter extends CustomPainter {
  const _SilhouettePainter({
    required this.background,
    required this.foreground,
    required this.accent,
  });
  final Color background;
  final Color foreground;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = background;
    canvas.drawRect(Offset.zero & size, bg);
    // Ambient radial glow.
    final glow = Paint()
      ..shader =
          RadialGradient(
            colors: [foreground.withValues(alpha: 0.55), Colors.transparent],
            stops: const [0.0, 0.92],
          ).createShader(
            Rect.fromCircle(
              center: Offset(size.width * 0.5, size.height * 0.34),
              radius: size.width * 0.72,
            ),
          );
    canvas.drawRect(Offset.zero & size, glow);
    final paint = Paint()..color = foreground;
    canvas.drawCircle(
      Offset(size.width * 0.5, size.height * 0.30),
      size.width * 0.17,
      paint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.5, size.height * 0.70),
        width: size.width * 0.58,
        height: size.height * 0.64,
      ),
      paint,
    );
    final accentPaint = Paint()..color = accent;
    canvas.drawCircle(
      Offset(size.width * 0.68, size.height * 0.22),
      size.width * 0.08,
      accentPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _SilhouettePainter oldDelegate) =>
      oldDelegate.background != background ||
      oldDelegate.foreground != foreground ||
      oldDelegate.accent != accent;
}
