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
  static Map<String, String> contactNameCacheEntries(
      SharedPreferences prefs, {int limit = _contactNameCacheLimit}) {
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

  // User name preference
  String? getUserName() {
    return _prefs.getString(_prefsUserNameKey);
  }

  Future<void> setUserName(String name) async {
    await _prefs.setString(_prefsUserNameKey, name);
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

  Future<void> saveChat(ChatEntity chat) async {
    try {
      final jsonData = chat.toJson();
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
  Future<List<MessageEntity>> getChatMessages(String chatId) async {
    final getStart = DateTime.now();
    try {
      // Ensure messages box is opened lazily - this will be synchronous for already opened box
      if (!_messagesBoxInitialized) {
        // If not initialized, return empty list and initialize in background
        _ensureMessagesBoxOpen();
        return [];
      }

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

      final jsonData = messageToSave.toJson();
      debugPrint(
          '💬 Saving message: ${message.id} for chat ${message.chatId} with status: ${message.status}');
      await _messagesBox.put(message.id, jsonData);
      // Update in-memory index
      _chatMessageIndex.putIfAbsent(message.chatId, () => []).add(message.id);
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
      }

      final updatedChat = chat.copyWith(
        lastMessage: displayMessage,
        lastMessageTime: message.timestamp,
      );
      await saveChat(updatedChat);
    }
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
    final acceptingReset = entry['capabilityReset'] == true &&
        resetSequence is num;
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
