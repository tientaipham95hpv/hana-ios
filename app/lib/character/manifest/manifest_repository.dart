import 'package:flutter/services.dart';

import 'manifest_loader.dart';

abstract interface class ManifestRepository {
  Future<ManifestLoadResult> loadNormalManifest();
}

class BundledPhase4ManifestRepository implements ManifestRepository {
  const BundledPhase4ManifestRepository({
    this.assetPath = 'assets/character/character_manifest.json',
    this.loader = const CharacterManifestLoader(),
  });

  final String assetPath;
  final CharacterManifestLoader loader;

  @override
  Future<ManifestLoadResult> loadNormalManifest() async {
    try {
      final source = await rootBundle.loadString(assetPath);
      return loader.load(source);
    } on Object catch (error) {
      return ManifestLoadResult.invalid(error);
    }
  }
}

class MemoryManifestRepository implements ManifestRepository {
  const MemoryManifestRepository(this.result);
  final ManifestLoadResult result;

  @override
  Future<ManifestLoadResult> loadNormalManifest() async => result;
}
