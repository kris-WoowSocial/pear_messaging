import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api_service.dart';
import 'local_storage_service.dart';
import 'socket_service.dart';
import '../../features/chat_list/chat_list_controller.dart';

/// Centralized reactive profile (avatar) cache.
///
/// Every [VantAvatar] in the app reads from [avatarByDeviceId], so a single
/// `profile_updated` socket event instantly re-renders every mounted avatar
/// for that user — chat list, chat app bar, call screens, call history, QR
/// cards — without a restart or manual refresh.
///
/// On top of the URL map sits a persistent local-file cache
/// ([localAvatarFileByDeviceId]): because the backend issues immutable
/// avatar URLs (a change always yields a new URL), a stored file whose
/// recorded URL still matches is guaranteed current — so avatars render
/// straight from disk on frame 1 with zero network traffic.
class UserProfileCache extends GetxService {
  /// deviceId -> avatarUrl ('' means explicitly no avatar).
  final RxMap<String, String> avatarByDeviceId = <String, String>{}.obs;

  /// deviceId -> last-updated millis, for staleness checks.
  final RxMap<String, int> avatarUpdatedAt = <String, int>{}.obs;

  /// The signed-in user's own avatar URL (persisted).
  final RxString myAvatarUrl = ''.obs;

  /// deviceId -> absolute path of the locally cached avatar image.
  /// Persisted in SharedPreferences so it survives restarts.
  final RxMap<String, String> localAvatarFileByDeviceId =
      <String, String>{}.obs;

  LocalStorageService get _storage => Get.find<LocalStorageService>();

  Directory? _avatarDir;
  Future<Directory>? _avatarDirFuture;
  final Set<String> _downloadInFlight = {};

  Future<UserProfileCache> init() async {
    // Restore own avatar + hydrate the map from persisted chats.
    myAvatarUrl.value = _storage.getUserAvatarUrl() ?? '';
    _hydrateFromChats();
    _hydrateLocalFiles();
    _wireSocket();
    // Precache decoded bitmaps as soon as the first frame exists so even
    // the very first ChatListScreen build shows images, not initials.
    WidgetsBinding.instance.addPostFrameCallback((_) => precacheAvatars());
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
    // Repair pass: any hydrated URL whose local file went missing (cache
    // eviction, reinstall-mismatch) re-downloads once in the background;
    // already-cached entries no-op inside ensureCachedLocally.
    avatarByDeviceId.forEach((id, url) {
      if (url.isNotEmpty) unawaited(ensureCachedLocally(id, url));
    });
    if (myAvatarUrl.value.isNotEmpty) {
      unawaited(
          ensureCachedLocally(_storage.deviceId ?? '', myAvatarUrl.value));
    }
  }

  /// Restore the persisted file map — entries whose file no longer exists
  /// are dropped and re-fetched by the repair pass above.
  void _hydrateLocalFiles() {
    try {
      for (final entry in _storage.getAllContactAvatarFiles().entries) {
        if (File(entry.value.path).existsSync()) {
          localAvatarFileByDeviceId[entry.key] = entry.value.path;
        } else {
          unawaited(_storage.setContactAvatarFile(entry.key, null, null));
        }
      }
    } catch (e) {
      debugPrint('⚠️ UserProfileCache local-file hydrate failed: $e');
    }
  }

  Future<Directory> _avatarsDir() async {
    if (_avatarDir != null) return _avatarDir!;
    return _avatarDirFuture ??= () async {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/vant_avatars');
      if (!dir.existsSync()) await dir.create(recursive: true);
      _avatarDir = dir;
      return dir;
    }();
  }

