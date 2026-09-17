import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../character/manifest/manifest_loader.dart';
import '../character/manifest/manifest_models.dart';
import '../character/policy/owner_policy.dart';
import '../character/stage/asset_repository.dart';
import 'character_runtime_controller.dart';
import '../backend/backend_config.dart';
import '../backend/hana_backend_client.dart';
import '../chat/chat_controller.dart';
import '../voice/tts_queue.dart';
import '../voice/ios_native_tts.dart';
import '../voice/voice_preferences.dart';
import '../voice/voice_recorder.dart';
import '../core/secure_store.dart';

final backendConfigProvider = Provider<BackendConfig>(
  (ref) => BackendConfig.fromEnvironment(),
);

final backendClientProvider = Provider<HanaBackendClient>((ref) {
  final config = ref.watch(backendConfigProvider);
  return HanaBackendClient(
    dio: Dio(
      BaseOptions(
        baseUrl: config.baseUrl,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 35),
        headers: const {'Accept': 'application/json'},
      ),
    ),
  );
});

final manifestLoadResultProvider = Provider<ManifestLoadResult>(
  (ref) => ManifestLoadResult.invalid('manifest has not been loaded'),
);

final manifestProvider = Provider<CharacterManifest>(
  (ref) =>
      ref.watch(manifestLoadResultProvider).manifest ??
      CharacterManifest.empty(),
);

final assetRepositoryProvider = Provider<CharacterAssetRepository>((ref) {
  const devRoot = String.fromEnvironment('HANA_DEV_VAULT_ROOT');
  if (kDebugMode && devRoot.isNotEmpty) {
    return LocalDevVaultAssetRepository(Directory(devRoot));
  }
  return const MockVaultAssetRepository();
});

class OwnerPolicyNotifier extends Notifier<OwnerPolicy> {
  @override
  OwnerPolicy build() => const OwnerPolicy();

  void setRelationship(bool enabled) =>
      state = state.copyWith(relationshipStageEnabled: enabled);

  void setDiscreet(bool enabled) =>
      state = state.copyWith(discreetStageEnabled: enabled);

  void setBlockScreenshots(bool enabled) => state = state.copyWith(
    secureWindowMode: enabled ? SecureWindowMode.always : SecureWindowMode.off,
  );

  void setSecureWindowMode(SecureWindowMode mode) =>
      state = state.copyWith(secureWindowMode: mode);

  void enableAsset(String assetId, bool enabled) =>
      state = state.setAssetEnabled(assetId, enabled);

  void setAllowedModes(
    CharacterAsset asset,
    Set<StageContext> modes, {
    required bool confirmSensitive,
  }) => state = state.setAssetAllowedModes(
    asset,
    modes,
    confirmSensitive: confirmSensitive,
  );

  void setWeight(String assetId, double multiplier) =>
      state = state.setAssetWeight(assetId, multiplier);
}

final ownerPolicyProvider = NotifierProvider<OwnerPolicyNotifier, OwnerPolicy>(
  OwnerPolicyNotifier.new,
);

final characterRuntimeProvider = Provider<CharacterRuntimeController>((ref) {
  final runtime = CharacterRuntimeController(
    manifest: ref.read(manifestProvider),
    ownerPolicy: ref.read(ownerPolicyProvider),
    repository: ref.read(assetRepositoryProvider),
  );
  ref.onDispose(runtime.dispose);
  return runtime;
});

final voicePreferencesProvider = Provider<VoicePreferences>((ref) {
  final preferences = VoicePreferences(
    store: const SecureVoicePreferenceStore(HanaSecureStore()),
  );
  preferences.load();
  ref.onDispose(preferences.dispose);
  return preferences;
});

final ttsQueueProvider = Provider<TtsQueue>((ref) {
  final queue = Platform.isIOS ? IosNativeTtsQueue() : HanaTtsQueue();
  ref.onDispose(queue.dispose);
  return queue;
});

final chatControllerProvider = Provider<ChatController>((ref) {
  final controller = ChatController(
    client: ref.read(backendClientProvider),
    runtime: ref.read(characterRuntimeProvider),
    tts: ref.read(ttsQueueProvider),
    recorder: PlatformVoiceRecorder(),
    preferences: ref.read(voicePreferencesProvider),
    configureAudio: ref.read(backendConfigProvider).enabled,
  );
  ref.onDispose(controller.dispose);
  return controller;
});
