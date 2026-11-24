import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:pear_messaging/storage/models/chat_entity.dart';
import 'package:pear_messaging/storage/models/connection_request_entity.dart';
import 'package:pear_messaging/storage/models/group_member_entity.dart';
import 'package:pear_messaging/storage/models/message_entity.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'callkit_service.dart';
import 'username_sync_service.dart';
import 'secure_encryption_service.dart';
import '../utils/string_utils.dart';
import '../utils/device_utils.dart';

class LocalStorageService extends GetxService {
  static const _appGroupChannel = MethodChannel('com.vant.chatting/app_group');
  static const String _chatsBoxName = 'chats';
  static const String _messagesBoxName = 'messages';
  static const String _connectionRequestsBoxName = 'connection_requests';
  static const String _prefsOnboardingKey = 'onboarding_completed';
  static const String _prefsDeviceIdKey = 'device_id';
  static const String _prefsAuthEnabledKey = 'auth_enabled';
  static const String _prefsUserNameKey = 'user_name';
  static const String _prefsProtectCallIpKey = 'protect_call_ip_address';
  static const String _prefsBlockUnknownMessagesKey = 'block_unknown_messages';
  static const String _prefsDisableLinkPreviewsKey = 'disable_link_previews';
  static const String _prefsStrictAccountSettingsKey =
      'strict_account_settings';
  static const String _prefsInstallReferrerCheckedKey =
      'install_referrer_checked';
  static const String _prefsSilenceUnknownCallersKey =
      'silence_unknown_callers';

  late Box _chatsBox;
  late Box _messagesBox;
  late Box _connectionRequestsBox;
  late SharedPreferences _prefs;
  bool _messagesBoxInitialized = false;

  /// Upper bound for entries written to the native contact-name cache.
  static const int _contactNameCacheLimit = 1000;

  /// iOS only: write `callerId -> displayName` into the App Group
  /// UserDefaults (`group.com.vant.chatting`) so PushKit/CallKit can resolve
  /// a saved contact name before Flutter starts. Pass null to remove.
  static Future<void> writeContactNameToAppGroup(
      String deviceId, String? name) async {
    try {
      if (name == null || name.isEmpty) {
        await _appGroupChannel.invokeMethod('removeFromAppGroup', {
          'key': 'chat_name_$deviceId',
        });
      } else {
        await _appGroupChannel.invokeMethod('saveToAppGroup', {
          'key': 'chat_name_$deviceId',
          'value': name,
        });
      }
    } on MissingPluginException {
      // App Group channel only exists on iOS — ignore elsewhere.
    } catch (e) {
      debugPrint('⚠️ App Group contact-name cache write failed: $e');
    }
  }

  /// Extracts `callerId -> displayName` pairs from the `chat_name_*`
  /// SharedPreferences keys, for seeding the native cache. Names only —
  /// no messages, no keys. Exposed for tests.
  static Map<String, String> contactNameCacheEntries(SharedPreferences prefs,
      {int limit = _contactNameCacheLimit}) {
    final result = <String, String>{};
    for (final key in prefs.getKeys()) {
      if (result.length >= limit) break;
      if (!key.startsWith('chat_name_')) continue;
      final id = key.substring('chat_name_'.length);
      final name = prefs.getString(key);
      if (id.isNotEmpty && name != null && name.isNotEmpty) {
        result[id] = name;
      }
    }
    return result;
  }

  /// Seed the App Group name cache from existing saved names. Runs on every
  /// app start so existing contacts (and any direct chat_name_ writes that
  /// bypassed saveChat) stay in sync; idempotent and names-only.
  Future<void> syncContactNamesToAppGroup() async {
    if (!Platform.isIOS) return;
    final entries = contactNameCacheEntries(_prefs);
    for (final entry in entries.entries) {
      await writeContactNameToAppGroup(entry.key, entry.value);
    }
    if (entries.isNotEmpty) {
      debugPrint(
          '📇 Contact-name cache synced to App Group: ${entries.length} names');
    }
  }

  // In-memory index: chatId -> list of message keys for fast lookup
  final Map<String, List<String>> _chatMessageIndex = {};

  Future<LocalStorageService> init() async {
    // Register Hive adapters (without generated files for now)

    // Initialize SharedPreferences FIRST - needed for device ID and terms check
    _prefs = await SharedPreferences.getInstance();

    // Check if iOS self-destruct flag is set and generate new device ID
    if (Platform.isIOS && _prefs.getBool('self_destruct_ios') == true) {
      debugPrint('🔄 iOS self-destruct detected, generating new device ID');
      final newDeviceId = DeviceUtils.generateNewDeviceId();
      await _prefs.setString(_prefsDeviceIdKey, newDeviceId);
      await _prefs.remove('self_destruct_ios'); // Clear the flag
      debugPrint('🆕 New device ID generated: $newDeviceId');
    }

    // Open all boxes at startup so data is ready instantly
    _chatsBox = await Hive.openBox(_chatsBoxName);
    _connectionRequestsBox = await Hive.openBox(_connectionRequestsBoxName);
    try {
      _peerIdentitiesBox = await _openPeerIdentitiesBox();
    } catch (e) {
      // Never fail app init over the pin store — run degraded instead.
      debugPrint('⚠️ Peer identity store unavailable: $e');
      pinStoreUnavailable.value = true;
    }
    _messagesBox = await Hive.openBox(_messagesBoxName);
    _messagesBoxInitialized = true;
    _buildMessageIndex();

    // Seed the native (PushKit-visible) contact-name cache on every start.
    unawaited(syncContactNamesToAppGroup());

    // One-time migration of pre-existing chats into the known-contact
    // allowlist (mirrored natively for killed-app call silencing).
    seedKnownContacts();

    return this;
  }

  /// Open messages box lazily when first needed
  Future<void> _ensureMessagesBoxOpen() async {
    if (!_messagesBoxInitialized) {
      _messagesBox = await Hive.openBox(_messagesBoxName);
      _messagesBoxInitialized = true;
      _buildMessageIndex();
    }
  }

  /// Build in-memory index of chatId -> message keys for fast lookup
  void _buildMessageIndex() {
    _chatMessageIndex.clear();
    for (final key in _messagesBox.keys) {
      try {
        final value = _messagesBox.get(key);
        String? chatId;
        if (value is Map) {
          chatId = value['chatId'] as String?;
        } else if (value is MessageEntity) {
          chatId = value.chatId;
        }
        if (chatId != null) {
          _chatMessageIndex.putIfAbsent(chatId, () => []).add(key.toString());
        }
      } catch (e) {
        debugPrint('⚠️ Error indexing message $key: $e');
      }
    }
    debugPrint(
        '📇 Built message index: ${_chatMessageIndex.length} chats indexed');
  }

  // Onboarding
  bool get isOnboardingCompleted =>
      _prefs.getBool(_prefsOnboardingKey) ?? false;

  Future<void> setOnboardingCompleted(bool value) async {
    await _prefs.setBool(_prefsOnboardingKey, value);
  }

  // Device ID
  String? get deviceId => _prefs.getString(_prefsDeviceIdKey);

  Future<void> setDeviceId(String id) async {
    await _prefs.setString(_prefsDeviceIdKey, id);
    // A created/regenerated device_id needs the VoIP token re-uploaded under
    // the new id — the server keys tokens as voip:<deviceId>.
    if (Platform.isIOS) {
      unawaited(CallKitService().registerCachedVoipToken());
    }
  }

  // Authentication preference
  bool get isAuthEnabled => _prefs.getBool(_prefsAuthEnabledKey) ?? false;

  Future<void> setAuthEnabled(bool enabled) async {
    await _prefs.setBool(_prefsAuthEnabledKey, enabled);
  }

