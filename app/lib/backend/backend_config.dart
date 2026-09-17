enum BackendConnectionState { connected, connecting, offline, misconfigured }

class BackendConfig {
  const BackendConfig({required this.enabled, required this.baseUrl});

  factory BackendConfig.fromEnvironment() => const BackendConfig(
    enabled: bool.fromEnvironment('HANA_BACKEND_ENABLED', defaultValue: false),
    baseUrl: String.fromEnvironment(
      'HANA_BACKEND_BASE_URL',
      defaultValue: '',
    ),
  );

  final bool enabled;
  final String baseUrl;

  bool get isConfigured => enabled && hasValidUrl;

  bool get hasValidUrl => _validUrl(baseUrl);

  BackendConnectionState get initialState {
    if (!enabled) return BackendConnectionState.misconfigured;
    return hasValidUrl
        ? BackendConnectionState.connecting
        : BackendConnectionState.misconfigured;
  }

  static bool _validUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }
}