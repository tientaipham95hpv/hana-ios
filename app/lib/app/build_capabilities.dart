import 'package:flutter/foundation.dart';

abstract final class BuildCapabilities {
  static const developerSurfaces =
      kDebugMode &&
      bool.fromEnvironment('HANA_ENABLE_DEV_SURFACES', defaultValue: true);

  static bool developerSurfacesFor({
    required bool debugBuild,
    required bool explicitlyEnabled,
  }) => debugBuild && explicitlyEnabled;
}