  // "Protect IP address in calls" — when on, WebRTC gathers only relayed
  // (TURN) candidates so the peer never sees the device's real IP.
  bool get protectCallIpAddress =>
      _prefs.getBool(_prefsProtectCallIpKey) ?? false;

  Future<void> setProtectCallIpAddress(bool enabled) async {
    await _prefs.setBool(_prefsProtectCallIpKey, enabled);
  }

  // "Block unknown account messages" (Settings → Advanced): unknown senders
  // are capped at a short burst before excess messages drop silently.
  bool get blockUnknownMessages =>
      _prefs.getBool(_prefsBlockUnknownMessagesKey) ?? false;

  Future<void> setBlockUnknownMessages(bool enabled) async {
    await _prefs.setBool(_prefsBlockUnknownMessagesKey, enabled);
  }

  // "Disable link previews" — never fetch third-party OG metadata so the
  // linked site can't infer this device's IP.
  bool get disableLinkPreviews =>
      _prefs.getBool(_prefsDisableLinkPreviewsKey) ?? false;

  Future<void> setDisableLinkPreviews(bool enabled) async {
    await _prefs.setBool(_prefsDisableLinkPreviewsKey, enabled);
  }

  // "Strict account settings" — master lock that forces the three Advanced
  // switches ON and silences calls/media from non-connections.
  bool get strictAccountSettings =>
      _prefs.getBool(_prefsStrictAccountSettingsKey) ?? false;

  Future<void> setStrictAccountSettings(bool enabled) async {
    await _prefs.setBool(_prefsStrictAccountSettingsKey, enabled);
  }

  // "Silence unknown callers" — enabled via Strict account settings.
  // Effective value: forced ON while strict mode is active.
  bool get silenceUnknownCallers =>
      strictAccountSettings ||
      (_prefs.getBool(_prefsSilenceUnknownCallersKey) ?? false);

  Future<void> setSilenceUnknownCallers(bool enabled) async {
    await _prefs.setBool(_prefsSilenceUnknownCallersKey, enabled);
  }

  // Play Install Referrer is a one-time query — once consumed (or found
  // empty) the flag stops re-checks from re-processing stale invite params.
  bool get hasCheckedInstallReferrer =>
      _prefs.getBool(_prefsInstallReferrerCheckedKey) ?? false;

  Future<void> setHasCheckedInstallReferrer(bool checked) async {
    await _prefs.setBool(_prefsInstallReferrerCheckedKey, checked);
  }

  // "Known contacts" allowlist — the peers we treat as real connections for
  // Strict-mode enforcement (silenced calls, gated media auto-download).
  // Populated by explicit engagement only: accepting/sending a connection
  // request, creating a chat yourself, or replying to someone. A stranger's
  // inbound message alone never grants membership, which is exactly what
  // keeps the strict-mode gates meaningful.
  //
  // Stored as a comma-joined string so the Android FCM service can read it
  // as `flutter.known_contact_ids` from FlutterSharedPreferences while the
  // app is killed (shared_preferences encodes StringList values — a plain
  // String survives as a readable string natively).
  static const String _prefsKnownContactIdsKey = 'known_contact_ids';
  // v2: v1 could mark itself seeded while the seed threw on the unmodifiable
  // empty set, leaving a permanently empty allowlist. The new key forces one
  // re-seed on the next launch for every device — same merge semantics.
  static const String _prefsKnownContactsSeededKey =
      'known_contact_ids_seeded_v2';

  Set<String> get knownContactIds {
    final raw = _prefs.getString(_prefsKnownContactIdsKey) ?? '';
    // Always a mutable copy — markContactKnown/seedKnownContacts add to the
    // returned set before re-joining. Returning `const {}` on the empty path
    // threw "Cannot change an unmodifiable set", which silently aborted the
    // seed while its flag still got written — a permanently empty allowlist
    // that made silence-unknown-callers mute EVERY incoming call.
    if (raw.isEmpty) return <String>{};
    return raw.split(',').where((id) => id.isNotEmpty).toSet();
  }

  bool isKnownContact(String deviceId) =>
      deviceId.isNotEmpty && knownContactIds.contains(deviceId);

  void markContactKnown(String deviceId) {
    if (deviceId.isEmpty || isKnownContact(deviceId)) return;
    final ids = knownContactIds..add(deviceId);
    unawaited(_prefs.setString(_prefsKnownContactIdsKey, ids.join(',')));
  }

  /// One-time migration: chats that existed before this allowlist was
  /// introduced were all user-accepted or user-created, so they seed the
  /// set. Runs once — stranger chats created later (e.g. by the FCM
  /// background path) stay unknown until the user engages.
  void seedKnownContacts() {
    if (_prefs.getBool(_prefsKnownContactsSeededKey) == true) return;
    try {
      final ids = knownContactIds;
      for (final chat in getAllChats()) {
        if (!chat.isGroup) ids.add(chat.id);
      }
      unawaited(
        _prefs.setString(_prefsKnownContactIdsKey, ids.join(',')),
      );
      // Mark seeded only after a successful run — a failed run that still
      // wrote the flag would leave the allowlist permanently empty, and
      // silence-unknown-callers would then mute EVERY incoming call.
      unawaited(_prefs.setBool(_prefsKnownContactsSeededKey, true));
    } catch (e) {
      debugPrint('⚠️ Known-contact seed failed: $e');
    }
  }

  // User name preference
  String? getUserName() {
    return _prefs.getString(_prefsUserNameKey);
  }

  Future<void> setUserName(String name) async {
    await _prefs.setString(_prefsUserNameKey, name);
  }

  /// Current user's own avatar URL (null = initial-letter fallback).
  String? getUserAvatarUrl() {
    return _prefs.getString('user_avatar_url');
  }

  Future<void> setUserAvatarUrl(String? url) async {
    if (url == null || url.isEmpty) {
      await _prefs.remove('user_avatar_url');
    } else {
      await _prefs.setString('user_avatar_url', url);
    }
  }

  /// Persisted avatar URL for a contact — written even before a ChatEntity
  /// exists so invite/QR flows don't lose the photo across restarts.
  String? getContactAvatarUrl(String deviceId) {
    return _prefs.getString('avatar_url_$deviceId');
  }

  Future<void> setContactAvatarUrl(String deviceId, String? url) async {
    if (url == null || url.isEmpty) {
      await _prefs.remove('avatar_url_$deviceId');
    } else {
      await _prefs.setString('avatar_url_$deviceId', url);
    }
  }

  /// All persisted contact avatars (deviceId -> url), for cache hydration.
  Map<String, String> getAllContactAvatarUrls() {
    final map = <String, String>{};
    for (final key in _prefs.getKeys()) {
      if (key.startsWith('avatar_url_')) {
        final value = _prefs.getString(key);
        if (value != null && value.isNotEmpty) {
          map[key.substring('avatar_url_'.length)] = value;
        }
      }
    }
    return map;
  }

  /// Local-file avatar cache — `avatar_file_<id>` is the on-disk path the
  /// image was downloaded to, `avatar_file_url_<id>` the remote URL it was
  /// fetched from. Because avatar URLs are immutable (new URL on every
  /// change), a matching stored URL means the file is still correct and no
  /// re-download is ever needed.
  String? getContactAvatarFile(String deviceId) {
    return _prefs.getString('avatar_file_$deviceId');
  }

  String? getContactAvatarFileUrl(String deviceId) {
    return _prefs.getString('avatar_file_url_$deviceId');
  }

  Future<void> setContactAvatarFile(
    String deviceId,
    String? path,
    String? url,
  ) async {
    if (path == null || path.isEmpty) {
      await _prefs.remove('avatar_file_$deviceId');
      await _prefs.remove('avatar_file_url_$deviceId');
    } else {
      await _prefs.setString('avatar_file_$deviceId', path);
      await _prefs.setString('avatar_file_url_$deviceId', url ?? '');
    }
  }

