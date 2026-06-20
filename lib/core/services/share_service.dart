import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:share_plus/share_plus.dart';
import '../utils/string_utils.dart';
import 'local_storage_service.dart';

class ShareService extends GetxService {
  final LocalStorageService _storageService = Get.find();

  /// Share app with custom deep link
  Future<void> shareApp({Rect? sharePositionOrigin}) async {
    try {
      final deviceId = _storageService.deviceId;
      if (deviceId == null) {
        throw Exception('Device ID not available');
      }

      final friendlyName = StringUtils.generateFriendlyName(deviceId);

      // Use custom URL scheme that will definitely work
      final link = 'pearmessaging://chat?device_id=$deviceId';

      final message = '''Hi! Let's chat on Vant Chat🔒

    I'm $friendlyName. Click this link to start chatting:

    $link

Once installed, the connection will be established automatically, and you can begin messaging me.

Experience total privacy with military-grade encryption and a direct, peer-to-peer connection that bypasses third-party servers entirely.''';

      await Share.share(
        message,
        subject: 'Chat with me on Pear Messaging',
        sharePositionOrigin: sharePositionOrigin,
      );
      debugPrint('✅ App shared successfully with custom scheme: $link');
    } catch (e) {
      debugPrint('❌ Error sharing app: $e');
      Get.snackbar(
        'Share Failed',
        'Unable to share the app. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }
}