  /// Download-on-change only: if the stored file was fetched from the same
  /// (immutable) [avatarUrl] and still exists, this is a complete no-op —
  /// no HTTP request, no file churn. A new URL downloads exactly once and
  /// replaces the previous file; an empty URL removes the cached copy.
  Future<void> ensureCachedLocally(String deviceId, String avatarUrl) async {
    if (deviceId.isEmpty) return;
    try {
      final storedPath = _storage.getContactAvatarFile(deviceId);
      final storedUrl = _storage.getContactAvatarFileUrl(deviceId) ?? '';

      if (avatarUrl.isEmpty) {
        if (storedPath != null) {
          try {
            await File(storedPath).delete();
          } catch (_) {}
          await _storage.setContactAvatarFile(deviceId, null, null);
        }
        if (localAvatarFileByDeviceId.containsKey(deviceId)) {
          localAvatarFileByDeviceId.remove(deviceId);
        }
        return;
      }

      if (storedUrl == avatarUrl &&
          storedPath != null &&
          File(storedPath).existsSync()) {
        // Same immutable URL + live file: nothing to do, zero network.
        if (localAvatarFileByDeviceId[deviceId] != storedPath) {
          localAvatarFileByDeviceId[deviceId] = storedPath;
        }
        return;
      }
      if (!_downloadInFlight.add(deviceId)) return;
      try {
        final response = await http
            .get(Uri.parse(avatarUrl))
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          return;
        }
        final dir = await _avatarsDir();
        final name =
            '${deviceId}_${avatarUrl.hashCode.abs().toRadixString(16)}.jpg';
        final file = File('${dir.path}/$name');
        // Grab the context before the write — it's only used to build the
        // ImageConfiguration for precacheImage below.
        final ctx = Get.context;
        await file.writeAsBytes(response.bodyBytes, flush: true);
        await _storage.setContactAvatarFile(deviceId, file.path, avatarUrl);
        // Warm the decode BEFORE pointing the reactive map at the new file —
        // Obx swaps straight from the old bitmap to this cached one, so the
        // avatar never renders an empty frame while FileImage decodes.
        if (ctx != null) {
          try {
            // Get.context is the global navigator context — it cannot
            // unmount, so the async gap is safe.
            // ignore: use_build_context_synchronously
            await precacheImage(FileImage(file), ctx);
          } catch (_) {}
        }
        localAvatarFileByDeviceId[deviceId] = file.path;
        // Old file deleted only after the map no longer references it —
        // any rebuild before this point still finds the old image on disk.
        if (storedPath != null && storedPath != file.path) {
          try {
            await File(storedPath).delete();
          } catch (_) {}
        }
      } finally {
        _downloadInFlight.remove(deviceId);
      }
    } catch (e) {
      debugPrint('⚠️ Avatar local cache failed for $deviceId: $e');
    }
  }

  /// Warm the decoded bitmaps into Flutter's ImageCache ahead of the first
  /// list frame. Called post-runApp; a missing context just skips the warm
  /// (rendering still works — FileImage decodes nearly instantly).
  void precacheAvatars([BuildContext? context]) {
    final ctx = context ?? Get.context;
    if (ctx == null) return;
    try {
      for (final path in localAvatarFileByDeviceId.values) {
        final file = File(path);
        if (file.existsSync()) {
          precacheImage(FileImage(file), ctx);
        }
      }
    } catch (e) {
      debugPrint('⚠️ Avatar precache failed: $e');
    }
  }

  /// Latest known avatar URL for a user ('' when none/unknown).
  String avatarFor(String deviceId, {String? fallback}) {
    final cached = avatarByDeviceId[deviceId];
    if (cached != null) return cached;
    return fallback ?? '';
  }

  /// Pull the freshest server-side profile (username + avatar) for a
  /// contact and apply it — QR/Branch payloads can predate the inviter's
  /// latest photo, so scanning always fetches the live record.
  Future<void> fetchAndCacheProfile(String deviceId) async {
    if (deviceId.isEmpty || !Get.isRegistered<ApiService>()) return;
    try {
      final profile = await Get.find<ApiService>().getProfile(deviceId);
      if (profile == null) return;

      final url =
          (profile['avatarUrl'] ?? profile['avatar_url'] ?? '').toString();
      final updated =
          profile['avatarUpdatedAt'] ?? profile['avatar_updated_at'];
      final updatedMs = updated is int
          ? updated
          : int.tryParse(updated?.toString() ?? '');

      // Already current — no churn.
      if (url == (avatarByDeviceId[deviceId] ?? '') &&
          (updatedMs == null || updatedMs <= (avatarUpdatedAt[deviceId] ?? 0))) {
        return;
      }

      avatarByDeviceId[deviceId] = url;
      if (updatedMs != null) avatarUpdatedAt[deviceId] = updatedMs;
      if (deviceId == _storage.deviceId) {
        myAvatarUrl.value = url;
        await _storage.setUserAvatarUrl(url.isEmpty ? null : url);
      }
      await _persistToChat(deviceId, url);
      unawaited(ensureCachedLocally(deviceId, url));
      _refreshLists();
    } catch (e) {
      debugPrint('⚠️ fetchAndCacheProfile failed for $deviceId: $e');
    }
  }

  /// Socket + manual entry point: apply a profile_updated payload
  /// ({ userId, deviceId, userName, avatarUrl, avatarUpdatedAt }).
  Future<void> applyProfileUpdate(Map<String, dynamic> data) async {
    final deviceId =
        (data['deviceId'] ?? data['userId'] ?? '').toString();
    if (deviceId.isEmpty) return;

    // Only payloads that explicitly carry avatarUrl may change the avatar —
    // a name-only update must never be read as "avatar removed".
    if (!data.containsKey('avatarUrl') && !data.containsKey('avatar_url')) {
      return;
    }
    var url = (data['avatarUrl'] ?? data['avatar_url'] ?? '').toString();
    final updated = data['avatarUpdatedAt'] ?? data['avatar_updated_at'];
    final updatedMs = updated is int
        ? updated
        : int.tryParse(updated?.toString() ?? '');

    // Staleness guard — ignore out-of-order older updates.
    final known = avatarUpdatedAt[deviceId];
    if (updatedMs != null && known != null && updatedMs <= known) return;

    // Own-avatar protection: a bare `{avatarUrl: null, avatarUpdatedAt:
    // null}` is indistinguishable from a device that simply never uploaded
    // — it must not strip a locally-uploaded photo. Real local removals go
    // through removePhoto() -> setAvatar(null) anyway.
    if (deviceId == _storage.deviceId &&
        url.isEmpty &&
        myAvatarUrl.value.isNotEmpty &&
        updatedMs == null) {
      url = myAvatarUrl.value;
    }

    avatarByDeviceId[deviceId] = url;
    if (updatedMs != null) avatarUpdatedAt[deviceId] = updatedMs;

    // Own avatar?
    if (deviceId == _storage.deviceId) {
      myAvatarUrl.value = url;
      await _storage.setUserAvatarUrl(url.isEmpty ? null : url);
    }

    // Persist onto the 1:1 ChatEntity so the change survives restarts.
    await _persistToChat(deviceId, url);
    unawaited(ensureCachedLocally(deviceId, url));

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
    unawaited(ensureCachedLocally(deviceId, url ?? ''));
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
      socket.onProfilesDeltaSync = (data) => applyProfilesDelta(data);
    } catch (e) {
      debugPrint('⚠️ UserProfileCache: socket not ready, will rely on sync');
    }
  }

  /// Server-time cursor sent on every socket register — the server answers
  /// `profiles_delta_sync` with only peers whose avatar changed after it.
  int? get lastProfileSyncAt => _storage.getLastProfileSyncAt();

  /// Apply the batched `profiles_delta_sync` payload (one packet on socket
  /// register) and advance the cursor to the server-provided time. Each
  /// profile flows through applyProfileUpdate, so timestamps, Hive writes
  /// and the atomic file swap all behave exactly like live updates.
  Future<void> applyProfilesDelta(Map<String, dynamic> data) async {
    final profiles = data['profiles'];
    if (profiles is List) {
      for (final p in profiles) {
        if (p is Map) {
          await applyProfileUpdate(Map<String, dynamic>.from(p));
        }
      }
    }

    final raw = data['serverTime'];
    final ms = raw is int
        ? raw
        : int.tryParse(raw?.toString() ?? '') ??
            DateTime.tryParse(raw?.toString() ?? '')?.millisecondsSinceEpoch;
    if (ms != null) {
      await _storage.setLastProfileSyncAt(ms);
    }
  }
}
