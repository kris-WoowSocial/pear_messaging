import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'invitation_storage_service.dart';

class AppLinkService extends GetxService {
  static const platform =
      MethodChannel('com.pear.messaging.pear_messaging/applinks');

  // Flag to prevent duplicate navigation
  static bool _isNavigating = false;
  static String? _lastProcessedUrl;
  static DateTime? _lastProcessTime;

  /// Initialize the service
  Future<AppLinkService> init() async {
    debugPrint('🔗 App Link Service initialized');
    return this;
  }

  /// Request to be set as default handler for supported links (Android only)
  Future<void> requestDefaultLinkHandler() async {
    // Only available on Android
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        debugPrint('🔗 Requesting default link handler status...');

        // This will prompt the user to set the app as default handler
        await platform.invokeMethod('requestDefaultLinkHandler');
        debugPrint('✅ App link handler request sent');
      } on PlatformException catch (e) {
        debugPrint('❌ Failed to request default link handler: ${e.message}');
      }
    } else {
      debugPrint('🔗 App link handler request not available on iOS');
    }
  }

  /// Check if app is set as default handler (Android only)
  Future<bool> isDefaultLinkHandler() async {
    // Only available on Android
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final result = await platform.invokeMethod('isDefaultLinkHandler');
        return result as bool? ?? false;
      } on PlatformException catch (e) {
        debugPrint('❌ Failed to check default link handler: ${e.message}');
        return false;
      }
    } else {
      debugPrint('🔗 App link handler check not available on iOS');
      return true; // On iOS, assume app can handle links if installed
    }
  }

  /// Get initial link when app starts (fallback for Branch)
  Future<void> handleInitialLink() async {
    try {
      debugPrint('🔗 Checking for initial app link...');

      // Get initial link from platform
      final String? initialLink = await platform.invokeMethod('getInitialLink');

      if (initialLink != null && initialLink.isNotEmpty) {
        debugPrint('🔗 Found initial link: $initialLink');

        // Check for duplicate processing
        final now = DateTime.now();
        if (_isNavigating &&
            _lastProcessedUrl == initialLink &&
            _lastProcessTime != null &&
            now.difference(_lastProcessTime!).inSeconds < 3) {
          debugPrint('📋 Duplicate initial link detected, skipping processing');
          return;
        }

        // Set processing flags
        _isNavigating = true;
        _lastProcessedUrl = initialLink;
        _lastProcessTime = now;

        // Try to store invitation from URL
        try {
          if (Get.isRegistered<InvitationStorageService>()) {
            final invitationService = Get.find<InvitationStorageService>();
            await invitationService.storeInvitationFromUrl(initialLink);
          } else {
            debugPrint('⚠️ InvitationStorageService not registered yet');
          }
        } catch (e) {
          debugPrint('⚠️ Could not store invitation from initial link: $e');
        } finally {
          // Reset processing flags
          _isNavigating = false;
          _lastProcessedUrl = null;
          _lastProcessTime = null;
        }
      } else {
        debugPrint('🔗 No initial link found');
      }
    } on PlatformException catch (e) {
      debugPrint('❌ Failed to get initial link: ${e.message}');
    } catch (e) {
      debugPrint('❌ Error handling initial link: $e');
    }
  }
}