  /// All persisted avatar file entries (deviceId -> (path, url)), for
  /// cache hydration at startup.
  Map<String, ({String path, String url})> getAllContactAvatarFiles() {
    final map = <String, ({String path, String url})>{};
    for (final key in _prefs.getKeys()) {
      // NB: 'avatar_file_url_' also starts with 'avatar_file_' — check it
      // first or it would be misread as a deviceId containing 'url_'.
      if (key.startsWith('avatar_file_url_')) continue;
      if (key.startsWith('avatar_file_')) {
        final deviceId = key.substring('avatar_file_'.length);
        final path = _prefs.getString(key);
        final url = _prefs.getString('avatar_file_url_$deviceId') ?? '';
        if (path != null && path.isNotEmpty) {
          map[deviceId] = (path: path, url: url);
        }
      }
    }
    return map;
  }

  /// Server-time cursor for the `profiles_delta_sync` socket event (epoch
  /// ms). Sent on every socket register so the server returns only peers
  /// whose avatar changed since the last sync — null means "send everything".
  int? getLastProfileSyncAt() => _prefs.getInt('last_profile_sync_at');

  Future<void> setLastProfileSyncAt(int serverTimeMs) {
    return _prefs.setInt('last_profile_sync_at', serverTimeMs);
  }

  // Last seen timestamp for presence status
  int? getLastSeen(String deviceId) {
    return _prefs.getInt('last_seen_$deviceId');
  }

  Future<void> setLastSeen(String deviceId, int timestamp) async {
    await _prefs.setInt('last_seen_$deviceId', timestamp);
  }

  /// Get display name for a specific device ID
  /// For current device: custom name if set, otherwise generated friendly name
  /// For other devices: use the saved chat contact name, fallback to generated friendly name
  String getDisplayName(String deviceId) {
    // Check if this is the current device
    if (deviceId == this.deviceId) {
      final customName = getUserName();
      if (customName != null && customName.isNotEmpty) {
        return customName;
      }
    }
    // Try the saved 1-on-1 chat name for this device
    final savedChatName = _prefs.getString('chat_name_$deviceId');
    if (savedChatName != null && savedChatName.isNotEmpty) {
      return savedChatName;
    }
    return StringUtils.generateFriendlyName(deviceId);
  }

  // Connection request operations
  List<ConnectionRequestEntity> getPendingConnectionRequests() {
    try {
      final requests = <ConnectionRequestEntity>[];

      for (final value in _connectionRequestsBox.values) {
        try {
          ConnectionRequestEntity request;
          if (value is Map) {
            final jsonMap = Map<String, dynamic>.from(value);
            request = ConnectionRequestEntity.fromJson(jsonMap);
          } else if (value is ConnectionRequestEntity) {
            request = value;
          } else {
            continue;
          }

          // Only return pending requests
          if (request.status == ConnectionRequestStatus.pending) {
            requests.add(request);
          }
        } catch (e) {
          debugPrint('Error parsing connection request: $e');
        }
      }

      return requests;
    } catch (e) {
      debugPrint('Error getting connection requests: $e');
      return [];
    }
  }

  Future<void> saveConnectionRequest(ConnectionRequestEntity request) async {
    try {
      final jsonData = request.toJson();
      await _connectionRequestsBox.put(request.id, jsonData);
      debugPrint('Connection request saved: ${request.id}');
    } catch (e) {
      debugPrint('Error saving connection request: $e');
    }
  }

  Future<void> removeConnectionRequest(String requestId) async {
    try {
      await _connectionRequestsBox.delete(requestId);
      debugPrint('Connection request removed: $requestId');
    } catch (e) {
      debugPrint('Error removing connection request: $e');
    }
  }

  // Chat operations

  /// Check if a chat ID represents a group chat.
  bool isGroupChatId(String chatId) => chatId.startsWith('g_');

  /// Get all group chats stored locally.
  List<ChatEntity> getGroupChats() {
    return getAllChats().where((chat) => chat.isGroupChat).toList();
  }

  List<ChatEntity> getAllChats() {
    try {
      debugPrint(
          '📦 Getting all chats from box. Total items: ${_chatsBox.length}');
      final chats = <ChatEntity>[];

      for (final value in _chatsBox.values) {
        try {
          if (value is Map) {
            // Convert Map to Map<String, dynamic>
            final jsonMap = Map<String, dynamic>.from(value);
            debugPrint('📦 Converting JSON to ChatEntity: $jsonMap');
            chats.add(ChatEntity.fromJson(jsonMap));
          } else if (value is ChatEntity) {
            debugPrint('📦 Found direct ChatEntity');
            chats.add(value);
          } else {
            debugPrint('📦 Unknown data type: ${value.runtimeType}');
          }
        } catch (e) {
          debugPrint('📦 Error parsing chat item: $e, value: $value');
        }
      }

      chats.sort((a, b) {
        if (a.lastMessageTime == null) return 1;
        if (b.lastMessageTime == null) return -1;
        return b.lastMessageTime!.compareTo(a.lastMessageTime!);
      });

      debugPrint('📦 Returning ${chats.length} chats');
      return chats;
    } catch (e) {
      debugPrint('📦 Error getting chats: $e');
      return [];
    }
  }

  ChatEntity? getChat(String chatId) {
    try {
      final chatData = _chatsBox.get(chatId);
      if (chatData == null) return null;

      if (chatData is ChatEntity) {
        return chatData;
      } else if (chatData is Map) {
        final jsonMap = Map<String, dynamic>.from(chatData);
        return ChatEntity.fromJson(jsonMap);
      } else {
        debugPrint('Unknown chat data type: ${chatData.runtimeType}');
        return null;
      }
    } catch (e) {
      debugPrint('Error getting chat: $e');
      return null;
    }
  }

  /// Flip a chat's locked flag (biometric-gated "Locked chats" feature).
  /// No-op when the chat row doesn't exist.
  Future<void> setChatLocked(String chatId, bool locked) async {
    final chat = getChat(chatId);
    if (chat == null || chat.isLocked == locked) return;
    await saveChat(chat.copyWith(isLocked: locked));
  }

  Future<void> saveChat(ChatEntity chat) async {
    try {
      // Preserve the stored avatar when the update doesn't carry one — most
      // ChatEntity reconstructions (message/list refreshes) omit avatarUrl.
      // The prefs store catches avatars that arrived before the chat did.
      var chatToSave = chat;
      if (chat.avatarUrl == null) {
        final preserved =
            getChat(chat.id)?.avatarUrl ?? getContactAvatarUrl(chat.id);
        if (preserved != null) {
          chatToSave = chat.copyWith(avatarUrl: preserved);
        }
      }
      final jsonData = chatToSave.toJson();
      debugPrint('💾 Saving chat: ${chat.id} -> $jsonData');
      await _chatsBox.put(chat.id, jsonData);

      // Also save chat name for background notification access
      if (chat.userName.isNotEmpty && !chat.isGroupChat) {
        await _prefs.setString('chat_name_${chat.id}', chat.userName);
        debugPrint(
            '💾 Chat name saved to SharedPreferences: ${chat.id} -> ${chat.userName}');

        // Mirror to the App Group store so native iOS code (PushKit incoming
        // call, background notification titles) can read it before Flutter.
        if (Platform.isIOS) {
          unawaited(writeContactNameToAppGroup(chat.id, chat.userName));
        }

        // Sync contact name to backend for personalized notification titles
        try {
          final usernameSyncService = Get.find<UsernameSyncService>();
          final myDeviceId = deviceId ?? '';
          if (myDeviceId.isNotEmpty) {
            await usernameSyncService.syncContactName(
                myDeviceId, chat.id, chat.userName);
            debugPrint(
                '🔄 Contact name synced to backend: $myDeviceId calls ${chat.id} as "${chat.userName}"');
          }
        } catch (e) {
          debugPrint('⚠️ Failed to sync contact name to backend: $e');
          // Continue even if sync fails
        }
      }

      debugPrint(
          '💾 Chat saved successfully. Box now has ${_chatsBox.length} items');
    } catch (e) {
      debugPrint('💾 Error saving chat: $e');
    }
  }

