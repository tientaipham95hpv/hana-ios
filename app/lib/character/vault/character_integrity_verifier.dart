import 'dart:io';

import 'package:crypto/crypto.dart';

import '../manifest/manifest_models.dart';

class IntegrityResult {
  const IntegrityResult(this.valid, [this.reason]);
  final bool valid;
  final String? reason;
}

class CharacterIntegrityVerifier {
  const CharacterIntegrityVerifier();

  Future<IntegrityResult> verify(CharacterAsset asset, File file) async {
    if (!RegExp(r'^chr_\d{3,}$').hasMatch(asset.assetId)) {
      return const IntegrityResult(false, 'invalid asset_id');
    }
    final filename = file.uri.pathSegments.last;
    if (filename != '${asset.assetId}.mp4' &&
        filename != '${asset.assetId}.mp4.partial') {
      return const IntegrityResult(false, 'unexpected filename');
    }
    if (!await file.exists()) {
      return const IntegrityResult(false, 'missing file');
    }
    final size = await file.length();
    if (size != asset.bytes) {
      return const IntegrityResult(false, 'size mismatch');
    }
    final header = await file
        .openRead(0, size < 32 ? size : 32)
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
    if (header.length < 12 ||
        String.fromCharCodes(header.sublist(4, 8)) != 'ftyp') {
      return const IntegrityResult(false, 'not an MP4 container');
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != asset.sha256) {
      return const IntegrityResult(false, 'sha256 mismatch');
    }
    return const IntegrityResult(true);
  }
}
