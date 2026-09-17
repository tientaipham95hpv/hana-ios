import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../character/manifest/manifest_models.dart';
import '../character/policy/owner_policy.dart';
import '../voice/voice_preferences.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key, required this.developerSurfaces});

  final bool developerSurfaces;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(ownerPolicyProvider);
    final notifier = ref.read(ownerPolicyProvider.notifier);
    final policySample = ref.watch(manifestProvider).byId['chr_003'];
    final voice = ref.read(voicePreferencesProvider);
    final dailyOverride =
        policySample != null &&
        (policy
                .overrideFor(policySample.assetId)
                ?.allowedModes
                ?.contains(StageContext.daily) ??
            false);
    return AnimatedBuilder(
      animation: voice,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Cài đặt')),
        body: ListView(
          children: [
            ListTile(
              title: const Text('Phản hồi của Hana'),
              subtitle: const Text(
                'AUTO: PTT có giọng, nhập chữ chỉ trả lời chữ.',
              ),
              trailing: DropdownButton<VoiceResponseMode>(
                key: const Key('voice-response-mode'),
                value: voice.responseMode,
                items: const [
                  DropdownMenuItem(
                    value: VoiceResponseMode.auto,
                    child: Text('Tự động'),
                  ),
                  DropdownMenuItem(
                    value: VoiceResponseMode.textOnly,
                    child: Text('Chỉ văn bản'),
                  ),
                  DropdownMenuItem(
                    value: VoiceResponseMode.voiceReply,
                    child: Text('Trả lời bằng giọng'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) voice.setResponseMode(value);
                },
              ),
            ),
            SwitchListTile(
              key: const Key('auto-play-voice'),
              title: const Text('Tự động phát giọng'),
              subtitle: const Text('Tắt để chỉ phát khi bấm nút loa.'),
              value: voice.autoPlayVoice,
              onChanged: voice.setAutoPlayVoice,
            ),
            const Divider(),
            SwitchListTile(
              title: const Text('Relationship stage'),
              subtitle: const Text(
                'Mở pool relationship theo chính sách owner.',
              ),
              value: policy.relationshipStageEnabled,
              onChanged: notifier.setRelationship,
            ),
            SwitchListTile(
              title: const Text('Discreet stage'),
              subtitle: const Text('Chỉ hiển thị silhouette.'),
              value: policy.discreetStageEnabled,
              onChanged: notifier.setDiscreet,
            ),
            ListTile(
              title: const Text('Bảo vệ ảnh chụp màn hình'),
              subtitle: const Text(
                'auto theo thư viện nhạy cảm, luôn bật, hoặc tắt.',
              ),
              trailing: DropdownButton<SecureWindowMode>(
                value: policy.secureWindowMode,
                items: SecureWindowMode.values
                    .map(
                      (mode) =>
                          DropdownMenuItem(value: mode, child: Text(mode.name)),
                    )
                    .toList(),
                onChanged: (mode) {
                  if (mode != null) notifier.setSecureWindowMode(mode);
                },
              ),
            ),
            if (developerSurfaces && policySample != null)
              ListTile(
                key: const Key('per-clip-policy-mock'),
                leading: const Icon(Icons.tune),
                title: const Text('Per-clip policy (mock)'),
                subtitle: Text(
                  dailyOverride
                      ? 'Daily override đang bật cho clip nhạy cảm mẫu.'
                      : 'Thử thêm clip nhạy cảm mẫu vào daily/assistant.',
                ),
                trailing: Icon(
                  dailyOverride ? Icons.check_circle : Icons.chevron_right,
                ),
                onTap: () async {
                  if (dailyOverride) {
                    notifier.setAllowedModes(
                      policySample,
                      policySample.allowedModes,
                      confirmSensitive: true,
                    );
                    return;
                  }
                  await _requestSensitiveDailyOverride(
                    context,
                    notifier,
                    policySample,
                  );
                },
              ),
            const Divider(),
            if (developerSurfaces)
              ListTile(
                key: const Key('private-mode-entry'),
                leading: const Icon(Icons.developer_mode),
                title: const Text('Private developer harness'),
                subtitle: const Text('Chỉ có trong debug build.'),
                onTap: () => Navigator.pushNamed(context, '/private'),
              )
            else
              const ListTile(
                key: Key('private-mode-unavailable'),
                enabled: false,
                leading: Icon(Icons.lock_outline),
                title: Text('Chế độ riêng tư chưa khả dụng'),
              ),
            if (developerSurfaces)
              ListTile(
                key: const Key('ios-voice-lab'),
                leading: const Icon(Icons.record_voice_over_outlined),
                title: const Text('iOS Voice Lab'),
                subtitle: const Text(
                  'Liệt kê giọng vi-VN và điều chỉnh tốc độ, cao độ, âm lượng.',
                ),
                onTap: () => Navigator.pushNamed(context, '/voice-lab'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _requestSensitiveDailyOverride(
    BuildContext context,
    OwnerPolicyNotifier notifier,
    CharacterAsset asset,
  ) async {
    final modes = <StageContext>{
      ...asset.allowedModes,
      StageContext.daily,
      StageContext.assistant,
    };
    try {
      notifier.setAllowedModes(asset, modes, confirmSensitive: false);
    } on SensitiveModeConfirmationRequired {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('confirm_sensitive'),
          content: const Text(
            'Clip này có sensitivity cao hơn pool daily mặc định. '
            'Bạn có chắc muốn bật cho daily/assistant?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Hủy'),
            ),
            FilledButton(
              key: const Key('confirm-sensitive-allow'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Cho phép'),
            ),
          ],
        ),
      );
      if (confirmed ?? false) {
        notifier.setAllowedModes(asset, modes, confirmSensitive: true);
      }
    }
  }
}
