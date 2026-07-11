enum Flavor { dev, prod }

class FlavorConfig {
  final Flavor flavor;
  final String appName;
  final String apiBaseUrl;
  final bool showDebugBanner;

  static FlavorConfig? _instance;

  factory FlavorConfig({
    required Flavor flavor,
    required String appName,
    required String apiBaseUrl,
    bool showDebugBanner = false,
  }) {
    _instance ??= FlavorConfig._internal(
      flavor: flavor,
      appName: appName,
      apiBaseUrl: apiBaseUrl,
      showDebugBanner: showDebugBanner,
    );
    return _instance!;
  }

  FlavorConfig._internal({
    required this.flavor,
    required this.appName,
    required this.apiBaseUrl,
    required this.showDebugBanner,
  });

  static FlavorConfig get instance {
    assert(_instance != null, 'FlavorConfig not initialized yet');
    return _instance!;
  }

  static bool isDev() => _instance?.flavor == Flavor.dev;
  static bool isProd() => _instance?.flavor == Flavor.prod;
}
