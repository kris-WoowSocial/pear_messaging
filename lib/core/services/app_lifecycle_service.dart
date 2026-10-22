import 'dart:io' show Platform;
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'feature_flag_service.dart';
import 'socket_service.dart';
import 'local_storage_service.dart';
import 'webrtc_call_service.dart';
import 'fcm_service.dart';

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
        FCMService.isAppInForeground = true;
        if (Get.isRegistered<SocketService>()) {
          Get.find<SocketService>().setAppForeground(true);
        }
        debugPrint('📱 App moved to foreground');
        _handleAppResumed();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _isInForeground.value = false;
        FCMService.isAppInForeground = false;
        if (Get.isRegistered<SocketService>()) {
          Get.find<SocketService>().setAppForeground(false);
        }
        debugPrint('📱 App moved to background');
        _handleAppPaused();
        break;
    }
  }

  /// Handle app resumed (foreground) - reconnect socket on iOS and restore audio state
  void _handleAppResumed() async {
    // Refresh feature flags — the 1h fetch interval is the floor, resume
    // brings fresh values sooner (a flag flip is the rollback switch).
    try {
      if (Get.isRegistered<FeatureFlagService>()) {
        await Get.find<FeatureFlagService>().refresh();
      }
    } catch (_) {}
    // Retry the encrypted peer-identity pin store — the app may have been
    // in a locked-device window at launch where the cipher key was
    // unreadable. Covers both platforms and post-first-unlock recovery.
    try {
      if (Get.isRegistered<LocalStorageService>()) {
        await Get.find<LocalStorageService>().retryPeerIdentityStore();
      }
    } catch (_) {}
    if (Platform.isIOS) {
      try {
        if (_isCallActive()) {
          debugPrint(
            '📱 iOS: Skipping socket reconnect on resume — call is active',
          );
          return;
        }
        if (Get.isRegistered<SocketService>()) {
          final socketService = Get.find<SocketService>();
          if (!socketService.isConnected.value) {
            debugPrint('📱 iOS: Connecting socket after app resumed');
            socketService.connect();
          }
        }
      } catch (e) {
        debugPrint('⚠️ iOS: Error reconnecting socket on resume: $e');
      }
    }
    
    // Restore audio speaker state when app resumes (Android & iOS)
    if (_isCallActive()){
      try {
        final callService = WebRTCCallService();
        final originalSpeakerState = callService.isSpeakerOn;
        debugPrint('📱 Restoring speaker state after app resume: $originalSpeakerState');
        // Force audio configuration to restore speaker state
        await callService.setSpeaker(originalSpeakerState);
      } catch (e) {
        debugPrint('⚠️ Error restoring speaker state on resume: $e');
      }
    }
  }

  /// Handle app paused (background) - disconnect socket on iOS to mark device offline
  void _handleAppPaused() {
    if (Platform.isIOS) {
      try {
        // Do not disconnect socket if a call is active — it would terminate the call
        if (_isCallActive()) {
          debugPrint('📱 iOS: Skipping socket disconnect — call is active');
          return;
        }
        if (Get.isRegistered<SocketService>()) {
          debugPrint('📱 iOS: Preserving socket for VoIP CallKit signaling');
        }
      } catch (e) {
        debugPrint('⚠️ iOS: Error disconnecting socket on pause: $e');
      }
    }
    
    // On Android, ensure audio mode is maintained when app goes to background during call
    if (Platform.isAndroid && _isCallActive()) {
      try {
        final callService = WebRTCCallService();
        debugPrint('📱 Android: Maintaining audio speaker state in background: ${callService.isSpeakerOn}');
        // Re-apply the current speaker state to ensure it persists in background
        callService.setSpeaker(callService.isSpeakerOn);
      } catch (e) {
        debugPrint('⚠️ Error maintaining speaker state on pause: $e');
      }
    }
  }

  /// Check if a WebRTC call is currently active
  bool _isCallActive() {
    try {
      return WebRTCCallService().isInCall;
    } catch (_) {
      return false;
    }
  }
}
