import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../character/manifest/manifest_loader.dart';
import '../character/manifest/manifest_models.dart';
import '../character/engine/effect_executor.dart';
import '../character/policy/owner_policy.dart';
import '../character/stage/asset_repository.dart';
import '../character/vault/character_download_manager.dart';
import '../character/vault/character_manifest_repository.dart';
import '../character/vault/character_preloader.dart';
import '../character/vault/character_vault.dart';
import '../character/vault/vault_models.dart';
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

final mediaConfigProvider = Provider<CharacterMediaConfig>(
  (ref) => CharacterMediaConfig.fromEnvironment(),
);

final characterVaultProvider = Provider<CharacterVault>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(minutes: 3),
      headers: const {'Accept': 'application/json, video/mp4'},
    ),
  );
  final vault = CharacterVault(
    seedManifest: ref.read(manifestProvider),
    config: ref.read(mediaConfigProvider),
    rootProvider: () async {
      final support = await getApplicationSupportDirectory();
      return Directory(
        '${support.path}${Platform.pathSeparator}character_media_vault',
      );
    },
    manifestTransport: DioCharacterManifestTransport(dio),
    mediaTransport: DioCharacterMediaTransport(dio),
  );
  ref.onDispose(vault.dispose);
  return vault;
});

final assetRepositoryProvider = Provider<CharacterAssetRepository>((ref) {
  const devRoot = String.fromEnvironment('HANA_DEV_VAULT_ROOT');
  if (kDebugMode && devRoot.isNotEmpty) {
    return LocalDevVaultAssetRepository(Directory(devRoot));
  }
  return ref.read(characterVaultProvider);
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
  final vault = ref.read(characterVaultProvider);
  final preloader = CharacterPreloader(vault);
  final runtime = CharacterRuntimeController(
    manifest: ref.read(manifestProvider),
    ownerPolicy: ref.read(ownerPolicyProvider),
    repository: ref.read(assetRepositoryProvider),
    ports: EngineRuntimePorts(
      onPlay: (resolution) {
        final asset = resolution.playRequest?.asset;
        if (asset != null) {
          unawaited(
            preloader.preloadLikely(asset, mode: resolution.effectiveContext),
          );
        }
      },
    ),
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