  /// Save or update a group chat from backend API data.
  Future<ChatEntity?> saveGroupChatFromApi(
    Map<String, dynamic> apiGroup, {
    String? myDeviceId,
  }) async {
    try {
      final groupId = apiGroup['id'] as String?;
      final name = apiGroup['name'] as String?;
      if (groupId == null || name == null) return null;

      final members = (apiGroup['members'] as List<dynamic>?)
              ?.map((m) => GroupMemberEntity.fromJson(
                  Map<String, dynamic>.from(m as Map)))
              .toList() ??
          [];
      final admins =
          members.where((m) => m.isAdmin).map((m) => m.deviceId).toList();

      final chat = ChatEntity(
        id: groupId,
        userName: name,
        isGroup: true,
        groupName: name,
        members: members,
        admins: admins,
        inviteCode: apiGroup['invite_code']?.toString(),
        avatarUrl: apiGroup['avatar_url']?.toString(),
        maxMembers: apiGroup['max_members'] as int? ?? 50,
        createdBy: apiGroup['created_by']?.toString(),
      );

      final existing = getChat(groupId);
      await saveChat(chat.copyWith(
        lastMessage: existing?.lastMessage,
        lastMessageTime: existing?.lastMessageTime,
        unreadCount: existing?.unreadCount,
      ));
      return chat;
    } catch (e) {
      debugPrint('💾 Error saving group chat from API: $e');
      return null;
    }
  }

  Future<void> deleteChat(String chatId) async {
    try {
      debugPrint('🗑️ Deleting chat: $chatId');
      await _chatsBox.delete(chatId);

      // Also delete all messages for this chat
      final messagesToDelete = <String>[];

      for (final key in _messagesBox.keys) {
        try {
          final value = _messagesBox.get(key);
          String? msgChatId;

          if (value is MessageEntity) {
            msgChatId = value.chatId;
          } else if (value is Map) {
            msgChatId = value['chatId'] as String?;
          }

          if (msgChatId == chatId) {
            messagesToDelete.add(key.toString());
          }
        } catch (e) {
          debugPrint('⚠️ Error checking message $key: $e');
        }
      }

      if (messagesToDelete.isNotEmpty) {
        await _messagesBox.deleteAll(messagesToDelete);
        debugPrint(
            '🗑️ Deleted ${messagesToDelete.length} messages for chat $chatId');
      }

      // Clean up index
      _chatMessageIndex.remove(chatId);

      // Also remove chat name from SharedPreferences
      await _prefs.remove('chat_name_$chatId');
      debugPrint('🗑️ Chat name removed from SharedPreferences: $chatId');
      // On iOS, also remove from App Group UserDefaults
      if (Platform.isIOS) {
        await writeContactNameToAppGroup(chatId, null);
        debugPrint('🗑️ Chat name removed from App Group: $chatId');
      }

      debugPrint('✅ Chat $chatId deleted successfully');
    } catch (e) {
      debugPrint('❌ Error deleting chat $chatId: $e');
      rethrow;
    }
  }

  Future<void> clearAllChats() async {
    await _chatsBox.clear();
    await _messagesBox.clear();
    _chatMessageIndex.clear();
  }

  /// Clear all messages for a specific chat (keep chat object)
  Future<void> clearChatMessages(String chatId) async {
    try {
      debugPrint('🧹 Clearing messages for chat: $chatId');

      // Find and delete all messages for this chat
      final messagesToDelete = <String>[];

      for (final key in _messagesBox.keys) {
        try {
          final value = _messagesBox.get(key);
          String? msgChatId;

          if (value is MessageEntity) {
            msgChatId = value.chatId;
          } else if (value is Map) {
            msgChatId = value['chatId'] as String?;
          }

          if (msgChatId == chatId) {
            messagesToDelete.add(key.toString());
          }
        } catch (e) {
          debugPrint('⚠️ Error checking message $key: $e');
        }
      }

      if (messagesToDelete.isNotEmpty) {
        await _messagesBox.deleteAll(messagesToDelete);
        // Clean up index
        _chatMessageIndex.remove(chatId);
        debugPrint(
            '🧹 Cleared ${messagesToDelete.length} messages for chat $chatId');
      } else {
        debugPrint('🧹 No messages found to clear for chat $chatId');
      }

      debugPrint('✅ Chat messages cleared successfully: $chatId');
    } catch (e) {
      debugPrint('❌ Error clearing chat messages $chatId: $e');
      rethrow;
    }
  }

  // Message operations
  /// Delete every stored message whose `expiresAt` has passed — box rows and
  /// in-memory index entries. Returns the expired message ids (empty when the
  /// box isn't open yet). Messages with `expiresAt == null` are untouched.
  Future<Set<String>> purgeExpiredMessages() async {
    final expired = <String>{};
    try {
      if (!_messagesBoxInitialized) return expired;
      await _ensureMessagesBoxOpen();
      final now = DateTime.now().millisecondsSinceEpoch;
      final keysToDelete = <dynamic>[];
      for (final key in _messagesBox.keys) {
        final value = _messagesBox.get(key);
        if (value is! Map) continue;
        final expiresAt = value['expiresAt'];
        if (expiresAt is int && expiresAt <= now) {
          keysToDelete.add(key);
          expired.add(key.toString());
        }
      }
      if (keysToDelete.isEmpty) return expired;
      await _messagesBox.deleteAll(keysToDelete);
      for (final list in _chatMessageIndex.values) {
        list.removeWhere(expired.contains);
      }
      debugPrint('🗑️ Purged ${keysToDelete.length} expired message(s)');
    } catch (e) {
      debugPrint('🗑️ purgeExpiredMessages error: $e');
    }
    return expired;
  }

