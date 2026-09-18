import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import 'app/hana_app.dart';
import 'app/providers.dart';
import 'character/manifest/manifest_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  final manifest = await const BundledPhase4ManifestRepository()
      .loadNormalManifest();
  runApp(
    ProviderScope(
      overrides: [manifestLoadResultProvider.overrideWithValue(manifest)],
      child: const HanaApp(),
    ),
  );
}
