import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../manifest/manifest_loader.dart';
import '../manifest/manifest_models.dart';

abstract interface class CharacterManifestTransport {
  Future<String> fetch(Uri uri);
}

class DioCharacterManifestTransport implements CharacterManifestTransport {
  DioCharacterManifestTransport(this.dio);
  final Dio dio;

  @override
  Future<String> fetch(Uri uri) async {
    final response = await dio.get<String>(
      uri.toString(),
      options: Options(responseType: ResponseType.plain),
    );
    if (response.statusCode != 200 || response.data == null) {
      throw HttpException('manifest HTTP ${response.statusCode}', uri: uri);
    }
    return response.data!;
  }
}

class ManifestSyncResult {
  const ManifestSyncResult({
    required this.manifest,
    required this.manifestHash,
    required this.fromRemote,
    required this.changed,
    this.remoteError,
  });

  final CharacterManifest manifest;
  final String manifestHash;
  final bool fromRemote;
  final bool changed;
  final String? remoteError;
}

/// Owns the last-known-good manifest. A remote response is never committed
/// until schema, path, canonical policy, and current baseline checks all pass.
class CharacterManifestRepository {
  CharacterManifestRepository({
    required this.localFile,
    required this.seedManifest,
    required this.transport,
    this.loader = const CharacterManifestLoader(),
  });

  final File localFile;
  final CharacterManifest seedManifest;
  final CharacterManifestTransport transport;
  final CharacterManifestLoader loader;

  Future<ManifestSyncResult> synchronize(Uri? remoteUri) async {
    var active = seedManifest;
    var activeHash = _manifestIdentity(seedManifest);
    if (await localFile.exists()) {
      final source = await localFile.readAsString();
      final local = loader.load(source, expectedAssetCount: null);
      if (local.isValid) {
        try {
          _validateBaseline(local.manifest!);
          active = local.manifest!;
          activeHash = sha256.convert(utf8.encode(source)).toString();
        } on Object {
          // Invalid local metadata is ignored; the bundled seed remains safe.
        }
      }
    }
    if (remoteUri == null) {
      return ManifestSyncResult(
        manifest: active,
        manifestHash: activeHash,
        fromRemote: false,
        changed: false,
      );
    }
    try {
      final source = await transport.fetch(remoteUri);
      final remote = loader.load(source, expectedAssetCount: null);
      if (!remote.isValid) {
        throw FormatException(remote.error ?? 'invalid remote manifest');
      }
      _validateBaseline(remote.manifest!);
      final remoteHash = sha256.convert(utf8.encode(source)).toString();
      final changed =
          remoteHash != activeHash ||
          remote.manifest!.manifestVersion != active.manifestVersion;
      await _commit(source);
      return ManifestSyncResult(
        manifest: remote.manifest!,
        manifestHash: remoteHash,
        fromRemote: true,
        changed: changed,
      );
    } on Object catch (error) {
      return ManifestSyncResult(
        manifest: active,
        manifestHash: activeHash,
        fromRemote: false,
        changed: false,
        remoteError: error.toString(),
      );
    }
  }

  void _validateBaseline(CharacterManifest candidate) {
    if (candidate.schemaVersion != seedManifest.schemaVersion ||
        candidate.manifestKind != ManifestKind.vault ||
        candidate.assets.length < seedManifest.assets.length) {
      throw const FormatException('canonical manifest baseline missing');
    }
    for (final expected in seedManifest.assets) {
      final actual = candidate.byId[expected.assetId];
      if (actual == null ||
          actual.delivery != expected.delivery ||
          actual.contentSensitivity != expected.contentSensitivity ||
          !_sameSet(actual.allowedModes, expected.allowedModes) ||
          actual.excludedByDefault != expected.excludedByDefault ||
          actual.reviewFlag != expected.reviewFlag ||
          actual.audioStreams != 0) {
        throw FormatException('policy mismatch for ${expected.assetId}');
      }
    }
  }

  bool _sameSet(Set<Object> left, Set<Object> right) =>
      left.length == right.length && left.containsAll(right);

  Future<void> _commit(String source) async {
    await localFile.parent.create(recursive: true);
    final temp = File('${localFile.path}.next');
    await temp.writeAsString(source, flush: true);
    final previous = File('${localFile.path}.previous');
    if (await previous.exists()) await previous.delete();
    if (await localFile.exists()) await localFile.rename(previous.path);
    try {
      await temp.rename(localFile.path);
      if (await previous.exists()) await previous.delete();
    } on Object {
      if (!await localFile.exists() && await previous.exists()) {
        await previous.rename(localFile.path);
      }
      rethrow;
    }
  }

  String _manifestIdentity(CharacterManifest manifest) =>
      '${manifest.schemaVersion}:${manifest.manifestVersion}:'
      '${manifest.assets.map((asset) => '${asset.assetId}:${asset.sha256}').join('|')}';
}