  Future<List<MessageEntity>> getChatMessages(String chatId) async {
    final getStart = DateTime.now();
    try {
      // Ensure messages box is opened lazily - this will be synchronous for already opened box
      if (!_messagesBoxInitialized) {
        // If not initialized, return empty list and initialize in background
        _ensureMessagesBoxOpen();
        return [];
      }

      // Drop disappeared messages before they reach the UI
      await purgeExpiredMessages();

      // Use index for fast lookup if available
      final indexStart = DateTime.now();
      final messageKeys = _chatMessageIndex[chatId];
      final indexEnd = DateTime.now();
      debugPrint(
          '⏱️ Index lookup took: ${indexEnd.difference(indexStart).inMicroseconds}μs');

      if (messageKeys != null && messageKeys.isNotEmpty) {
        debugPrint(
            '📨 Getting ${messageKeys.length} indexed messages for chat: $chatId');
        final messages = <MessageEntity>[];

        final parseStart = DateTime.now();
        for (final key in messageKeys) {
          try {
            final value = _messagesBox.get(key);
            if (value == null) continue;

            MessageEntity message;
            if (value is Map) {
              final jsonMap = Map<String, dynamic>.from(value);
              message = MessageEntity.fromJson(jsonMap);
            } else if (value is MessageEntity) {
              message = value;
            } else {
              continue;
            }

            // Decrypt message content if it's text
            if (message.type == MessageType.text &&
                message.content.isNotEmpty) {
              try {
                final encryptionService = Get.find<SecureEncryptionService>();
                final decryptedContent =
                    await encryptionService.decryptText(message.content);
                message = message.copyWith(content: decryptedContent);
              } catch (e) {
                debugPrint('⚠️ Failed to decrypt message content: $e');
                // Keep original content if decryption fails (might be plain text)
              }
            }

            messages.add(message);
          } catch (e) {
            debugPrint('📨 Error parsing message $key: $e');
          }
        }
        final parseEnd = DateTime.now();
        debugPrint(
            '⏱️ Message parsing took: ${parseEnd.difference(parseStart).inMicroseconds}μs');

        final sortStart = DateTime.now();
        messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        final sortEnd = DateTime.now();
        debugPrint(
            '⏱️ Sorting took: ${sortEnd.difference(sortStart).inMicroseconds}μs');

        final getEnd = DateTime.now();
        debugPrint('📨 Returning ${messages.length} messages for chat $chatId');
        debugPrint(
            '⏱️ getChatMessages() TOTAL: ${getEnd.difference(getStart).inMicroseconds}μs');
        return messages;
      }

      // Fallback: full scan if index is empty (rebuild index while scanning)
      debugPrint(
          '📨 Index miss for chat: $chatId, falling back to full scan. Total in box: ${_messagesBox.length}');
      final messages = <MessageEntity>[];

      for (final key in _messagesBox.keys) {
        try {
          final value = _messagesBox.get(key);
          if (value == null) continue;

          MessageEntity message;
          if (value is Map) {
            final jsonMap = Map<String, dynamic>.from(value);
            message = MessageEntity.fromJson(jsonMap);
          } else if (value is MessageEntity) {
            message = value;
          } else {
            continue;
          }

          // Decrypt message content if it's text
          if (message.type == MessageType.text && message.content.isNotEmpty) {
            try {
              final encryptionService = Get.find<SecureEncryptionService>();
              final decryptedContent =
                  await encryptionService.decryptText(message.content);
              message = message.copyWith(content: decryptedContent);
            } catch (e) {
              debugPrint('⚠️ Failed to decrypt message content: $e');
              // Keep original content if decryption fails
            }
          }

          // Rebuild index entry while scanning
          _chatMessageIndex
              .putIfAbsent(message.chatId, () => [])
              .add(key.toString());

          if (message.chatId == chatId) {
            messages.add(message);
          }
        } catch (e) {
          debugPrint('📨 Error parsing message $key: $e');
        }
      }

      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      debugPrint(
          '📨 Fallback returning ${messages.length} messages for chat $chatId');
      return messages;
    } catch (e) {
      debugPrint('📨 Error getting messages: $e');
      return [];
    }
  }

  Future<void> saveMessage(MessageEntity message) async {
    try {
      // Ensure messages box is opened lazily
      await _ensureMessagesBoxOpen();

      // Encrypt message content if it's text
      MessageEntity messageToSave = message;
      if (message.type == MessageType.text && message.content.isNotEmpty) {
        try {
          final encryptionService = Get.find<SecureEncryptionService>();
          final encryptedContent =
              await encryptionService.encryptText(message.content);
          messageToSave = message.copyWith(content: encryptedContent);
          debugPrint('🔒 Message content encrypted');
        } catch (e) {
          debugPrint('⚠️ Failed to encrypt message content: $e');
          // Continue with unencrypted content as fallback
        }
      }

      // Stamp disappearing-message expiry from the chat's timer when the
      // sender didn't already set one (covers socket, FCM and group paths).
      if (messageToSave.expiresAt == null) {
        final chatTimer = getChat(message.chatId)?.disappearingAfterSeconds;
        if (chatTimer != null && chatTimer > 0) {
          messageToSave = messageToSave.copyWith(
            expiresAt: messageToSave.timestamp.millisecondsSinceEpoch +
                chatTimer * 1000,
          );
        }
      }

      final jsonData = messageToSave.toJson();
      debugPrint(
          '💬 Saving message: ${message.id} for chat ${message.chatId} with status: ${message.status}');
      await _messagesBox.put(message.id, jsonData);
      // Update in-memory index (idempotent — deterministic ids are
      // re-saved on status updates and must not index twice)
      final indexList = _chatMessageIndex.putIfAbsent(message.chatId, () => []);
      if (!indexList.contains(message.id)) indexList.add(message.id);
      debugPrint(
          '💬 Message saved successfully. Box now has ${_messagesBox.length} messages');
    } catch (e) {
      debugPrint('💬 Error saving message: $e');
      return;
    }

    // Update chat's last message
    final chat = getChat(message.chatId);
    if (chat != null) {
      // For image messages, store a user-friendly display text instead of base64
      String displayMessage = message.content;
      if (message.type == MessageType.image) {
        displayMessage = '📷 Photo';
      } else if (message.type == MessageType.call) {
        displayMessage = '📞 Call';
      }

      final updatedChat = chat.copyWith(
        lastMessage: displayMessage,
        lastMessageTime: message.timestamp,
      );
      await saveChat(updatedChat);
    }
  }

  /// Write a complete reactions map onto the stored message JSON.
  ///
  /// Box-level write — must NOT go through [saveMessage] because stored text
  /// content is already encrypted; re-saving would double-encrypt it.
  Future<bool> setMessageReactions(
    String messageId,
    Map<String, String> reactions,
  ) async {
    try {
      await _ensureMessagesBoxOpen();
      final value = _messagesBox.get(messageId);
      if (value is! Map) return false;
      final jsonMap = Map<String, dynamic>.from(value)
        ..['reactions'] = reactions;
      await _messagesBox.put(messageId, jsonMap);
      return true;
    } catch (e) {
      debugPrint('💬 setMessageReactions error for $messageId: $e');
      return false;
    }
  }

  /// Mark a view-once message as opened — box-level write so stored (already
  /// encrypted) content is never re-saved.
  Future<bool> setMessageViewOnceOpened(String messageId) async {
    try {
      await _ensureMessagesBoxOpen();
      final value = _messagesBox.get(messageId);
      if (value is! Map) return false;
      final jsonMap = Map<String, dynamic>.from(value)
        ..['isViewOnceOpened'] = true;
      await _messagesBox.put(messageId, jsonMap);
      return true;
    } catch (e) {
      debugPrint('💬 setMessageViewOnceOpened error for $messageId: $e');
      return false;
    }
  }

  /// Read a message's raw stored JSON (reactions-only callers; content stays
  /// encrypted). Returns null when absent.
  Future<Map<String, dynamic>?> getStoredMessageJson(String messageId) async {
    try {
      await _ensureMessagesBoxOpen();
      final value = _messagesBox.get(messageId);
      return value is Map ? Map<String, dynamic>.from(value) : null;
    } catch (_) {
      return null;
    }
  }

  /// Delete-for-everyone tombstone — identity + timestamp survive, every
  /// content field (text, media, reply, file/audio metadata, reactions,
  /// expiry, view-once) is stripped so nothing recoverable stays on disk.
  /// The `saveMessage` write re-encrypts the (now empty) content blob.
  Future<void> setMessageDeletedForEveryone(
    String messageId,
    DateTime deletedAt,
  ) async {
    final json = await getStoredMessageJson(messageId);
    if (json == null) return;
    json['content'] = '';
    json['isDeletedForEveryone'] = true;
    json['deletedAt'] = deletedAt.toUtc().toIso8601String();
    json['mediaToken'] = null;
    json['mediaExpiryTimestamp'] = null;
    json['replyTo'] = null;
    json['senderName'] = null;
    json['fileName'] = null;
    json['fileSize'] = null;
    json['isCompressed'] = false;
    json['audioDuration'] = null;
    json['waveformData'] = null;
    json['encryptedAudioData'] = null;
    json['reactions'] = <String, String>{};
    json['expiresAt'] = null;
    json['isViewOnce'] = false;
    await saveMessage(MessageEntity.fromJson(json));
  }

