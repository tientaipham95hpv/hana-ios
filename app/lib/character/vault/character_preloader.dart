import '../manifest/manifest_models.dart';
import 'character_vault.dart';
import 'vault_models.dart';

class CharacterPreloader {
  CharacterPreloader(this.vault, {this.maxCandidates = 3});

  final CharacterVault vault;
  final int maxCandidates;

  Future<void> preloadLikely(
    CharacterAsset current, {
    required StageContext mode,
  }) async {
    final states = current.states.keys;
    final currentState = states.isEmpty ? CoreState.idle : states.first;
    final likely = switch (currentState) {
      CoreState.idle => const [
        CoreState.idle,
        CoreState.thinking,
        CoreState.talking,
      ],
      CoreState.thinking => const [
        CoreState.talking,
        CoreState.happy,
        CoreState.idle,
      ],
      CoreState.talking => const [CoreState.happy, CoreState.idle],
      _ => const [CoreState.idle, CoreState.talking],
    };
    final candidates = <CharacterAsset>[];
    for (final state in likely) {
      for (final asset in vault.manifest.assets) {
        if (asset.assetId == current.assetId ||
            asset.excludedByDefault ||
            !asset.allowedModes.contains(mode) ||
            !asset.supportsState(state) ||
            vault.isReady(asset.assetId) ||
            candidates.contains(asset)) {
          continue;
        }
        candidates.add(asset);
        if (candidates.length == maxCandidates) break;
      }
      if (candidates.length == maxCandidates) break;
    }
    if (candidates.isEmpty) return;
    for (final asset in candidates) {
      vault.markPreloading(asset.assetId, true);
    }
    try {
      await vault.downloadAssets(
        candidates,
        scope: VaultDownloadScope(mode: mode),
        pin: false,
      );
    } finally {
      for (final asset in candidates) {
        vault.markPreloading(asset.assetId, false);
      }
    }
  }
}
