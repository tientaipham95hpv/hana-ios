import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../engine/character_cue.dart';
import '../engine/clock.dart';
import '../engine/engine_event.dart';
import '../engine/session_manager.dart';
import '../manifest/manifest_models.dart';
import '../policy/owner_policy.dart';
import '../resolver/asset_resolver.dart';
import '../resolver/random_source.dart';
import '../stage/video_stage.dart';
import '../vault/vault_models.dart';
import '../../private_mode/private_session.dart';

class CharacterLabScreen extends ConsumerStatefulWidget {
  const CharacterLabScreen({super.key});

  @override
  ConsumerState<CharacterLabScreen> createState() => _CharacterLabScreenState();
}

class _CharacterLabScreenState extends ConsumerState<CharacterLabScreen> {
  final _resolver = AssetResolver(SeededRandomSource(2026));
  var _mode = StageContext.daily;
  var _state = CoreState.idle;
  var _emotion = Emotion.neutral;
  var _intensity = Intensity.low;
  String? _specialCue;
  ResolutionResult? _resolution;
  List<String> _demoTrace = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolution ??= _resolve(ref.read(ownerPolicyProvider));
  }

  ResolutionResult _resolve(OwnerPolicy policy) {
    final manifest = ref.read(manifestProvider);
    final ready = manifest.byId.keys.toSet();
    return _resolver.resolve(
      ResolverInput(
        manifest: manifest,
        requestedState: _state,
        stageContext: _mode,
        ownerPolicy: policy,
        readyAssetIds: ready,
        readyPosterIds: ready,
        brokenAssetIds: const {},
        recentUsage: _resolution?.assetId == null
            ? const []
            : [_resolution!.assetId!],
        privateSessionActive: _mode == StageContext.private,
        intensity: _intensity,
      ),
    );
  }

  void _refresh([OwnerPolicy? policy]) {
    setState(
      () => _resolution = _resolve(policy ?? ref.read(ownerPolicyProvider)),
    );
  }

  void _runEngineDemo() {
    final manifest = ref.read(manifestProvider);
    final policy = ref.read(ownerPolicyProvider);
    final session = CharacterEngineSessionManager(
      normalManifest: manifest,
      ownerPolicy: policy,
      clock: FakeClock(DateTime.utc(2026)),
      seed: 9,
    ).normal;
    session.state = session.state.copyWith(
      readyAssetIds: manifest.byId.keys.toSet(),
      readyPosterIds: manifest.byId.keys.toSet(),
    );
    final states = <String>[];
    void fire(EngineEvent event) {
      session.dispatch(event);
      states.add(session.state.activity.name);
    }

    fire(const AppStarted());
    fire(const PttPressed());
    fire(const PttReleased(valid: true));
    fire(const TurnSubmitted('demo'));
    fire(
      const ReplyReady(
        turnId: 'demo',
        cue: CharacterCue(emotion: Emotion.neutral, intensity: Intensity.low),
        willSpeak: true,
      ),
    );
    fire(
      Tick(
        'thinking_min_dwell',
        session.state.timerTokens['thinking_min_dwell']!,
        turnId: session.state.currentTurnId,
      ),
    );
    fire(const TtsStarted('demo'));
    fire(const TtsFinished('demo'));
    fire(
      const CueReceived(
        CharacterCue(emotion: Emotion.happy, intensity: Intensity.medium),
      ),
    );
    final play = session.state.lastResolution?.playRequest;
    if (play != null) fire(ClipEnded(play.asset.assetId, playId: play.playId));
    setState(() => _demoTrace = states);
  }

  void _runWorkDemo() {
    setState(() => _demoTrace = const ['idle', 'working', 'idle']);
  }

  Future<void> _runPrivateIsolationDemo() async {
    final manifest = ref.read(manifestProvider);
    final manager = CharacterEngineSessionManager(
      normalManifest: manifest,
      ownerPolicy: ref.read(ownerPolicyProvider),
      seed: 11,
    );
    final before = manager.normal.state.activity.name;
    final authorization = await DevelopmentPrivateUnlockService().unlock();
    if (authorization == null) return;
    manager.openPrivate(manifest, ref.read(ownerPolicyProvider), authorization);
    manager.privateSession!.dispatch(
      const CueReceived(
        CharacterCue(emotion: Emotion.shy, intensity: Intensity.low),
      ),
    );
    final during = manager.privateSession!.state.activity.name;
    manager.lockPrivate();
    setState(
      () => _demoTrace = [
        before,
        'private:$during',
        'lock',
        manager.normal.state.activity.name,
      ],
    );
  }

  Future<void> _addSelectedToDaily(CharacterAsset asset) async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('confirm_sensitive'),
            content: Text(
              'Cho phép ${asset.assetId} (${asset.contentSensitivity.name}) trong daily/assistant?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Hủy'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Xác nhận'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    ref.read(ownerPolicyProvider.notifier).setAllowedModes(asset, {
      ...asset.allowedModes,
      StageContext.daily,
      StageContext.assistant,
    }, confirmSensitive: true);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(ownerPolicyProvider, (_, next) => _refresh(next));
    final manifest = ref.watch(manifestProvider);
    final vault = ref.watch(characterVaultProvider);
    final result = _resolution!;
    final asset = result.playRequest?.asset ?? result.posterAsset;
    final override = asset == null
        ? null
        : ref.watch(ownerPolicyProvider).overrideFor(asset.assetId);
    return Scaffold(
      appBar: AppBar(title: const Text('Character Lab · debug')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _enumMenu('Mode', _mode, StageContext.values, (value) {
                _mode = value;
                _refresh();
              }),
              _enumMenu('State', _state, CoreState.values, (value) {
                _state = value;
                _refresh();
              }),
              _enumMenu('Emotion', _emotion, Emotion.values, (value) {
                _emotion = value;
                _state = switch (value) {
                  Emotion.happy => CoreState.happy,
                  Emotion.shy => CoreState.shy,
                  Emotion.surprised => CoreState.surprised,
                  Emotion.concerned => CoreState.concerned,
                  Emotion.neutral => _state,
                };
                _refresh();
              }),
              _enumMenu('Intensity', _intensity, Intensity.values, (value) {
                _intensity = value;
                _refresh();
              }),
              DropdownButton<String?>(
                value: _specialCue,
                hint: const Text('Special cue'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('No cue'),
                  ),
                  ...manifest.cues.map(
                    (cue) =>
                        DropdownMenuItem(value: cue.cue, child: Text(cue.cue)),
                  ),
                ],
                onChanged: (value) => setState(() => _specialCue = value),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            height: 280,
            decoration: BoxDecoration(
              color: const Color(0xFFE8DCE2),
              borderRadius: BorderRadius.circular(24),
            ),
            child: result.kind == VisualKind.silhouette
                ? const Center(
                    child: Icon(
                      Icons.person_outline,
                      size: 96,
                      color: Color(0xFF9A5B79),
                    ),
                  )
                : VideoStage(
                    resolution: result,
                    repository: ref.read(assetRepositoryProvider),
                    onEngineEvent: (_) {},
                  ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: asset == null
                  ? Text('Fallback: ${result.fallbackTrace.join(' → ')}')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          asset.assetId,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text('Sensitivity: ${asset.contentSensitivity.name}'),
                        Text(
                          'States: ${asset.states.keys.map((e) => e.name).join(', ')}',
                        ),
                        Text(
                          'Allowed: ${asset.allowedModes.map((e) => e.name).join(', ')}',
                        ),
                        Text(
                          'Weight: ${asset.weight * (override?.weightMultiplier ?? 1)}',
                        ),
                        Text(
                          'Loop grade: ${asset.loopGrade.name.toUpperCase()}',
                        ),
                        Text('Playback: ${asset.kind.name}'),
                        Text('Review: ${asset.reviewFlag}'),
                        Text('Excluded default: ${asset.excludedByDefault}'),
                        Text(
                          'Download: ${vault.statusFor(asset.assetId).name}',
                        ),
                        Text(
                          'Integrity: ${vault.statusFor(asset.assetId) == VaultAssetStatus.ready ? 'verified' : 'not ready'}',
                        ),
                        Text(
                          'Cache: ${vault.isReady(asset.assetId) ? 'local' : 'absent'}',
                        ),
                        Text('Candidate pool: ${result.candidatePoolCount}'),
                        Text('Fallback: ${result.fallbackTrace.join(' → ')}'),
                        OutlinedButton.icon(
                          key: const Key('character-lab-play-test'),
                          onPressed: _refresh,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play / test'),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Per-clip enabled'),
                          value: override?.enabled ?? !asset.excludedByDefault,
                          onChanged: (value) {
                            ref
                                .read(ownerPolicyProvider.notifier)
                                .enableAsset(asset.assetId, value);
                            _refresh();
                          },
                        ),
                        Slider(
                          value: (override?.weightMultiplier ?? 1)
                              .clamp(0, 4)
                              .toDouble(),
                          max: 4,
                          divisions: 16,
                          label: (override?.weightMultiplier ?? 1)
                              .toStringAsFixed(2),
                          onChanged: (value) {
                            ref
                                .read(ownerPolicyProvider.notifier)
                                .setWeight(asset.assetId, value);
                            _refresh();
                          },
                        ),
                        if (asset.contentSensitivity !=
                                ContentSensitivity.normal &&
                            !asset.allowedModes.contains(StageContext.daily))
                          OutlinedButton(
                            onPressed: () => _addSelectedToDaily(asset),
                            child: const Text('Thêm vào daily…'),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _runEngineDemo,
                child: const Text('Demo hội thoại'),
              ),
              OutlinedButton(
                onPressed: _runWorkDemo,
                child: const Text('Demo working'),
              ),
              OutlinedButton(
                onPressed: _runPrivateIsolationDemo,
                child: const Text('Demo private isolation'),
              ),
            ],
          ),
          if (_demoTrace.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Trace: ${_demoTrace.join(' → ')}'),
          ],
        ],
      ),
    );
  }

  Widget _enumMenu<T extends Enum>(
    String label,
    T value,
    List<T> values,
    ValueChanged<T> changed,
  ) => DropdownButton<T>(
    value: value,
    hint: Text(label),
    items: values
        .map(
          (item) => DropdownMenuItem(
            value: item,
            child: Text('$label: ${item.name}'),
          ),
        )
        .toList(),
    onChanged: (value) {
      if (value != null) changed(value);
    },
  );
}
