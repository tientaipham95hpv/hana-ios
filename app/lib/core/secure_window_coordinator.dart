import '../character/manifest/manifest_models.dart';
import '../character/policy/owner_policy.dart';
import 'secure_window_service.dart';

class SecureWindowCoordinator {
  const SecureWindowCoordinator({this.service = const SecureWindowService()});

  final SecureWindowPort service;

  bool homeRequiresSecureWindow(
    CharacterManifest manifest,
    OwnerPolicy policy,
  ) {
    switch (policy.secureWindowMode) {
      case SecureWindowMode.always:
        return true;
      case SecureWindowMode.off:
        return false;
      case SecureWindowMode.auto:
        return manifest.assets.any((asset) {
          final enabled =
              policy.overrideFor(asset.assetId)?.enabled ??
              !asset.excludedByDefault;
          return enabled &&
              asset.delivery != Delivery.privateVault &&
              asset.contentSensitivity != ContentSensitivity.normal;
        });
    }
  }

  Future<void> applyHome(CharacterManifest manifest, OwnerPolicy policy) =>
      service.setBlocked(homeRequiresSecureWindow(manifest, policy));

  Future<void> enterPrivate() => service.setBlocked(true);

  Future<void> leavePrivate(CharacterManifest manifest, OwnerPolicy policy) =>
      applyHome(manifest, policy);
}
