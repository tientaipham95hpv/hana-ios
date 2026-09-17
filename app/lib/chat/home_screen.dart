import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/character_runtime_controller.dart';
import '../app/providers.dart';
import '../backend/backend_config.dart';
import '../character/engine/engine_event.dart';
import '../character/manifest/manifest_models.dart';
import '../character/stage/video_stage.dart';
import '../core/secure_window_coordinator.dart';
import '../voice/voice_recorder.dart';
import 'chat_controller.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, required this.developerSurfaces});
  final bool developerSurfaces;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  late final CharacterRuntimeController _runtime;
  late final ChatController _chat;
  final _secureWindow = const SecureWindowCoordinator();
  final _draft = TextEditingController();
  final _scroll = ScrollController();
  var _privacyOverlay = false;
  Timer? _pttDelay;
  Offset? _pttOrigin;
  var _cancelPtt = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _runtime = ref.read(characterRuntimeProvider)..addListener(_refresh);
    _chat = ref.read(chatControllerProvider)..addListener(_refresh);
    unawaited(
      _secureWindow.applyHome(
        ref.read(manifestProvider),
        ref.read(ownerPolicyProvider),
      ),
    );
    unawaited(_runtime.refreshVaultAvailability());
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      final asset =
          _runtime.state.lastResolution?.playRequest?.asset ??
          _runtime.state.lastResolution?.posterAsset;
      if (asset != null &&
          asset.contentSensitivity != ContentSensitivity.normal &&
          mounted) {
        setState(() => _privacyOverlay = true);
      }
    } else if (state == AppLifecycleState.paused) {
      _chat.appPaused();
      _runtime.dispatch(const AppPaused());
    } else if (state == AppLifecycleState.resumed) {
      if (mounted) setState(() => _privacyOverlay = false);
      _runtime.dispatch(const AppResumed());
    }
  }

  Future<void> _send() async {
    if (!ref.read(backendConfigProvider).isConfigured) {
      setState(
        () => _chat.error = 'Backend chưa cấu hình. Hãy kiểm tra cài đặt.',
      );
      return;
    }
    final value = _draft.text;
    await _chat.sendText(value);
    if (_chat.pendingDraft == null && mounted) _draft.clear();
  }

  void _pointerDown(PointerDownEvent event) {
    _pttOrigin = event.position;
    _cancelPtt = false;
    _pttDelay?.cancel();
    _pttDelay = Timer(const Duration(milliseconds: 150), _chat.beginPtt);
  }

  void _pointerMove(PointerMoveEvent event) {
    final origin = _pttOrigin;
    if (origin == null) return;
    final delta = event.position - origin;
    final cancel = delta.dx < -80 || delta.dy < -80;
    if (cancel != _cancelPtt && mounted) setState(() => _cancelPtt = cancel);
  }

  void _pointerUp(PointerEvent event) {
    if (_pttDelay?.isActive ?? false) {
      _pttDelay?.cancel();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Giữ để nói')));
    } else if (_cancelPtt) {
      unawaited(_chat.cancelPtt());
    } else {
      unawaited(_chat.endPtt());
    }
    _pttOrigin = null;
    if (mounted) setState(() => _cancelPtt = false);
  }

  @override
  void dispose() {
    _pttDelay?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _runtime.removeListener(_refresh);
    _chat.removeListener(_refresh);
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(ownerPolicyProvider, (_, next) {
      _runtime.updateOwnerPolicy(next);
      unawaited(_secureWindow.applyHome(ref.read(manifestProvider), next));
    });
    final backendConfig = ref.watch(backendConfigProvider);
    final resolution = _runtime.state.lastResolution;
    final noMedia =
        _runtime.state.readyAssetIds.isEmpty &&
        _runtime.state.readyPosterIds.isEmpty;
    final pttUnavailableReason = _pttUnavailableReason(backendConfig);
    final pttEnabled = pttUnavailableReason == null && !_chat.recording ||
        _chat.recording;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hana'),
        actions: [
          if (widget.developerSurfaces)
            IconButton(
              tooltip: 'Character Lab',
              onPressed: () => Navigator.pushNamed(context, '/character-lab'),
              icon: const Icon(Icons.science_outlined),
            ),
          IconButton(
            tooltip: 'Cài đặt',
            onPressed: () => Navigator.pushNamed(context, '/settings'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _BackendStatus(config: backendConfig, chat: _chat),
                if (noMedia) const _MediaBootstrapNotice(),
                SizedBox(
                  height: 260,
                  child: Center(
                    child: SizedBox(
                      width: 146,
                      child: resolution == null
                          ? const VideoStagePlaceholder()
                          : VideoStage(
                              resolution: resolution,
                              repository: _runtime.repository,
                              onEngineEvent: _runtime.dispatch,
                              paused: _runtime.stagePaused,
                            ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      const Text('Chat'),
                      if (ref
                          .watch(ownerPolicyProvider)
                          .relationshipStageEnabled)
                        DropdownButton<String>(
                          key: const Key('chat-semantic-mode'),
                          value: _chat.semanticMode,
                          items: const [
                            DropdownMenuItem(
                              value: 'daily',
                              child: Text('Hằng ngày'),
                            ),
                            DropdownMenuItem(
                              value: 'relationship',
                              child: Text('Quan hệ'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) _chat.setSemanticMode(value);
                          },
                        ),
                      const Spacer(),
                      Text('Trạng thái: ${_runtime.state.activity.name}'),
                      if (_chat.activeTurnId != null)
                        IconButton(
                          key: const Key('cancel-turn'),
                          tooltip: 'Hủy lượt',
                          onPressed: _chat.cancelTurn,
                          icon: const Icon(Icons.stop_circle_outlined),
                        ),
                    ],
                  ),
                ),
                if (_chat.error != null)
                  MaterialBanner(
                    content: Text(_chat.error!),
                    actions: [
                      if (_chat.microphonePermission ==
                              MicrophonePermissionState.denied ||
                          _chat.microphonePermission ==
                              MicrophonePermissionState.restricted)
                        TextButton(
                          onPressed: _chat.openMicrophoneSettings,
                          child: const Text('Mở Cài đặt'),
                        ),
                      TextButton(
                        onPressed: () => setState(() => _chat.error = null),
                        child: const Text('Đóng'),
                      ),
                    ],
                  ),
                if (_chat.microphonePermission ==
                        MicrophonePermissionState.denied ||
                    _chat.microphonePermission ==
                        MicrophonePermissionState.restricted)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Text(
                      'Micro bị từ chối — chat văn bản vẫn dùng được.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                if (pttUnavailableReason != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Text(
                      pttUnavailableReason,
                      key: const Key('ptt-status'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                Expanded(
                  child: ListView(
                    key: const Key('chat-messages'),
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: _chat.messages.isEmpty
                        ? const [
                            SizedBox(
                              height: 100,
                              child: Center(
                                child: Text(
                                  'Chưa có tin nhắn — hãy nói “Xin chào Hana”',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ]
                        : _chat.messages.map((message) {
                            return Align(
                              alignment: message.role == 'user'
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Card(
                                color: message.role == 'user'
                                    ? Theme.of(context).colorScheme.primaryContainer
                                    : null,
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Text(message.text),
                                ),
                              ),
                            );
                          }).toList(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('chat-input'),
                          controller: _draft,
                          enabled: !_chat.recording,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            hintText: 'Nhắn Hana…',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('send-message'),
                        tooltip: 'Gửi',
                        onPressed: _chat.sending ? null : _send,
                        icon: _chat.sending
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send),
                      ),
                      Listener(
                        onPointerDown: pttEnabled ? _pointerDown : null,
                        onPointerMove: pttEnabled ? _pointerMove : null,
                        onPointerUp: pttEnabled ? _pointerUp : null,
                        onPointerCancel: pttEnabled ? _pointerUp : null,
                        child: Semantics(
                          button: true,
                          label: pttUnavailableReason ?? 'Giữ để nói',
                          child: CircleAvatar(
                            key: const Key('ptt-button'),
                            backgroundColor: _cancelPtt
                                ? Theme.of(context).colorScheme.error
                                : pttEnabled
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                            child: Icon(
                              _chat.recording ? Icons.mic : Icons.mic_none,
                              color: pttEnabled ? Colors.white : Colors.black54,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!backendConfig.isConfigured)
                  const Padding(
                    padding: EdgeInsets.only(left: 16, right: 16, bottom: 8),
                    child: Text(
                      'Backend chưa cấu hình — tin nhắn sẽ báo lỗi cho tới khi cấu hình.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                if (widget.developerSurfaces && !backendConfig.isConfigured)
                  FilledButton(
                    key: const Key('mock-conversation'),
                    onPressed: _runtime.runConversationDemo,
                    child: const Text('Demo PTT'),
                  ),
              ],
            ),
          ),
          if (_privacyOverlay)
            const Positioned.fill(
              child: ColoredBox(
                key: Key('home-privacy-overlay'),
                color: Color(0xFF171217),
              ),
            ),
        ],
      ),
    );
  }

  String? _pttUnavailableReason(BackendConfig config) {
    if (!config.isConfigured) return 'Voice input not configured';
    if (_chat.microphonePermission == MicrophonePermissionState.denied ||
        _chat.microphonePermission == MicrophonePermissionState.restricted) {
      return 'Micro bị từ chối — bật trong Cài đặt để dùng voice.';
    }
    return null;
  }
}

class VideoStagePlaceholder extends StatelessWidget {
  const VideoStagePlaceholder({super.key});

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 9 / 16,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _PlaceholderSilhouettePainter(
              background: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest,
              foreground: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.35),
            ),
          ),
          Positioned(
            left: 12,
            bottom: 10,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: Text(
                  'Hana',
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _PlaceholderSilhouettePainter extends CustomPainter {
  const _PlaceholderSilhouettePainter({
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
  bool shouldRepaint(covariant _PlaceholderSilhouettePainter oldDelegate) =>
      oldDelegate.background != background ||
      oldDelegate.foreground != foreground;
}

class _BackendStatus extends StatelessWidget {
  const _BackendStatus({required this.config, required this.chat});
  final BackendConfig config;
  final ChatController chat;

  @override
  Widget build(BuildContext context) {
    final state = _derive();
    final (label, icon, color) = switch (state) {
      BackendConnectionState.connected => (
        'Backend: Đã kết nối',
        Icons.cloud_done_outlined,
        Colors.green,
      ),
      BackendConnectionState.connecting => (
        'Backend: Đang kết nối',
        Icons.cloud_sync_outlined,
        Colors.orange,
      ),
      BackendConnectionState.offline => (
        'Backend: Ngoại tuyến',
        Icons.cloud_off_outlined,
        Colors.red,
      ),
      BackendConnectionState.misconfigured => (
        'Backend: Chưa cấu hình',
        Icons.settings_outlined,
        Colors.orange,
      ),
    };
    return Container(
      key: const Key('backend-status'),
      width: double.infinity,
      color: color.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
            ),
          ),
          if (state == BackendConnectionState.offline && chat.error != null)
            Text(
              ' • ${chat.error}',
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  BackendConnectionState _derive() {
    if (!config.isConfigured) return BackendConnectionState.misconfigured;
    final error = chat.error;
    if (error != null &&
        (error.contains('Không kết nối') ||
            error.contains('Mất kết nối') ||
            error.contains('Backend chưa cấu hình'))) {
      return BackendConnectionState.offline;
    }
    if (chat.sending || chat.activeTurnId != null) {
      return BackendConnectionState.connecting;
    }
    // Without a real health probe, treat a configured backend with no active
    // error/turn as connecting until the first successful turn. This avoids
    // claiming "connected" before any network proof.
    return BackendConnectionState.connecting;
  }
}

class _MediaBootstrapNotice extends StatelessWidget {
  const _MediaBootstrapNotice();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('media-bootstrap-notice'),
    width: double.infinity,
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Row(
      children: [
        Icon(Icons.person_outline, size: 18),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            'Character media not downloaded yet — silhouette shown.',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    ),
  );
}