  /// Persist an edited message body — `content` arrives as plaintext and is
  /// re-encrypted by `saveMessage`; `isEdited`/`editedAt` mark the bubble.
  Future<void> setMessageEdited(
    String messageId,
    String newPlaintext,
    DateTime editedAt,
  ) async {
    final json = await getStoredMessageJson(messageId);
    if (json == null) return;
    json['content'] = newPlaintext;
    json['isEdited'] = true;
    json['editedAt'] = editedAt.toUtc().toIso8601String();
    await saveMessage(MessageEntity.fromJson(json));
  }

  /// Delete a single message locally (Delete for Me) and drop its index
  /// entry so it no longer appears in this chat or any other.
  Future<void> deleteMessage(String messageId) async {
    await _ensureMessagesBoxOpen();
    _chatMessageIndex.forEach((_, keys) => keys.remove(messageId));
    await _messagesBox.delete(messageId);
  }

  /// Persistent outbox for control events (delete_for_everyone / edit) that
  /// must survive an offline gap — the sender's device can't push the event
  /// over the socket while disconnected, so it is queued here and flushed
  /// when the socket reconnects (even across app restarts).
  static const String _controlOutboxBoxName = 'control_outbox';

  Future<Box> _ensureControlOutboxOpen() async {
    if (Hive.isBoxOpen(_controlOutboxBoxName)) {
      return Hive.box(_controlOutboxBoxName);
    }
    return Hive.openBox(_controlOutboxBoxName);
  }

  /// Append a control event to the persistent outbox. `event['eventType']`
  /// is 'delete_message' | 'edit_message'; remaining keys form the payload.
  Future<void> enqueueControlEvent(Map<String, dynamic> event) async {
    final box = await _ensureControlOutboxOpen();
    await box.put(event['queueKey'] ??
        '${event['eventType']}:${event['messageId']}', event);
  }

  /// Read all queued control events in insertion order.
  Future<List<Map<String, dynamic>>> getControlOutboxEvents() async {
    final box = await _ensureControlOutboxOpen();
    return box.values
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// Remove a control event once it has been emitted successfully.
  Future<void> removeControlEvent(String queueKey) async {
    final box = await _ensureControlOutboxOpen();
    await box.delete(queueKey);
  }

  /// Check if a message with the given ID already exists in local storage
  bool messageExists(String messageId) {
    try {
      return _messagesBox.containsKey(messageId);
    } catch (e) {
      return false;
    }
  }

  /// Get all messages across all chats (for deduplication)
  Future<List<MessageEntity>> getAllMessages() async {
    try {
      // Ensure messages box is opened lazily
      _ensureMessagesBoxOpen();

      debugPrint(
          '📨 Getting all messages. Total in box: ${_messagesBox.length}');
      final messages = <MessageEntity>[];

      for (final key in _messagesBox.keys) {
        try {
          final messageData = _messagesBox.get(key);
          if (messageData != null) {
            var message = messageData is MessageEntity
                ? messageData
                : MessageEntity.fromJson(
                    Map<String, dynamic>.from(messageData));

            // Decrypt message content if it's text
            if (message.type == MessageType.text &&
                message.content.isNotEmpty) {
              try {
                final encryptionService = Get.find<SecureEncryptionService>();
                final decryptedContent =
                    await encryptionService.decryptText(message.content);
                message = message.copyWith(content: decryptedContent);
              } catch (e) {
                debugPrint('⚠️ Failed to decrypt message content: $e');
                // Keep original content if decryption fails
              }
            }

            messages.add(message);
          }
        } catch (e) {
          debugPrint('📨 Error parsing message $key: $e');
          continue;
        }
      }

      debugPrint('📨 Retrieved ${messages.length} messages successfully');
      return messages;
    } catch (e) {
      debugPrint('📨 Error getting all messages: $e');
      return [];
    }
  }

  // Priority ladder for status regression guard (higher = further along lifecycle).
  // 'failed' is not in the ladder — it is always writable (timeout / send error).
  static const Map<MessageStatus, int> _statusPriority = {
    MessageStatus.sending: 1,
    MessageStatus.sent: 2,
    MessageStatus.delivered: 3,
    MessageStatus.read: 4,
  };

  Future<void> updateMessageStatus(
      String messageId, MessageStatus status) async {
    try {
      debugPrint('📝 Updating message status: $messageId -> $status');
      final messageData = _messagesBox.get(messageId);
      if (messageData != null) {
        MessageEntity message;
        if (messageData is MessageEntity) {
          message = messageData;
        } else if (messageData is Map) {
          // Handle both Map<dynamic, dynamic> and Map<String, dynamic>
          final jsonMap = Map<String, dynamic>.from(messageData);
          message = MessageEntity.fromJson(jsonMap);
        } else {
          debugPrint('❌ Unknown message data type: ${messageData.runtimeType}');
          return;
        }

        // Regression guard: never write a lower-priority status over a higher one.
        // 'failed' bypasses this check — it can always be written.
        if (status != MessageStatus.failed) {
          final currentPriority = _statusPriority[message.status] ?? 0;
          final newPriority = _statusPriority[status] ?? 0;
          if (newPriority < currentPriority) {
            debugPrint(
                '📊 Skipping status regression for $messageId: ${message.status} → $status');
            return;
          }
        }

        final updatedMessage = message.copyWith(status: status);
        await _messagesBox.put(messageId, updatedMessage.toJson());
        debugPrint(
            '✅ Message status updated successfully: $messageId -> $status');
      } else {
        debugPrint('⚠️ Message not found for status update: $messageId');
      }
    } catch (e) {
      debugPrint('❌ Error updating message status: $e');
    }
  }

  // Search
  List<ChatEntity> searchChats(String query) {
    if (query.isEmpty) return getAllChats();

    final lowercaseQuery = query.toLowerCase();
    return getAllChats()
        .where((chat) =>
            chat.userName.toLowerCase().contains(lowercaseQuery) ||
            (chat.lastMessage?.toLowerCase().contains(lowercaseQuery) ?? false))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // E2EE identity pinning — dedicated store keyed by peer deviceId.
  //
  // Pins live in their own Hive box, NOT inside ChatEntity JSON: any code
  // path that rebuilds and re-saves a chat would otherwise silently erase a
  // pin (a trust downgrade), and deleting a chat would delete its pin.
  // ---------------------------------------------------------------------------
  static const String _peerIdentitiesBoxName = 'peer_identities';
  // Cipher key for the pin box lives only in platform secure storage —
  // on-device tampering with the box can't swap pinned keys without it.
  static const String _peerIdentitiesKeyName = 'vant_peer_identities_key';
  static const String _prefsPeerKeyCreated = 'peer_identities_key_created';
  // Same options as IdentityService: readable after first unlock (needed for
  // cold-start call answers from a locked phone) and never self-wiping.
  static const FlutterSecureStorage _peerIdentitySecureStorage =
      FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: 'VantPeerIdentityKeys',
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: false,
    ),
  );
  Box? _peerIdentitiesBox;

  /// Degraded mode: the pin box couldn't be opened (key unreadable — e.g.
  /// locked keychain — or key lost with a box still on disk). Reads return
  /// null and pins can't be written; the app keeps working and retries.
  final RxBool pinStoreUnavailable = false.obs;

  /// The box exists but can't be decrypted (backup restore without the key,
  /// corruption). Needs a VISIBLE user notice — silently dropping pins would
  /// let the next announcement win.
  final RxBool pinStoreCorrupted = false.obs;

  /// Result of an attempted pin. The store NEVER overwrites an existing pin —
  /// a conflict is surfaced to the caller for the key-changed warning.
  static const String pinResultPinned = 'pinned';
  static const String pinResultUnchanged = 'unchanged';
  static const String pinResultConflict = 'conflict';
  static const String pinResultNoChat = 'no_chat';
  static const String pinResultUnavailable = 'unavailable';

