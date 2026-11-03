class DeviceUtils {
  /// Server-enforced deviceId format: digits only, 8–20 chars
  /// (`/^\d{8,20}$/`). Platform identifiers (Android `androidInfo.id` build
  /// fingerprints like `BP4A.251205.006`, iOS `identifierForVendor` UUIDs) do
  /// NOT satisfy it — registrations carrying them are rejected outright.
  static final RegExp _validDeviceIdPattern = RegExp(r'^\d{8,20}$');

  static bool isValidDeviceId(String? id) =>
      id != null && _validDeviceIdPattern.hasMatch(id);

  /// Returns a server-valid deviceId (epoch milliseconds). Kept async for
  /// API compatibility with the former platform-ID implementation.
  static Future<String> getDeviceId() async {
    return _generateDeviceId();
  }

  static int _lastGeneratedMs = 0;

  static String _generateDeviceId() {
    var ms = DateTime.now().millisecondsSinceEpoch;
    if (ms <= _lastGeneratedMs) ms = _lastGeneratedMs + 1;
    _lastGeneratedMs = ms;
    return ms.toString();
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
