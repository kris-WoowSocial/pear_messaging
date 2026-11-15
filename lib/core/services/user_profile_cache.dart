import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import 'local_storage_service.dart';
import 'socket_service.dart';
import '../../features/chat_list/chat_list_controller.dart';

/// Centralized reactive profile (avatar) cache.
///
/// Every [VantAvatar] in the app reads from [avatarByDeviceId], so a single
/// `profile_updated` socket event instantly re-renders every mounted avatar
/// for that user — chat list, chat app bar, call screens, call history, QR
/// cards — without a restart or manual refresh.
class UserProfileCache extends GetxService {
  /// deviceId -> avatarUrl ('' means explicitly no avatar).
  final RxMap<String, String> avatarByDeviceId = <String, String>{}.obs;

  /// deviceId -> last-updated millis, for staleness checks.
  final RxMap<String, int> avatarUpdatedAt = <String, int>{}.obs;

  /// The signed-in user's own avatar URL (persisted).
  final RxString myAvatarUrl = ''.obs;

  LocalStorageService get _storage => Get.find<LocalStorageService>();

  Future<UserProfileCache> init() async {
    // Restore own avatar + hydrate the map from persisted chats.
    myAvatarUrl.value = _storage.getUserAvatarUrl() ?? '';
    _hydrateFromChats();
    _wireSocket();
    return this;
  }

  void _hydrateFromChats() {
    try {
      for (final chat in _storage.getAllChats()) {
        final url = chat.avatarUrl;
        if (url != null && url.isNotEmpty) {
          avatarByDeviceId[chat.id] = url;
        }
      }
      // Contact-level avatars saved before their chat existed (QR/Branch).
      avatarByDeviceId.addAll(_storage.getAllContactAvatarUrls());
    } catch (e) {
      debugPrint('⚠️ UserProfileCache hydrate failed: $e');
    }
  }

  /// Latest known avatar URL for a user ('' when none/unknown).
  String avatarFor(String deviceId, {String? fallback}) {
    final cached = avatarByDeviceId[deviceId];
    if (cached != null) return cached;
    return fallback ?? '';
  }

  /// Socket + manual entry point: apply a profile_updated payload
  /// ({ userId, deviceId, userName, avatarUrl, avatarUpdatedAt }).
  Future<void> applyProfileUpdate(Map<String, dynamic> data) async {
    final deviceId =
        (data['deviceId'] ?? data['userId'] ?? '').toString();
    if (deviceId.isEmpty) return;

    final url = (data['avatarUrl'] ?? '').toString();
    final updated = data['avatarUpdatedAt'];
    final updatedMs = updated is int
        ? updated
        : int.tryParse(updated?.toString() ?? '');

    // Staleness guard — ignore out-of-order older updates.
    final known = avatarUpdatedAt[deviceId];
    if (updatedMs != null && known != null && updatedMs <= known) return;

    avatarByDeviceId[deviceId] = url;
    if (updatedMs != null) avatarUpdatedAt[deviceId] = updatedMs;

    // Own avatar?
    if (deviceId == _storage.deviceId) {
      myAvatarUrl.value = url;
      await _storage.setUserAvatarUrl(url.isEmpty ? null : url);
    }

    // Persist onto the 1:1 ChatEntity so the change survives restarts.
    await _persistToChat(deviceId, url);

    // Refresh surfaces that build rows from ChatEntity directly.
    _refreshLists();
  }

  /// Direct setter used by upload/remove flows and invite/QR ingestion.
  Future<void> setAvatar(String deviceId, String? url,
      {int? updatedAt}) async {
    avatarByDeviceId[deviceId] = url ?? '';
    if (updatedAt != null) avatarUpdatedAt[deviceId] = updatedAt;
    if (deviceId == _storage.deviceId) {
      myAvatarUrl.value = url ?? '';
      await _storage.setUserAvatarUrl(url);
    }
    await _persistToChat(deviceId, url ?? '');
    _refreshLists();
  }

  Future<void> _persistToChat(String deviceId, String url) async {
    try {
      // Prefs-backed store survives restarts even before a ChatEntity exists.
      await _storage.setContactAvatarUrl(
          deviceId, url.isEmpty ? null : url);
      final chat = _storage.getChat(deviceId);
      if (chat != null && (chat.avatarUrl ?? '') != url) {
        await _storage.saveChat(
            chat.copyWith(avatarUrl: url.isEmpty ? null : url));
      }
    } catch (e) {
      debugPrint('⚠️ Failed to persist avatar for $deviceId: $e');
    }
  }

  // Every avatar surface reads avatarByDeviceId inside Obx, so the map
  // write alone re-renders them; this hook only nudges lists whose rows are
  // built eagerly from ChatEntity before VantAvatar takes over.
  void _refreshLists() {
    try {
      if (Get.isRegistered<ChatListController>()) {
        Get.find<ChatListController>().loadChats();
      }
    } catch (_) {}
  }

  void _wireSocket() {
    try {
      final socket = Get.find<SocketService>();
      socket.onProfileUpdated = (data) => applyProfileUpdate(data);
    } catch (e) {
      debugPrint('⚠️ UserProfileCache: socket not ready, will rely on sync');
    }
  }
}
