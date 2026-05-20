import 'dart:io' show Platform;
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'socket_service.dart';

/// Service to track global app lifecycle state
/// Used to suppress notifications on iOS when app is in foreground
/// Also handles iOS-specific socket disconnection when app goes to background
class AppLifecycleService extends GetxService with WidgetsBindingObserver {
  static AppLifecycleService get instance => Get.find<AppLifecycleService>();

  final RxBool _isInForeground = false.obs;
  bool get isInForeground => _isInForeground.value;

  @override
  void onInit() {
    super.onInit();
    debugPrint('📱 AppLifecycleService initialized');
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('📱 App lifecycle state changed: $state');

    switch (state) {
      case AppLifecycleState.resumed:
        _isInForeground.value = true;
        debugPrint('📱 App moved to foreground');
        _handleAppResumed();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _isInForeground.value = false;
        debugPrint('📱 App moved to background');
        _handleAppPaused();
        break;
    }
  }

  /// Handle app resumed (foreground) - reconnect socket on iOS
  void _handleAppResumed() {
    if (Platform.isIOS) {
      try {
        if (Get.isRegistered<SocketService>()) {
          final socketService = Get.find<SocketService>();
          debugPrint('📱 iOS: Reconnecting socket after app resumed');
          socketService.forceReconnect();
        }
      } catch (e) {
        debugPrint('⚠️ iOS: Error reconnecting socket on resume: $e');
      }
    }
  }

  /// Handle app paused (background) - disconnect socket on iOS to mark device offline
  void _handleAppPaused() {
    if (Platform.isIOS) {
      try {
        if (Get.isRegistered<SocketService>()) {
          final socketService = Get.find<SocketService>();
          debugPrint(
              '📱 iOS: Disconnecting socket when app goes to background (mark device offline)');
          socketService.disconnect();
        }
      } catch (e) {
        debugPrint('⚠️ iOS: Error disconnecting socket on pause: $e');
      }
    }
  }
}
