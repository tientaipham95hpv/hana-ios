class BackendConfig {
  const BackendConfig({required this.enabled, required this.baseUrl});

  factory BackendConfig.fromEnvironment() => const BackendConfig(
    enabled: bool.fromEnvironment('HANA_BACKEND_ENABLED', defaultValue: false),
    baseUrl: String.fromEnvironment(
      'HANA_BACKEND_BASE_URL',
      defaultValue: 'http://10.0.2.2:18000',
    ),
  );

  final bool enabled;
  final String baseUrl;
}
