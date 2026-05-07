import 'package:device_info_plus/device_info_plus.dart';
import 'package:uuid/uuid.dart';

class DeviceUtils {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  static const Uuid _uuid = Uuid();

  static Future<String> getDeviceId() async {
    try {
      // Try to get platform-specific device ID
      if (await _isAndroid()) {
        final androidInfo = await _deviceInfo.androidInfo;
        return androidInfo.id;
      } else if (await _isIOS()) {
        final iosInfo = await _deviceInfo.iosInfo;
        return iosInfo.identifierForVendor ?? _generateDeviceId();
      }
    } catch (e) {
      print('Error getting device ID: $e');
    }

    // Fallback to generated UUID
    return _generateDeviceId();
  }

  static String _generateDeviceId() {
    return _uuid.v4().substring(0, 16).toUpperCase();
  }

  static Future<bool> _isAndroid() async {
    try {
      await _deviceInfo.androidInfo;
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _isIOS() async {
    try {
      await _deviceInfo.iosInfo;
      return true;
    } catch (_) {
      return false;
    }
  }

  static String formatDeviceId(String id) {
    // Format as XXXX-XXXX-XXXX
    if (id.length >= 12) {
      return '${id.substring(0, 4)}-${id.substring(4, 8)}-${id.substring(8, 12)}';
    }
    return id;
  }

  /// Force generate a new device ID (used for self-destruct on iOS)
  static String generateNewDeviceId() {
    return _generateDeviceId();
  }
}
