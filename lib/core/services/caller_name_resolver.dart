import 'package:get/get.dart';

import '../utils/string_utils.dart';
import 'local_storage_service.dart';
import 'username_service.dart';

/// Single place that derives a human display name for a peer device id.
///
/// Used by every incoming-call/contact-creation path so they all present the
/// same name: the push path, the foreground socket `call_incoming` path,
/// native-notification callbacks, QR scans, and deep links. Previously each
/// path had its own fallback and the foreground path leaked the wire's raw
/// `callerName` — often the sender's generated `@user_xxxxx` handle — instead
/// of the name the user actually saved.
///
/// Resolution order (first non-placeholder wins):
///   1. the name carried in the wire/QR payload,
///   2. the locally saved contact name for that device id,
///   3. the server profile lookup (UsernameService),
///   4. the deterministic friendly name (always non-empty).
class CallerNameResolver {
  CallerNameResolver._();

  /// Names that carry no identifying value and must never be shown as the
  /// resolved contact name. `generateFriendlyName` output always starts with
  /// `@user_`, so generated handles are treated as placeholders too.
  static bool isPlaceholder(String? name, String deviceId) {
    if (name == null) return true;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return true;
    if (trimmed == deviceId) return true;
    if (trimmed.startsWith('@user_')) return true;
    switch (trimmed) {
      case 'Unknown':
      case 'Unknown User':
      case 'Unknown Device':
      case 'Incoming Call':
      case 'Vant Call':
        return true;
    }
    return false;
  }

  /// Synchronous fast path: payload name -> saved contact name.
  /// Returns null when neither yields a real name (server lookup + friendly
  /// fallback are left to [resolve]).
  static String? resolveSync(
    String deviceId, {
    String? payloadName,
    String? Function(String deviceId)? savedNameLookup,
  }) {
    if (!isPlaceholder(payloadName, deviceId)) return payloadName!.trim();
    final saved = (savedNameLookup ?? _defaultSavedNameLookup)(deviceId);
    if (!isPlaceholder(saved, deviceId)) return saved!.trim();
    return null;
  }

  /// Full resolution: payload -> saved contact -> server profile -> friendly.
  /// Always returns a non-empty name.
  static Future<String> resolve(
    String deviceId, {
    String? payloadName,
    String? Function(String deviceId)? savedNameLookup,
    Future<String?> Function(String deviceId)? serverNameLookup,
  }) async {
    final fast = resolveSync(
      deviceId,
      payloadName: payloadName,
      savedNameLookup: savedNameLookup,
    );
    if (fast != null) return fast;

    try {
      final lookup = serverNameLookup ?? _defaultServerNameLookup;
      final serverName = await lookup(deviceId);
      if (!isPlaceholder(serverName, deviceId)) return serverName!.trim();
    } catch (_) {
      // Server unreachable — fall through to the friendly name.
    }

    return StringUtils.generateFriendlyName(deviceId);
  }

  static String? _defaultSavedNameLookup(String deviceId) {
    try {
      final chat = Get.isRegistered<LocalStorageService>()
          ? Get.find<LocalStorageService>().getChat(deviceId)
          : null;
      if (chat != null && chat.userName.isNotEmpty) return chat.userName;
    } catch (_) {}
    return null;
  }

  static Future<String?> _defaultServerNameLookup(String deviceId) async {
    try {
      final data = await UsernameService.getUsername(deviceId);
      return data?.username;
    } catch (_) {
      return null;
    }
  }
}
