/// Network Configuration Constants
/// Contains all API, socket, and web URL constants
class NetworkConstants {
  // Base URLs
  static const String apiBaseUrl = 'https://vant.chat';
  static const String socketUrl = 'https://vant.chat';

  // Socket Configuration
  static const String socketPath = '/socket/secureconnection';

  // API Endpoints
  static const String apiPath = '/api';
  static const String callsRespondPath = '/api/calls';
  static const String voipTokenPath = '/api/devices/voip-token';

  // Web URLs (for legal pages, sharing, etc.)
  static const String termsUrl = 'https://vant.chat/terms.html';
  static const String privacyPolicyUrl =
      'https://vant.chat/privacy-policy.html';
  static const String chatShareUrl = 'https://vant.chat/chat';

  // App Store URLs
  static const String appStoreReviewUrl = 'https://apps.apple.com/app/id';
  static const String appStoreLookupUrl = 'https://itunes.apple.com/lookup';
  static const String playStoreUrl =
      'https://play.google.com/store/apps/details';

  // Branch.io URLs
  static const String branchApiUrl = 'https://api2.branch.io/v1/url';
  static const String branchWebsiteUrl = 'https://pearmessaging.com';
  static const String branchIconUrl = 'https://pearmessaging.com/icon.png';
}
