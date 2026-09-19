import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/character_runtime_controller.dart';
import '../app/providers.dart';
import '../backend/backend_config.dart';
import '../backend/turn_models.dart';
import '../character/engine/engine_event.dart';
import '../character/manifest/manifest_models.dart';
import '../character/vault/character_vault.dart';
import '../core/secure_window_coordinator.dart';
import '../voice/voice_recorder.dart';
import 'character_stage.dart';
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
  late final CharacterVault _vault;
  final _secureWindow = const SecureWindowCoordinator();
  final _draft = TextEditingController();
  final _scroll = ScrollController();
  Timer? _pttDelay;
  Offset? _pttOrigin;
  var _privacyOverlay = false;
  var _cancelPtt = false;
  var _historyExpanded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _runtime = ref.read(characterRuntimeProvider)..addListener(_refresh);
    _chat = ref.read(chatControllerProvider)..addListener(_refresh);
    _vault = ref.read(characterVaultProvider)..addListener(_mediaRefresh);
    unawaited(
      _secureWindow.applyHome(
        ref.read(manifestProvider),
        ref.read(ownerPolicyProvider),
      ),
    );
    unawaited(_bootstrapMedia());
  }

  Future<void> _bootstrapMedia() async {
    await _vault.bootstrap();
    _runtime.updateManifest(_vault.manifest);
    await _runtime.refreshVaultAvailability();
  }

  void _mediaRefresh() {
    unawaited(_runtime.refreshVaultAvailability());
    _refresh();
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Giữ để nói')));
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
    _vault.removeListener(_mediaRefresh);
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
    final config = ref.watch(backendConfigProvider);
    final resolution = _runtime.state.lastResolution;
    final noMedia =
        _runtime.state.readyAssetIds.isEmpty &&
        _runtime.state.readyPosterIds.isEmpty;
    final pttUnavailableReason = _pttUnavailableReason(config);
    final pttEnabled =
        (pttUnavailableReason == null && !_chat.recording) || _chat.recording;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final composerBottom = insets > 0 ? insets + 8 : safeBottom + 8;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        key: const Key('character-stage-root'),
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            key: const Key('character-stage-viewport'),
            child: resolution == null
                ? const _SilhouetteFallback()
                : CharacterStageBackground(
                    resolution: resolution,
                    repository: _runtime.repository,
                    onEngineEvent: _runtime.dispatch,
                    paused: _runtime.stagePaused,
                  ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: _TopChrome(
                config: config,
                chat: _chat,
                developerSurfaces: widget.developerSurfaces,
                onDemo: _runtime.runConversationDemo,
              ),
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(
                top: MediaQuery.paddingOf(context).top + 52,
                bottom: composerBottom + 76,
              ),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: _buildChatOverlay(context, noMedia),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: composerBottom,
            child: _buildComposer(
              context,
              config,
              pttUnavailableReason,
              pttEnabled,
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

  Widget _buildChatOverlay(BuildContext context, bool noMedia) {
    final messages = _chat.messages;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final maxHeight = keyboard
        ? 150.0
        : (MediaQuery.sizeOf(context).height < 650 ? 150.0 : 240.0);
    final shown = _historyExpanded
        ? messages
        : (messages.length <= 3
              ? messages
              : messages.sublist(messages.length - 3));
    return Container(
      key: const Key('chat-overlay'),
      constraints: BoxConstraints(maxHeight: maxHeight),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (noMedia) _MediaBootstrapNotice(status: _vault.snapshot.label),
          if (noMedia && messages.isEmpty)
            const Text(
              'Voice input not configured',
              key: Key('ptt-status'),
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          if (messages.isNotEmpty)
            Flexible(
              child: ListView(
                key: const Key('chat-messages'),
                controller: _scroll,
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: shown.map(_messageBubble).toList(),
              ),
            )
          else
            const Text(
              'Chat',
              style: TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          if (messages.length > 3)
            TextButton(
              key: const Key('conversation-history-toggle'),
              onPressed: () =>
                  setState(() => _historyExpanded = !_historyExpanded),
              child: Text(
                _historyExpanded ? 'Thu gọn lịch sử' : 'Xem lịch sử trò chuyện',
              ),
            ),
        ],
      ),
    );
  }

  Widget _messageBubble(ChatMessageModel message) {
    final user = message.role == 'user';
    final talking = _chat.manualAudioTurnId == message.turnId;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Card(
        color: user
            ? Theme.of(context).colorScheme.primaryContainer
            : Colors.black.withValues(alpha: .58),
        child: InkWell(
          key: user ? null : Key('speech-${message.id}'),
          onTap: user
              ? null
              : () => talking ? _chat.stopAudio() : _chat.playMessage(message),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    message.text,
                    style: user ? null : const TextStyle(color: Colors.white),
                  ),
                ),
                if (!user) ...[
                  const SizedBox(width: 6),
                  Icon(
                    talking
                        ? Icons.stop_circle_outlined
                        : Icons.volume_up_outlined,
                    size: 16,
                    color: Colors.white70,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildComposer(
    BuildContext context,
    BackendConfig config,
    String? reason,
    bool enabled,
  ) => SafeArea(
    key: const Key('composer-overlay'),
    top: false,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
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
                filled: true,
                fillColor: Color(0xDDFFFFFF),
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
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send, color: Colors.white),
          ),
          Listener(
            onPointerDown: enabled ? _pointerDown : null,
            onPointerMove: enabled ? _pointerMove : null,
            onPointerUp: enabled ? _pointerUp : null,
            onPointerCancel: enabled ? _pointerUp : null,
            child: Semantics(
              button: true,
              label: reason ?? 'Giữ để nói',
              child: CircleAvatar(
                key: const Key('ptt-button'),
                backgroundColor: _cancelPtt
                    ? Theme.of(context).colorScheme.error
                    : enabled
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(
                  _chat.recording ? Icons.mic : Icons.mic_none,
                  color: enabled ? Colors.white : Colors.black54,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  String? _pttUnavailableReason(BackendConfig config) {
    if (!config.isConfigured) return 'Voice input not configured';
    if (_chat.microphonePermission == MicrophonePermissionState.denied ||
        _chat.microphonePermission == MicrophonePermissionState.restricted) {
      return 'Micro bị từ chối — bật trong Cài đặt để dùng voice.';
    }
    return null;
  }
}

class _TopChrome extends StatelessWidget {
  const _TopChrome({
    required this.config,
    required this.chat,
    required this.developerSurfaces,
    required this.onDemo,
  });
  final BackendConfig config;
  final ChatController chat;
  final bool developerSurfaces;
  final VoidCallback onDemo;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Hana',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const Spacer(),
          if (developerSurfaces)
            IconButton(
              tooltip: 'Character Lab',
              onPressed: () => Navigator.pushNamed(context, '/character-lab'),
              icon: const Icon(Icons.science_outlined, color: Colors.white),
            ),
          IconButton(
            tooltip: 'Cài đặt',
            onPressed: () => Navigator.pushNamed(context, '/settings'),
            icon: const Icon(Icons.settings_outlined, color: Colors.white),
          ),
        ],
      ),
      _BackendStatus(config: config, chat: chat),
      if (chat.error != null)
        Text(
          chat.error!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      if (!config.isConfigured) ...[
        const Text(
          'Backend chưa cấu hình — tin nhắn sẽ báo lỗi cho tới khi cấu hình.',
          style: TextStyle(color: Colors.white70, fontSize: 12),
          textAlign: TextAlign.center,
        ),
        if (developerSurfaces)
          FilledButton(
            key: const Key('mock-conversation'),
            onPressed: onDemo,
            child: const Text('Demo PTT'),
          ),
      ],
    ],
  );
}

class _BackendStatus extends StatelessWidget {
  const _BackendStatus({required this.config, required this.chat});
  final BackendConfig config;
  final ChatController chat;
  @override
  Widget build(BuildContext context) {
    final state = _derive();
    final label = switch (state) {
      BackendConnectionState.connected => 'Backend: Đã kết nối',
      BackendConnectionState.connecting => 'Backend: Đang kết nối',
      BackendConnectionState.offline => 'Backend: Ngoại tuyến',
      BackendConnectionState.misconfigured => 'Backend: Chưa cấu hình',
    };
    final color = switch (state) {
      BackendConnectionState.connected => Colors.green,
      BackendConnectionState.connecting => Colors.orange,
      BackendConnectionState.offline => Colors.red,
      BackendConnectionState.misconfigured => Colors.orange,
    };
    return Container(
      key: const Key('backend-status'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: Colors.black.withValues(alpha: .28),
      child: Row(
        children: [
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  BackendConnectionState _derive() {
    if (!config.isConfigured) return BackendConnectionState.misconfigured;
    if (chat.error != null &&
        (chat.error!.contains('Không kết nối') ||
            chat.error!.contains('Mất kết nối') ||
            chat.error!.contains('Backend chưa cấu hình'))) {
      return BackendConnectionState.offline;
    }
    if (chat.sending || chat.activeTurnId != null) {
      return BackendConnectionState.connecting;
    }
    return BackendConnectionState.connected;
  }
}

class _MediaBootstrapNotice extends StatelessWidget {
  const _MediaBootstrapNotice({required this.status});
  final String status;
  @override
  Widget build(BuildContext context) => Container(
    key: const Key('media-bootstrap-notice'),
    padding: const EdgeInsets.all(8),
    margin: const EdgeInsets.only(bottom: 6),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Character media not downloaded yet — silhouette shown.',
          style: TextStyle(color: Colors.white, fontSize: 12),
        ),
        Text(
          status,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    ),
  );
}

class _SilhouetteFallback extends StatelessWidget {
  const _SilhouetteFallback();
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _SilhouettePainter(
      Theme.of(context).colorScheme.primary.withValues(alpha: .28),
    ),
  );
}

class _SilhouettePainter extends CustomPainter {
  const _SilhouettePainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF1A1220),
    );
    final paint = Paint()..color = color;
    canvas.drawCircle(
      Offset(size.width / 2, size.height * .3),
      size.width * .17,
      paint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height * .7),
        width: size.width * .58,
        height: size.height * .64,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _SilhouettePainter oldDelegate) =>
      oldDelegate.color != color;
}

enum BackendConnectionState { connected, connecting, offline, misconfigured }
