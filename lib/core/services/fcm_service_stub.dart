import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Minimal FCM Service stub - Firebase Messaging temporarily disabled
class FCMService extends GetxService {
  String? _fcmToken;

  String? get fcmToken => _fcmToken;

  /// Initialize FCM service (stub)
  Future<FCMService> init() async {
    debugPrint('⚠️ FCM Service is temporarily disabled');
    debugPrint('✅ FCM Service stub initialized');
    return this;
  }

  /// Register token if available (stub)
  Future<void> registerTokenIfAvailable() async {
    debugPrint('⚠️ FCM token registration temporarily disabled');
  }
}
