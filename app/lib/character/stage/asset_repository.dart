import 'dart:io';

import '../manifest/manifest_models.dart';

class LocalCharacterMedia {
  const LocalCharacterMedia({
    required this.video,
    this.poster,
    this.posterBlur,
  });
  final File video;
  final File? poster;
  final File? posterBlur;
}

abstract interface class CharacterAssetRepository {
  Future<LocalCharacterMedia?> resolve(CharacterAsset asset);
  Future<File?> resolvePoster(CharacterAsset asset);
  Future<File?> resolvePosterBlur(CharacterAsset asset);
}

class MockVaultAssetRepository implements CharacterAssetRepository {
  const MockVaultAssetRepository({
    this.available = const <String, LocalCharacterMedia>{},
  });

  final Map<String, LocalCharacterMedia> available;

  @override
  Future<LocalCharacterMedia?> resolve(CharacterAsset asset) async =>
      available[asset.assetId];

  @override
  Future<File?> resolvePoster(CharacterAsset asset) async =>
      available[asset.assetId]?.poster;

  @override
  Future<File?> resolvePosterBlur(CharacterAsset asset) async =>
      available[asset.assetId]?.posterBlur;
}

class LocalDevVaultAssetRepository implements CharacterAssetRepository {
  LocalDevVaultAssetRepository(this.root);

  final Directory root;

  @override
  Future<LocalCharacterMedia?> resolve(CharacterAsset asset) async {
    final video = _safeFile(asset.path);
    if (video == null || !await video.exists()) return null;
    final poster = _safeFile(asset.poster);
    final blur = _safeFile(asset.posterBlur);
    return LocalCharacterMedia(
      video: video,
      poster: poster != null && await poster.exists() ? poster : null,
      posterBlur: blur != null && await blur.exists() ? blur : null,
    );
  }

  @override
  Future<File?> resolvePoster(CharacterAsset asset) async {
    final poster = _safeFile(asset.poster);
    return poster != null && await poster.exists() ? poster : null;
  }

  @override
  Future<File?> resolvePosterBlur(CharacterAsset asset) async {
    final posterBlur = _safeFile(asset.posterBlur);
    return posterBlur != null && await posterBlur.exists() ? posterBlur : null;
  }

  File? _safeFile(String relative) {
    if (relative.contains('\\') ||
        relative.contains(':') ||
        relative.startsWith('/') ||
        relative.split('/').any((part) => part == '..' || part.isEmpty)) {
      return null;
    }
    final normalizedRoot = root.absolute.path.replaceAll('\\', '/');
    final candidate = File(
      '${root.path}/${relative.replaceAll('/', Platform.pathSeparator)}',
    );
    final normalizedCandidate = candidate.absolute.path.replaceAll('\\', '/');
    if (!normalizedCandidate.startsWith('$normalizedRoot/')) return null;
    return candidate;
  }
}