  /// Pin a peer's identity bundle on an existing chat.
  ///
  /// Rules:
  /// - No existing pin → creates it with status 'unverified' (TOFU).
  /// - Identical pin → returns [pinResultUnchanged], nothing written.
  /// - Different pin → returns [pinResultConflict] and writes NOTHING.
  /// - Store degraded → returns [pinResultUnavailable], writes NOTHING.
  Future<String> pinPeerBundle(String peerDeviceId, String bundle) async {
    if (getChat(peerDeviceId) == null) return pinResultNoChat;
    await _ensurePeerIdentitiesBox();
    if (_peerIdentitiesBox?.isOpen != true) return pinResultUnavailable;

    final existing = _peerIdentitiesBox!.get(peerDeviceId);
    if (existing == null) {
      await _peerIdentitiesBox!.put(peerDeviceId, {
        'bundle': bundle,
        'status': 'unverified',
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'capabilities': const <String>[],
        'capabilitySeq': 0,
        'encryptedCallSeen': false,
      });
      return pinResultPinned;
    }
    final existingBundle =
        existing is Map ? existing['bundle'] as String? : null;
    if (existingBundle == bundle) return pinResultUnchanged;
    // Persist the conflicting bundle + time — a key change is serious (a
    // bound ID cannot legitimately change keys) and must survive restarts.
    final existingEntry = existing is Map
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};
    await _peerIdentitiesBox!.put(peerDeviceId, {
      ...existingEntry,
      'bundle': existingBundle,
      'conflictBundle': bundle,
      'conflictAt': DateTime.now().millisecondsSinceEpoch,
    });
    return pinResultConflict;
  }

  /// Record a signed capability announcement for a pinned peer. The sequence
  /// is monotonic: exact or older values are rejected as replays. A strictly
  /// older sequence for the unchanged bundle records a reset warning so the
  /// user can re-verify instead of silently accepting rolled-back state.
  Future<bool> recordPeerCapabilities(
    String peerDeviceId,
    List<String> capabilities,
    int sequence, {
    required String bundleBase64,
  }) async {
    if (sequence < 0 || _peerIdentitiesBox?.isOpen != true) return false;
    final existing = _peerIdentitiesBox!.get(peerDeviceId);
    if (existing is! Map || existing['bundle'] == null) return false;
    final seen = existing['capabilitySeq'];
    final lastSequence = seen is int
        ? seen
        : seen is num
            ? seen.toInt()
            : 0;
    if (sequence <= lastSequence) {
      if (sequence < lastSequence && existing['bundle'] == bundleBase64) {
        await _peerIdentitiesBox!.put(peerDeviceId, {
          ...Map<String, dynamic>.from(existing),
          'capabilityReset': true,
          'capabilityResetSeq': sequence,
          'capabilityResetCapabilities': capabilities,
          'capabilityResetAt': DateTime.now().millisecondsSinceEpoch,
        });
      }
      return false;
    }
    final retained = capabilities.toSet();
    final previous = existing['capabilities'];
    if (previous is List && previous.contains('encrypted_call')) {
      retained.add('encrypted_call');
    }
    await _peerIdentitiesBox!.put(peerDeviceId, {
      ...Map<String, dynamic>.from(existing),
      'capabilities': retained.toList()..sort(),
      'capabilitySeq': sequence,
      'capabilityReset': null,
      'capabilityResetSeq': null,
      'capabilityResetCapabilities': null,
      'capabilityResetAt': null,
    });
    return true;
  }

  /// A lower sequence for the unchanged bundle needs visible re-verification.
  bool hasPeerCapabilityReset(String peerDeviceId) {
    if (_peerIdentitiesBox?.isOpen != true) return false;
    final entry = _peerIdentitiesBox!.get(peerDeviceId);
    return entry is Map && entry['capabilityReset'] == true;
  }

  /// Peers whose reset warning must survive app restart.
  List<String> peersWithCapabilityReset() {
    if (_peerIdentitiesBox?.isOpen != true) return [];
    return _peerIdentitiesBox!.keys
        .where((key) {
          final entry = _peerIdentitiesBox!.get(key);
          return entry is Map && entry['capabilityReset'] == true;
        })
        .map((key) => key as String)
        .toList();
  }

  /// Clear a capability reset warning after acknowledgment/verification.
  Future<void> clearPeerCapabilityReset(String peerDeviceId) async {
    if (_peerIdentitiesBox?.isOpen != true) return;
    final entry = _peerIdentitiesBox!.get(peerDeviceId);
    if (entry is! Map || entry['capabilityReset'] != true) return;
    await _peerIdentitiesBox!.put(peerDeviceId, {
      ...Map<String, dynamic>.from(entry),
      'capabilityReset': null,
      'capabilityResetSeq': null,
      'capabilityResetCapabilities': null,
      'capabilityResetAt': null,
    });
  }

  /// True when the peer once signed encrypted-call support, even if a later
  /// capability lookup is missing or weakened.
  bool peerSignedEncryptedCalls(String peerDeviceId) {
    if (_peerIdentitiesBox?.isOpen != true) return false;
    final entry = _peerIdentitiesBox!.get(peerDeviceId);
    if (entry is! Map) return false;
    final capabilities = entry['capabilities'];
    return capabilities is List && capabilities.contains('encrypted_call');
  }

  /// True when this device completed an encrypted call with the peer.
  bool peerHasEncryptedCallHistory(String peerDeviceId) {
    if (_peerIdentitiesBox?.isOpen != true) return false;
    final entry = _peerIdentitiesBox!.get(peerDeviceId);
    return entry is Map && entry['encryptedCallSeen'] == true;
  }

  /// Mark a successful encrypted handshake. This is a security floor: once a
  /// peer has used encrypted calling, plaintext must never be silently used.
  Future<bool> markPeerEncryptedCall(String peerDeviceId) async {
    if (_peerIdentitiesBox?.isOpen != true) return false;
    final existing = _peerIdentitiesBox!.get(peerDeviceId);
    if (existing is! Map || existing['bundle'] == null) return false;
    await _peerIdentitiesBox!.put(peerDeviceId, {
      ...Map<String, dynamic>.from(existing),
      'encryptedCallSeen': true,
    });
    return true;
  }

  /// A pinned contact may not silently downgrade to plaintext. Signed support
  /// and completed encrypted calls also make encryption mandatory.
  bool peerRequiresEncryptedCall(String peerDeviceId) {
    if (pinStoreUnavailable.value || pinStoreCorrupted.value) return true;
    return getPeerBundle(peerDeviceId) != null ||
        peerSignedEncryptedCalls(peerDeviceId) ||
        peerHasEncryptedCallHistory(peerDeviceId);
  }

  /// The conflicting bundle seen for a peer, or null. Persisted so a
  /// restart can't silently drop a key-changed warning.
  String? getPeerConflictBundle(String peerDeviceId) {
    if (_peerIdentitiesBox?.isOpen != true) return null;
    final entry = _peerIdentitiesBox!.get(peerDeviceId);
    return entry is Map ? entry['conflictBundle'] as String? : null;
  }

  /// All peers with a recorded key-changed conflict — used to restore the
  /// warning banner after app restarts.
  List<String> peersWithConflict() {
    if (_peerIdentitiesBox?.isOpen != true) return [];
    return _peerIdentitiesBox!.keys
        .where((k) {
          final entry = _peerIdentitiesBox!.get(k);
          return entry is Map && entry['conflictBundle'] != null;
        })
        .map((k) => k as String)
        .toList();
  }

  /// Clear a conflict after the user acknowledged it or re-verified.
  /// The PIN is untouched — dismissing a warning is not trusting the key.
  Future<void> clearPeerConflict(String peerDeviceId) async {
    if (_peerIdentitiesBox?.isOpen != true) return;
    final entry = _peerIdentitiesBox!.get(peerDeviceId);
    if (entry is! Map || entry['conflictBundle'] == null) return;
    await _peerIdentitiesBox!.put(peerDeviceId, {
      ...Map<String, dynamic>.from(entry),
      'conflictBundle': null,
      'conflictAt': null,
    });
  }

  /// Pinned bundle for a peer, or null.
  String? getPeerBundle(String peerDeviceId) {
    if (_peerIdentitiesBox?.isOpen != true) return null;
    final entry = _peerIdentitiesBox!.get(peerDeviceId);
    return entry is Map ? entry['bundle'] as String? : null;
  }

  /// Verification status ('verified' | 'unverified' | null when unpinned).
  String? getPeerVerificationStatus(String peerDeviceId) {
    if (_peerIdentitiesBox?.isOpen != true) return null;
    final entry = _peerIdentitiesBox!.get(peerDeviceId);
    return entry is Map ? entry['status'] as String? : null;
  }

  /// Mark a pinned contact verified. Only allowed when a pin exists —
  /// cannot create verified state out of thin air.
  Future<bool> markPeerVerified(String peerDeviceId) async {
    await _ensurePeerIdentitiesBox();
    final entry = _peerIdentitiesBox!.get(peerDeviceId);
    if (entry is! Map || entry['bundle'] == null) return false;
    if (entry['status'] == 'verified' &&
        entry['conflictBundle'] == null &&
        entry['capabilityReset'] != true) {
      return true;
    }
    final resetSequence = entry['capabilityResetSeq'];
    final acceptingReset =
        entry['capabilityReset'] == true && resetSequence is num;
    final resetCapabilities = <String>{};
    if (acceptingReset) {
      final announced = entry['capabilityResetCapabilities'];
      if (announced is List) {
        resetCapabilities.addAll(announced.whereType<String>());
      }
      final previous = entry['capabilities'];
      if (previous is List && previous.contains('encrypted_call')) {
        resetCapabilities.add('encrypted_call');
      }
    }
    await _peerIdentitiesBox!.put(peerDeviceId, {
      ...Map<String, dynamic>.from(entry),
      'status': 'verified',
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      if (acceptingReset) ...{
        'capabilities': resetCapabilities.toList()..sort(),
        'capabilitySeq': resetSequence.toInt(),
      },
      'capabilityReset': null,
      'capabilityResetSeq': null,
      'capabilityResetCapabilities': null,
      'capabilityResetAt': null,
    });
    return true;
  }

  /// Replace a pin after the user explicitly confirmed the new key via QR
  /// scan (the in-person channel outranks the TOFU pin). Also used when
  /// scanning a contact that had no pin yet — pins as 'verified'.
  Future<bool> replacePeerPinVerified(
      String peerDeviceId, String bundle) async {
    if (getChat(peerDeviceId) == null) return false;
    await _ensurePeerIdentitiesBox();
    if (_peerIdentitiesBox?.isOpen != true) return false;
    final existing = _peerIdentitiesBox!.get(peerDeviceId);
    await _peerIdentitiesBox!.put(peerDeviceId, {
      if (existing is Map) ...Map<String, dynamic>.from(existing),
      'bundle': bundle,
      'status': 'verified',
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'conflictBundle': null,
      'conflictAt': null,
      'capabilityReset': null,
      'capabilityResetSeq': null,
      'capabilityResetCapabilities': null,
      'capabilityResetAt': null,
    });
    return true;
  }

  /// 1:1 contact deviceIds with no pinned bundle — announcement targets.
  List<String> contactsWithoutPin() {
    if (_peerIdentitiesBox?.isOpen != true) return [];
    return getAllChats()
        .where((c) => !c.isGroupChat && getPeerBundle(c.id) == null)
        .map((c) => c.id)
        .toList();
  }

  Future<void> _ensurePeerIdentitiesBox() async {
    if (_peerIdentitiesBox?.isOpen != true) {
      _peerIdentitiesBox = await _openPeerIdentitiesBox();
    }
  }

  /// Open the pin box AES-encrypted.
  ///
  /// Three outcomes:
  ///  - key read OK → open box normally (corrupt box → pinStoreCorrupted)
  ///  - key read THREW → degraded; the key may still exist. Never generates
  ///    a replacement (that would permanently orphan the encrypted box).
  ///  - key read returned null + key-was-created flag set → the key was lost
  ///    while a box exists → degraded + corrupted flag (visible notice)
  ///  - key null + never created → first run; generate + flag.
  Future<Box?> _openPeerIdentitiesBox() async {
    String? keyB64;
    try {
      keyB64 = await _peerIdentitySecureStorage.read(
        key: _peerIdentitiesKeyName,
      );
    } catch (e) {
      debugPrint('⚠️ Pin-store key read failed (locked/transient): $e');
      pinStoreUnavailable.value = true;
      return null;
    }

    if (keyB64 == null) {
      if (_prefs.getBool(_prefsPeerKeyCreated) == true) {
        // Key existed before and is now gone — box on disk is unreadable.
        debugPrint('❌ Pin-store key lost but box exists');
        pinStoreUnavailable.value = true;
        pinStoreCorrupted.value = true;
        return null;
      }
      keyB64 = base64Encode(Hive.generateSecureKey());
      try {
        await _peerIdentitySecureStorage.write(
          key: _peerIdentitiesKeyName,
          value: keyB64,
        );
        await _prefs.setBool(_prefsPeerKeyCreated, true);
      } catch (e) {
        debugPrint('⚠️ Pin-store key write failed: $e');
        pinStoreUnavailable.value = true;
        return null;
      }
    }

    try {
      return await Hive.openBox(
        _peerIdentitiesBoxName,
        encryptionCipher: HiveAesCipher(base64Decode(keyB64)),
      );
    } catch (e) {
      debugPrint('❌ Pin box cannot be decrypted: $e');
      pinStoreUnavailable.value = true;
      pinStoreCorrupted.value = true;
      return null;
    }
  }

  /// Retry opening the pin box after a degraded open (locked keychain,
  /// transient keystore error). Called by the announcement flush and can be
  /// called on app resume. No-op once the box is open; never retries a
  /// corrupted box (that needs the user's explicit reset).
  Future<void> retryPeerIdentityStore() async {
    if (_peerIdentitiesBox?.isOpen == true) return;
    if (pinStoreCorrupted.value) return;
    _peerIdentitiesBox = await _openPeerIdentitiesBox();
    if (_peerIdentitiesBox?.isOpen == true) {
      pinStoreUnavailable.value = false;
      debugPrint('🔐 Peer identity store recovered');
    }
  }

  /// Deliberate pin removal — the "reset verification" action in contact
  /// settings. Only reachable through explicit user action.
  Future<void> removePeerPin(String peerDeviceId) async {
    await _ensurePeerIdentitiesBox();
    if (_peerIdentitiesBox?.isOpen != true) return;
    await _peerIdentitiesBox!.delete(peerDeviceId);
  }

  /// Wipe the pin store after user confirmation (undecryptable box flow).
  /// Keeps the cipher key — a fresh encrypted box is opened next launch.
  Future<void> resetPeerIdentityStore() async {
    try {
      await _peerIdentitiesBox?.close();
      await Hive.deleteBoxFromDisk(_peerIdentitiesBoxName);
    } catch (_) {}
    _peerIdentitiesBox = null;
    pinStoreUnavailable.value = false;
    pinStoreCorrupted.value = false;
    await _ensurePeerIdentitiesBox();
  }

  @override
  void onClose() {
    _chatsBox.close();
    _peerIdentitiesBox?.close();
    if (_messagesBoxInitialized) {
      _messagesBox.close();
    }
    super.onClose();
  }
}
