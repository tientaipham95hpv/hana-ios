import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hana_app/character/manifest/manifest_loader.dart';
import 'package:hana_app/character/manifest/manifest_models.dart';

import 'support/manifest_fixture.dart';
import 'support/canonical_manifest.dart';
import '../tool/sanitize_phase4_manifest.dart';

void main() {
  const loader = CharacterManifestLoader();

  test('runtime Phase 4 snapshot contains exactly 43 unique assets', () {
    final manifest = canonicalManifest();
    expect(manifest.assets, hasLength(43));
    expect(manifest.byId, hasLength(43));
    expect(manifest.byId.keys.first, 'chr_001');
    expect(manifest.byId.keys.last, 'chr_043');
  });

  test(
    'canonical Phase 4 master yields the identical sanitized runtime schema',
    () {
      final raw = jsonDecode(
        File('../../assets_processed/hana/character_manifest.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(raw['manifest_kind'], 'master');
      final result = loader.load(jsonEncode(sanitizePhase4Manifest(raw)));
      expect(result.isValid, isTrue, reason: result.error);
      expect(result.manifest!.assets, hasLength(43));
      final runtime = canonicalManifest();
      for (final asset in result.manifest!.assets) {
        final bundled = runtime.byId[asset.assetId]!;
        expect(bundled.states, asset.states);
        expect(bundled.technicalQuality, asset.technicalQuality);
        expect(bundled.weight, asset.weight);
        expect((bundled.width, bundled.height), (asset.width, asset.height));
        expect(bundled.sha256, asset.sha256);
      }
    },
  );

  test('malformed JSON fails closed instead of throwing', () {
    final result = loader.load('{oops');
    expect(result.isValid, isFalse);
    expect(result.manifest, isNull);
  });

  test('wrong asset count is invalid', () {
    final result = loader.load(jsonEncode(validManifest()));
    expect(result.isValid, isFalse);
    expect(result.error, contains('exactly 43'));
  });

  test('duplicate asset ID is rejected', () {
    final source = validManifest(count: 2);
    (source['assets']! as List<Object?>)[1] = validAsset(1);
    expect(
      () => loader.parse(source.cast<String, dynamic>(), expectedAssetCount: 2),
      throwsFormatException,
    );
  });

  test('path traversal and Windows absolute path are rejected', () {
    for (final path in ['../chr_001.mp4', r'C:\vault\chr_001.mp4']) {
      final source = validManifest();
      (source['assets']! as List<Object?>)[0] = validAsset(1, {'path': path});
      expect(
        () =>
            loader.parse(source.cast<String, dynamic>(), expectedAssetCount: 1),
        throwsFormatException,
      );
    }
  });

  test('invalid mode and sensitivity fail validation', () {
    for (final patch in [
      {
        'allowed_modes': ['unknown'],
      },
      {'content_sensitivity': 'unknown'},
    ]) {
      final source = validManifest();
      (source['assets']! as List<Object?>)[0] = validAsset(1, patch);
      expect(
        () =>
            loader.parse(source.cast<String, dynamic>(), expectedAssetCount: 1),
        throwsFormatException,
      );
    }
  });

  test('canonical poor/review policy remains present', () {
    final manifest = canonicalManifest();
    expect(manifest.assets.where((asset) => asset.reviewFlag), hasLength(19));
    final poor = manifest.assets
        .where((asset) => asset.technicalQuality == TechnicalQuality.poor)
        .toList();
    expect(poor.map((asset) => asset.assetId), ['chr_011', 'chr_022']);
    expect(poor.every((asset) => asset.excludedByDefault), isTrue);
    expect(poor.every((asset) => asset.kind == PlaybackKind.oneshot), isTrue);
    expect(poor.every((asset) => asset.weight == 0.2), isTrue);
  });

  test('legacy field aliases are rejected fail closed', () {
    final source = validManifest();
    final asset = validAsset(1)
      ..remove('states')
      ..remove('kind')
      ..['candidate_states'] = ['idle']
      ..['playback_kind'] = 'loop'
      ..['technical_quality'] = 'acceptable';
    (source['assets']! as List<Object?>)[0] = asset;
    expect(
      () => loader.parse(source.cast<String, dynamic>(), expectedAssetCount: 1),
      throwsFormatException,
    );
  });

  group('Phase 5.1 cross-field validation', () {
    void rejects(
      Map<String, Object?> patch, {
      Map<String, Object?>? rootPatch,
    }) {
      final source = validManifest()..addAll(rootPatch ?? const {});
      (source['assets']! as List<Object?>)[0] = validAsset(1, patch);
      expect(
        () =>
            loader.parse(source.cast<String, dynamic>(), expectedAssetCount: 1),
        throwsFormatException,
      );
    }

    test('foreign asset path is rejected', () {
      rejects({'path': 'vault/chr_002.mp4'});
    });

    test('wrong delivery prefix is rejected', () {
      rejects({'path': 'private_vault/chr_001.mp4'});
    });

    test('wrong manifest_kind is rejected', () {
      rejects(const {}, rootPatch: {'manifest_kind': 'master'});
    });

    test('bundle/private sensitivity invariant is rejected', () {
      rejects(
        {
          'delivery': 'bundle',
          'content_sensitivity': 'private',
          'path': 'bundle/chr_001.mp4',
          'poster': 'bundle/chr_001.poster.jpg',
          'poster_blur': 'bundle/chr_001.blur.jpg',
        },
        rootPatch: {'manifest_kind': 'bundle'},
      );
    });

    test('private_vault must be private-only', () {
      final source = validManifest()..['manifest_kind'] = 'private_vault';
      (source['assets']! as List<Object?>)[0] = validAsset(1, {
        'delivery': 'private_vault',
        'allowed_modes': ['daily', 'private'],
        'path': 'private_vault/chr_001.mp4',
        'poster': 'private_vault/chr_001.poster.jpg',
        'poster_blur': 'private_vault/chr_001.blur.jpg',
      });
      expect(
        () => loader.parse(
          source.cast<String, dynamic>(),
          expectedAssetCount: 1,
          allowedKinds: const {ManifestKind.privateVault},
        ),
        throwsFormatException,
      );
    });

    test('audio, subtitle, data and attached-picture streams are rejected', () {
      for (final field in [
        'audio_streams',
        'subtitle_streams',
        'data_streams',
        'attached_picture_streams',
      ]) {
        rejects({field: 1});
      }
    });

    test('forbidden shipping metadata is rejected', () {
      for (final field in [
        'source_file',
        'notes',
        'hard_block',
        'sensitivity_source',
      ]) {
        rejects({field: 'forbidden'});
      }
    });

    test('unknown metadata, invalid loop and out-of-range runtime dimensions reject entire manifest', () {
      rejects({'source_asset_map': 'leak'});
      rejects({'loop_quality': 'unknown'});
      rejects({'width': 4096});
      rejects({'duration_ms': 120000});
    });

    test('enum case and delivery_class mismatch are rejected', () {
      rejects({'content_sensitivity': 'PRIVATE'});
      rejects({'delivery_class': 'bundle'});
    });

    test('poster/video extensions cannot be swapped', () {
      rejects({'path': 'vault/chr_001.poster.jpg'});
      rejects({'poster': 'vault/chr_001.mp4'});
    });

    test('manifest failure leaves an empty safe fallback library', () {
      final result = loader.load('{broken');
      final fallback = result.manifest ?? CharacterManifest.empty();
      expect(fallback.assets, isEmpty);
      expect(fallback.manifestVersion, 'invalid-fallback');
    });
  });
}
