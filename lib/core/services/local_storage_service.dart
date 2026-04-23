import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:pear_messaging/storage/models/chat_entity.dart';
import 'package:pear_messaging/storage/models/connection_request_entity.dart';
import 'package:pear_messaging/storage/models/message_entity.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'username_sync_service.dart';
import '../utils/string_utils.dart';

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

  // In-memory index: chatId -> list of message keys for fast lookup
  final Map<String, List<String>> _chatMessageIndex = {};

  Future<LocalStorageService> init() async {
    // Register Hive adapters (without generated files for now)

    // Initialize SharedPreferences FIRST - needed for device ID and terms check
    _prefs = await SharedPreferences.getInstance();

    // Open all boxes at startup so data is ready instantly
    _chatsBox = await Hive.openBox(_chatsBoxName);
    _connectionRequestsBox = await Hive.openBox(_connectionRequestsBoxName);
    _messagesBox = await Hive.openBox(_messagesBoxName);
    _messagesBoxInitialized = true;
    _buildMessageIndex();

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
  /// For other devices: generated friendly name (since we don't store custom names for other users)
  String getDisplayName(String deviceId) {
    // Check if this is the current device
    if (deviceId == this.deviceId) {
      final customName = getUserName();
      if (customName != null && customName.isNotEmpty) {
        return customName;
      }
    }
    // For any device (current or other), return generated friendly name
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
      if (chat.userName.isNotEmpty) {
        await _prefs.setString('chat_name_${chat.id}', chat.userName);
        debugPrint(
            '💾 Chat name saved to SharedPreferences: ${chat.id} -> ${chat.userName}');

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
        try {
          await _appGroupChannel.invokeMethod('removeFromAppGroup', {
            'key': 'chat_name_$chatId',
          });
          debugPrint('🗑️ Chat name removed from App Group: $chatId');
        } catch (e) {
          debugPrint('⚠️ Failed to remove chat name from App Group: $e');
        }
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
  List<MessageEntity> getChatMessages(String chatId) {
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

      final jsonData = message.toJson();
      debugPrint(
          '💬 Saving message: ${message.id} for chat ${message.chatId} with status: ${message.status} -> $jsonData');
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
  List<MessageEntity> getAllMessages() {
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
            final message = messageData is MessageEntity
                ? messageData
                : MessageEntity.fromJson(
                    Map<String, dynamic>.from(messageData));
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

  @override
  void onClose() {
    _chatsBox.close();
    if (_messagesBoxInitialized) {
      _messagesBox.close();
    }
    super.onClose();
  }
}
