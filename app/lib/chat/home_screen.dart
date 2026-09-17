import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/character_runtime_controller.dart';
import '../app/providers.dart';
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
    final resolution = _runtime.state.lastResolution;
    final backendEnabled = ref.watch(backendConfigProvider).enabled;
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
                SizedBox(
                  height: 260,
                  child: Center(
                    child: SizedBox(
                      width: 146,
                      child: resolution == null
                          ? const AspectRatio(
                              aspectRatio: 9 / 16,
                              child: ColoredBox(color: Color(0xFFE8DCE2)),
                            )
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
                Expanded(
                  child: ListView.builder(
                    key: const Key('chat-messages'),
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _chat.messages.length,
                    itemBuilder: (_, index) {
                      final message = _chat.messages[index];
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
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(child: Text(message.text)),
                                if (message.role == 'assistant' &&
                                    message.turnId != null)
                                  IconButton(
                                    key: Key('speech-${message.id}'),
                                    tooltip:
                                        _runtime.state.activity ==
                                                CoreState.talking &&
                                            _runtime.state.currentTurnId ==
                                                message.turnId
                                        ? 'Dừng giọng nói'
                                        : 'Phát giọng nói',
                                    onPressed:
                                        _runtime.state.activity ==
                                                CoreState.talking &&
                                            _runtime.state.currentTurnId ==
                                                message.turnId
                                        ? _chat.stopAudio
                                        : () => _chat.playMessage(message),
                                    icon: Icon(
                                      _runtime.state.activity ==
                                                  CoreState.talking &&
                                              _runtime.state.currentTurnId ==
                                                  message.turnId
                                          ? Icons.stop_circle_outlined
                                          : Icons.volume_up_outlined,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (backendEnabled)
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
                          onPointerDown: _pointerDown,
                          onPointerMove: _pointerMove,
                          onPointerUp: _pointerUp,
                          onPointerCancel: _pointerUp,
                          child: Semantics(
                            button: true,
                            label: _chat.recording
                                ? (_cancelPtt ? 'Thả để hủy' : 'Thả để gửi')
                                : 'Giữ để nói',
                            child: CircleAvatar(
                              backgroundColor: _cancelPtt
                                  ? Theme.of(context).colorScheme.error
                                  : Theme.of(context).colorScheme.primary,
                              child: Icon(
                                _chat.recording ? Icons.mic : Icons.mic_none,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Chat placeholder'),
                  ),
                if (widget.developerSurfaces && !backendEnabled)
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
}
