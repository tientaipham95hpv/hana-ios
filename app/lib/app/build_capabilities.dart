import 'package:flutter/foundation.dart';

abstract final class BuildCapabilities {
  /// All developer/internal surfaces (Character Lab, Private harness, Voice
  /// Lab) stay gated behind debug builds. Release-profile installs never get
  /// dev navigation entries.
  static const developerSurfaces =
      kDebugMode &&
      bool.fromEnvironment('HANA_ENABLE_DEV_SURFACES', defaultValue: true);

  static bool developerSurfacesFor({
    required bool debugBuild,
    required bool explicitlyEnabled,
  }) => debugBuild && explicitlyEnabled;
}
