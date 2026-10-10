import 'package:crypto/crypto.dart';
import 'dart:convert';

class StringUtils {
  /// Converts a device ID into a user-friendly identifier
  /// Format: @user_[first 4 chars of hash]
  /// Example: @user_a7b2
  static String formatDeviceId(String deviceId) {
    // Create a hash of the device ID
    final bytes = utf8.encode(deviceId);
    final hash = sha256.convert(bytes).toString();

    // Take first 4 characters of the hash
    final shortHash = hash.substring(0, 4);

    // Return formatted identifier
    return '@user_$shortHash';
  }

  /// Generates a friendly name from a device ID
  /// Format: @user_[last 5 chars of device ID]
  /// Example: @user_abc12
  static String generateFriendlyName(String deviceId) {
    final suffix = deviceId.length >= 5
        ? deviceId.substring(deviceId.length - 5)
        : deviceId;
    return '@user_$suffix';
  }

  /// Formats a device ID for display in UI
  /// If userName is provided and not default, returns "userName"
  /// If userName is not provided or is default, returns friendly name
  static String formatDeviceIdWithName(String deviceId, [String? userName]) {
    if (userName != null && userName.isNotEmpty && userName != deviceId) {
      return userName;
    }
    return generateFriendlyName(deviceId);
  }
}
