import 'dart:io';

import 'package:hana_app/character/manifest/manifest_loader.dart';
import 'package:hana_app/character/manifest/manifest_models.dart';

CharacterManifest canonicalManifest() {
  final source = File('assets/character/character_manifest.json')
      .readAsStringSync();
  final result = const CharacterManifestLoader().load(source);
  if (!result.isValid) throw StateError(result.error ?? 'invalid manifest');
  return result.manifest!;
}
