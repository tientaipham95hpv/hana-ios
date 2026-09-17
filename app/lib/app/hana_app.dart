import 'package:flutter/material.dart';

import '../character/lab/character_lab_screen.dart';
import '../chat/home_screen.dart';
import '../private_mode/private_mode_screen.dart';
import '../settings/settings_screen.dart';
import '../voice/voice_lab_screen.dart';
import 'build_capabilities.dart';

class HanaApp extends StatelessWidget {
  const HanaApp({super.key, this.developerSurfaces});

  /// Injectable only to verify the release-like route map in widget tests.
  final bool? developerSurfaces;

  @override
  Widget build(BuildContext context) {
    final developerEnabled =
        BuildCapabilities.developerSurfaces && (developerSurfaces ?? true);
    return MaterialApp(
      title: 'Hana',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF9A5B79),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      routes: {
        '/': (_) => HomeScreen(developerSurfaces: developerEnabled),
        '/settings': (_) => SettingsScreen(developerSurfaces: developerEnabled),
        if (developerEnabled) '/private': (_) => const PrivateModeScreen(),
        if (developerEnabled)
          '/character-lab': (_) => const CharacterLabScreen(),
        if (developerEnabled) '/voice-lab': (_) => const VoiceLabScreen(),
      },
      onUnknownRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => const _UnavailableRouteScreen(),
      ),
    );
  }
}

class _UnavailableRouteScreen extends StatelessWidget {
  const _UnavailableRouteScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Không khả dụng')),
    body: const Center(
      child: Text('Tính năng này chưa khả dụng trong bản phát hành.'),
    ),
  );
}
