import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/canonical_manifest.dart';

import 'package:hana_app/character/stage/asset_repository.dart';

void main() {
  final asset = canonicalManifest().byId['chr_001']!;

  test('mock vault fails closed when an asset is unavailable', () async {
    const repository = MockVaultAssetRepository();
    expect(await repository.resolve(asset), isNull);
    expect(await repository.resolvePoster(asset), isNull);
  });

  test(
    'local dev vault resolves only existing manifest-relative files',
    () async {
      final root = await Directory.systemTemp.createTemp('hana-vault-');
      addTearDown(() => root.delete(recursive: true));
      final vault = Directory('${root.path}/vault')..createSync();
      File('${vault.path}/chr_001.mp4').writeAsBytesSync([0, 1]);
      File('${vault.path}/chr_001.poster.jpg').writeAsBytesSync([2, 3]);
      final media = await LocalDevVaultAssetRepository(root).resolve(asset);
      expect(media, isNotNull);
      expect(media!.video.path, endsWith('chr_001.mp4'));
      expect(media.poster!.path, endsWith('chr_001.poster.jpg'));
    },
  );

  test('production pubspec does not bundle processed videos', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, isNot(contains('assets_processed')));
    expect(pubspec, isNot(contains('/videos')));
    expect(pubspec, isNot(contains('.mp4')));
  });
}
