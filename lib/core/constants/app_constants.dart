class AppConstants {
  // App Configuration
  static const String appName = 'Vant Chat';
  static const String appVersion = '1.0.0';

  // Storage Keys
  static const String deviceIdKey = 'device_id';
  static const String userNameKey = 'user_name';
  static const String onboardingKey = 'onboarding_completed';
  static const String authEnabledKey = 'auth_enabled';

  // Limits
  static const int maxUsernameLength = 30;
  static const int minUsernameLength = 3;
  static const int maxBatchUsernames = 100;

  // Timeouts
  static const int connectionTimeout = 10000; // 10 seconds
  static const int requestTimeout = 10000; // 10 seconds
}
