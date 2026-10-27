import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pear_messaging/core/services/api_service.dart';
import 'package:pear_messaging/core/services/fcm_service.dart';
import 'package:pear_messaging/storage/models/connection_request_entity.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/services/membership_service.dart';
import '../../core/services/socket_service.dart';
import '../../core/services/badge_service.dart';
import '../../core/services/caller_name_resolver.dart';
import '../../core/services/invitation_storage_service.dart';
import '../../core/services/local_auth_service.dart';
import '../../core/services/username_service.dart';
import '../../core/services/username_sync_service.dart';
import '../../core/utils/string_utils.dart';
import '../../storage/models/chat_entity.dart';
import '../../storage/models/message_entity.dart';
import '../../storage/models/reply_to_entity.dart';
import 'chat_list_model.dart';
import '../../routes/app_routes.dart';

// Use foundation debugPrint to avoid conflicts
import 'package:flutter/foundation.dart' as foundation;

class ChatListController extends GetxController {
  final LocalStorageService _storageService = Get.find();
  final SocketService _socketService = Get.find();
  final ApiService _apiService = ApiService.to;

  final TextEditingController searchController = TextEditingController();
  final TextEditingController userNameController = TextEditingController();
  final RxList<ChatListModel> chats = <ChatListModel>[].obs;
  final RxList<ChatListModel> filteredChats = <ChatListModel>[].obs;
  final RxList<ConnectionRequestEntity> pendingConnectionRequests =
      <ConnectionRequestEntity>[].obs;
  final Uuid _uuid = const Uuid();
  final Set<String> _processedMessageIds = <String>{};

  // User name editing state
  final RxBool isEditingName = false.obs;
  final RxString currentUserName = ''.obs;

  @override
  void onInit() {
    super.onInit();

    // Reset active chat ID when on chat list - show all notifications
    FCMService.activeChatId = null;

    _authenticateIfNeeded();
    loadChats(); // This calls loadConnectionRequests internally
    loadConnectionRequests(); // Explicitly load connection requests before checking pending invitation
    _checkPendingInvitation();
    _setupSocketListeners();
    _loadUserName();
    _syncExistingUsernames();
    _syncMembership();
    _syncGroupsFromServer();
  }

  /// Sync membership from server in background on app open.
  /// Only calls API if no active plan is stored locally.
  void _syncMembership() {
    Future.microtask(() async {
      try {
        final deviceId = _storageService.deviceId;
        if (deviceId == null) return;
        final membershipService = Get.find<MembershipService>();
        await membershipService.syncMembershipFromServer(deviceId);
      } catch (e) {
        foundation.debugPrint('⚠️ Membership sync failed: $e');
      }
    });
  }

  /// Sync groups from server in background on app open.
  void _syncGroupsFromServer() {
    Future.microtask(() async {
      try {
        final deviceId = _storageService.deviceId;
        if (deviceId == null) return;
        final groups = await _apiService.getGroupsForDevice(deviceId);
        for (final group in groups) {
          final groupData = group is Map<String, dynamic>
              ? group
              : Map<String, dynamic>.from(group as Map);
          await _storageService.saveGroupChatFromApi(groupData,
              myDeviceId: deviceId);
        }
        loadChats();
        debugPrint('🔄 Synced ${groups.length} groups from server');
      } catch (e) {
        debugPrint('⚠️ Failed to sync groups from server: $e');
      }
    });
  }

  /// Sync existing usernames to backend on app startup
  void _syncExistingUsernames() {
    // Run in background to not block UI
    Future.microtask(() async {
      try {
        final usernameSyncService = Get.find<UsernameSyncService>();
        await usernameSyncService.syncAllChatNames();
        debugPrint('🔄 Existing usernames synced to backend on startup');
      } catch (e) {
        debugPrint('⚠️ Failed to sync existing usernames: $e');
      }
    });
  }

  /// Check for pending invitations (for returning users who skip splash)
  void _checkPendingInvitation() {
    try {
      final invitationService = Get.find<InvitationStorageService>();
      final pendingInvitation = invitationService.getPendingInvitation();

      if (pendingInvitation != null) {
        debugPrint(
          '📋 Found pending invitation in chat list: ${pendingInvitation['deviceId']}',
        );

        final deviceId = pendingInvitation['deviceId']!;

        // Check if there's already a connection request for this device
        // If so, don't auto-navigate - let the user interact with the connection request card
        final existingConnectionRequest = pendingConnectionRequests
            .where((request) => request.senderDeviceId == deviceId)
            .firstOrNull;

        if (existingConnectionRequest != null) {
          debugPrint(
            '📋 Connection request already exists for this device, skipping auto-navigation',
          );
          // Clear the pending invitation since we're handling it via connection request
          invitationService.clearPendingInvitation();
          debugPrint(
            '📋 Cleared pending invitation - user should use connection request card',
          );
          return;
        }

        // Enhanced validation: Check if chat already exists
        final existingChat = _storageService.getChat(deviceId);
        if (existingChat != null) {
          debugPrint(
            '📋 Chat already exists for device $deviceId, clearing pending invitation',
          );
          invitationService.clearPendingInvitation();
          return;
        }

        // Enhanced validation: Check for any connection request involving this device
        final anyExistingRequest = pendingConnectionRequests.any(
          (request) =>
              request.senderDeviceId == deviceId ||
              request.receiverDeviceId == deviceId,
        );

        if (anyExistingRequest) {
          debugPrint(
            '📋 Connection request already exists involving device $deviceId, clearing pending invitation',
          );
          invitationService.clearPendingInvitation();
          return;
        }

        // final userName = pendingInvitation['userName']!;

        // // Navigate to chat screen with pending connection
        // Future.microtask(() {
        //   debugPrint("location 2");
        //   Get.offAllNamed(
        //     AppRoutes.chat,
        //     arguments: {
        //       'chatId': deviceId,
        //       'userName': userName,
        //       'recipientDeviceId': deviceId,
        //       'isPendingConnection': true,
        //       'firstMessageSent': false,
        //     },
        //   );
        // });

        // Clear the pending invitation after processing
        invitationService.clearPendingInvitation();
        debugPrint('✅ Navigated to conversation from pending invitation');
      }
    } catch (e) {
      debugPrint('⚠️ Error checking pending invitations: $e');
    }
  }

  /// Authenticate user if biometric auth is enabled (for returning users who skip splash)
  Future<void> _authenticateIfNeeded() async {
    try {
      // Check if auth is enabled by user
      if (!_storageService.isAuthEnabled) {
        return;
      }

      final authService = Get.find<LocalAuthService>();
      final isAvailable = await authService.isAvailable();

      if (!isAvailable) {
        return;
      }

      final authenticated = await authService.authenticate();
      if (!authenticated) {
        // Auth failed - show error and retry option
        Get.snackbar(
          'Authentication Failed',
          'Please authenticate to continue',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 5),
          mainButton: TextButton(
            onPressed: () => _authenticateIfNeeded(),
            child: const Text('Retry', style: TextStyle(color: Colors.white)),
          ),
        );
      }
    } catch (e) {
      debugPrint('⚠️ Auth check error: $e');
    }
  }

  /// Load the current user's display name
  void _loadUserName() {
    final deviceId = _storageService.deviceId ?? '';
    currentUserName.value = _storageService.getDisplayName(deviceId);
    userNameController.text = currentUserName.value;
  }

  /// Get the current user's display name (reactive)
  String get userDisplayName => currentUserName.value;

  /// Set user name from anywhere in the app (centralized method)
  Future<void> setUserName(String name) async {
    final trimmedName = name.trim();
    if (trimmedName.isNotEmpty) {
      await _storageService.setUserName(trimmedName);
      currentUserName.value = trimmedName;
      userNameController.text = trimmedName;

      // Sync username to backend for notification titles
      try {
        final deviceId = _storageService.deviceId ?? '';
        if (deviceId.isNotEmpty) {
          final usernameSyncService = Get.find<UsernameSyncService>();
          await usernameSyncService.syncUsername(deviceId, trimmedName);
          debugPrint(
            '🔄 Username synced to backend: $deviceId -> $trimmedName',
          );
        }
      } catch (e) {
        debugPrint('⚠️ Failed to sync username to backend: $e');
      }
    }
  }

  /// Start editing the user name
  void startEditingName() {
    userNameController.text = currentUserName.value;
    isEditingName.value = true;
  }

  /// Save the edited user name
  Future<void> saveUserName() async {
    final newName = userNameController.text.trim();
    if (newName.isNotEmpty) {
      await setUserName(newName);
    }
    isEditingName.value = false;
  }

  /// Cancel editing the user name
  void cancelEditingName() {
    userNameController.text = currentUserName.value;
    isEditingName.value = false;
  }

  void _setupSocketListeners() {
    // Listen for incoming messages to create/update conversations
    _socketService.onMessageReceived = _handleIncomingMessage;
    _socketService.onPendingMessages = _handlePendingMessages;
    _socketService.onGroupMessageReceived = _handleGroupMessage;

    // Listen for group management events
    _socketService.onGroupCreated = _onGroupCreated;
    _socketService.onGroupMemberAdded = _onGroupMemberChange;
    _socketService.onGroupMemberRemoved = _onGroupMemberChange;
    _socketService.onGroupMemberLeft = _onGroupMemberChange;
    _socketService.onGroupInfoUpdated = _onGroupInfoUpdated;
    _socketService.onGroupDissolved = _onGroupDissolved;

    _socketService.processPendingMessages();
  }

  Future<void> _handleIncomingMessage(Map<String, dynamic> data) async {
    debugPrint('📬 CHAT LIST LOG: _handleIncomingMessage called');
    debugPrint('🔍 CHAT LIST LOG: Incoming message data: $data');
    debugPrint(
      '🔍 CHAT LIST LOG: Current device ID: ${_storageService.deviceId}',
    );

    // Match backend field names: messageId, senderDeviceId, encryptedPayload, timestamp
    final senderId = data['senderDeviceId'] as String;
    final messageId = data['messageId'] as String? ?? _uuid.v4();
    final cipherText = data['encryptedPayload'] as String? ?? '';
    final timestamp =
        data['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;

    // Parse reply metadata if present
    ReplyToEntity? replyToEntity;
    if (data['replyTo'] != null) {
      try {
        final replyTo = data['replyTo'] as Map<String, dynamic>;
        replyToEntity = ReplyToEntity.fromJson(replyTo);
        debugPrint(
          '🔁 CHAT LIST LOG: Reply metadata parsed - content: ${replyToEntity.content}',
        );
      } catch (e) {
        debugPrint('⚠️ CHAT LIST LOG: Failed to parse reply metadata: $e');
      }
    }

    debugPrint('📋 CHAT LIST LOG: Parsed message data:');
    debugPrint('  - senderId: $senderId');
    debugPrint('  - messageId: $messageId');
    debugPrint('  - timestamp: $timestamp');

    // Check if this message has already been processed (in-memory)
    if (_processedMessageIds.contains(messageId)) {
      debugPrint(
        '⚠️ Message already processed (in-memory), skipping: $messageId',
      );
      return;
    }

    // Check if message already exists in Hive (FCM may have saved it)
    final messageWasAlreadyInStorage = _storageService.messageExists(messageId);
    if (messageWasAlreadyInStorage) {
      debugPrint(
        '🔁 Message $messageId already in Hive (FCM), skipping insert and notification',
      );
      return;
    }

    // Mark message as processed
    _processedMessageIds.add(messageId);

    // Decrypt message content
    final decryptedContent = SocketService.decryptMessage(cipherText);
    final messageTime = DateTime.fromMillisecondsSinceEpoch(timestamp);

    // Check if this is an image/audio/file message
    final bool isImageMessage = decryptedContent.startsWith('MEDIA:') ||
        decryptedContent.startsWith('IMAGE:');
    final bool isAudioMessage = decryptedContent.startsWith('AUDIO:');
    final bool isFileMessage = decryptedContent.startsWith('FILE:');
    final String content = decryptedContent;
    final MessageType messageType = isAudioMessage
        ? MessageType.audio
        : isFileMessage
            ? MessageType.file
            : isImageMessage
                ? MessageType.image
                : MessageType.text;

    // Check if chat exists for this sender
    final existingChatIndex = chats.indexWhere((chat) => chat.id == senderId);
    debugPrint(
      '🔍 DEBUG: Existing chat index for sender $senderId: $existingChatIndex',
    );

    // Save the message FIRST before calculating unread count
    final message = MessageEntity(
      id: messageId,
      chatId: senderId,
      senderId: senderId,
      receiverId: _storageService.deviceId ?? '',
      content: content,
      timestamp: messageTime,
      status: MessageStatus.delivered,
      isMe: false,
      type: messageType,
      replyTo: replyToEntity,
    );

    // Save message to storage
    await _storageService.saveMessage(message);
    debugPrint('💾 DEBUG: Message saved to storage');

    if (existingChatIndex == -1) {
      debugPrint('🆕 DEBUG: No existing chat found, checking storage...');
      // Check if we have an existing chat in storage (might not be in memory)
      final existingChat = _storageService.getChat(senderId);

      if (existingChat != null) {
        // Chat exists in storage, add to memory and update
        debugPrint('📝 Found existing chat in storage for sender: $senderId');

        final actualUnreadCount = await _calculateUnreadCount(senderId);
        final displayMessage = isAudioMessage
            ? '🎤 Voice message'
            : (isImageMessage ? '📷 Photo' : content);

        // Update in storage
        final updatedChat = existingChat.copyWith(
          lastMessage: displayMessage,
          lastMessageTime: messageTime,
          unreadCount: actualUnreadCount,
          isReply: replyToEntity != null,
          replyContent: replyToEntity?.content,
        );
        _storageService.saveChat(updatedChat);

        // Update filtered chats
        filteredChats.value = List.from(chats);
      } else {
        // No existing chat - check if this is a response to our invitation
        debugPrint(
          '📩 CHAT LIST LOG: Received message from unknown sender: $senderId',
        );
        debugPrint(
          '🔍 CHAT LIST LOG: Checking if this is a response to our invitation...',
        );

        // Check if we have a chat with "Invitation sent" status (meaning we sent them an invitation)
        final allChats = _storageService.getAllChats();
        debugPrint(
          '📚 CHAT LIST LOG: Found ${allChats.length} existing chats in storage',
        );

        final invitationChat = allChats
            .where(
              (chat) =>
                  chat.id == senderId &&
                  (chat.lastMessage?.contains('Invitation sent') == true ||
                      chat.lastMessage?.contains('waiting for response') ==
                          true),
            )
            .firstOrNull;

        debugPrint(
          '🔍 CHAT LIST LOG: Invitation chat search result: ${invitationChat?.toJson()}',
        );

        if (invitationChat != null) {
          // This is a response to our invitation - create regular chat, not connection request
          debugPrint(
            '✅ CHAT LIST LOG: This is a response to our invitation - creating regular chat',
          );
          debugPrint(
            '📋 CHAT LIST LOG: Found invitation chat: ${invitationChat.toJson()}',
          );

          final displayName = invitationChat.userName.isNotEmpty &&
                  invitationChat.userName != invitationChat.id
              ? invitationChat.userName
              : StringUtils.generateFriendlyName(senderId);
          final actualUnreadCount = await _calculateUnreadCount(senderId);
          final displayMessage = isAudioMessage
              ? '🎤 Voice message'
              : (isImageMessage ? '📷 Photo' : content);

          debugPrint(
            '🏗️ CHAT LIST LOG: Creating regular chat for invitation response:',
          );
          debugPrint('  - displayName: $displayName');
          debugPrint('  - actualUnreadCount: $actualUnreadCount');
          debugPrint('  - displayMessage: $displayMessage');

          final chatModel = ChatListModel(
            id: senderId,
            userName: displayName,
            lastMessage: displayMessage,
            lastMessageTime: messageTime,
            unreadCount: actualUnreadCount,
            isReply: replyToEntity != null,
            replyContent: replyToEntity?.content,
          );

          // Update the existing invitation chat to regular chat
          final updatedChat = ChatEntity(
            id: senderId,
            userName: displayName,
            lastMessage: displayMessage,
            lastMessageTime: messageTime,
            unreadCount: actualUnreadCount,
            isReply: replyToEntity != null,
            replyContent: replyToEntity?.content,
          );

          await _storageService.saveChat(updatedChat);

          // Add to UI
          chats.add(chatModel);
          chats.sort(
            (a, b) => b.lastMessageTime!.compareTo(a.lastMessageTime!),
          );
          filteredChats.value = List.from(chats);

          debugPrint(
            '✅ CHAT LIST LOG: Regular chat created for invitation response',
          );
        } else {
          // Unknown sender sent us a message - they already accepted to chat
          // Create a direct chat instead of connection request
          debugPrint(
            '✅ CHAT LIST LOG: Received message from new contact - creating direct chat',
          );
          debugPrint(
            '📋 CHAT LIST LOG: Sender ID: $senderId, Message: $content',
          );

          // Fetch username from server for display
          String displayName = _storageService.getDisplayName(senderId);
          try {
            final usernameData = await UsernameService.getUsername(senderId);
            if (usernameData?.username != null) {
              displayName = usernameData!.username;
              debugPrint(
                '✅ CHAT LIST LOG: Fetched username from server: $displayName',
              );
            }
          } catch (e) {
            debugPrint('⚠️ CHAT LIST LOG: Could not fetch username: $e');
          }

          final actualUnreadCount = await _calculateUnreadCount(senderId);
          final displayMessage = isAudioMessage
              ? '🎤 Voice message'
              : (isImageMessage ? '📷 Photo' : content);

          final chatModel = ChatListModel(
            id: senderId,
            userName: displayName,
            lastMessage: displayMessage,
            lastMessageTime: messageTime,
            unreadCount: actualUnreadCount,
            isReply: replyToEntity != null,
            replyContent: replyToEntity?.content,
          );

          // Create and save new chat
          final newChat = ChatEntity(
            id: senderId,
            userName: displayName,
            lastMessage: displayMessage,
            lastMessageTime: messageTime,
            unreadCount: actualUnreadCount,
            isReply: replyToEntity != null,
            replyContent: replyToEntity?.content,
          );

          await _storageService.saveChat(newChat);
          debugPrint('💾 CHAT LIST LOG: Direct chat saved to storage');

          // Add to UI
          chats.add(chatModel);
          chats.sort(
            (a, b) => b.lastMessageTime!.compareTo(a.lastMessageTime!),
          );
          filteredChats.value = List.from(chats);

          debugPrint(
            '✅ CHAT LIST LOG: Direct chat created for new contact: $displayName',
          );
        }

        // Send message acknowledgment
        if (_socketService.isConnected.value) {
          _socketService.sendMessageAck(messageId);
          debugPrint('✅ Message acknowledgment sent for: $messageId');
        }

        return; // Exit after handling new contact
      }
    } else {
      // Update existing chat AFTER message is saved
      debugPrint('📝 Updating existing chat for sender: $senderId');
      final existingChat = chats[existingChatIndex];

      // Calculate actual unread count by counting unread messages (now includes the new message)
      final actualUnreadCount = await _calculateUnreadCount(senderId);

      // Display "🎤 Voice message" or "📷 Photo" for media in chat list
      final displayMessage = isAudioMessage
          ? '🎤 Voice message'
          : (isImageMessage ? '📷 Photo' : content);

      final updatedChat = ChatListModel(
        id: existingChat.id,
        userName: existingChat.userName,
        lastMessage: displayMessage,
        lastMessageTime: messageTime,
        unreadCount: actualUnreadCount,
        isReply: replyToEntity != null,
        replyContent: replyToEntity?.content,
      );

      // Update in storage
      _storageService.saveChat(
        ChatEntity(
          id: updatedChat.id,
          userName: updatedChat.userName,
          lastMessage: updatedChat.lastMessage,
          lastMessageTime: updatedChat.lastMessageTime,
          unreadCount: updatedChat.unreadCount,
          isReply: updatedChat.isReply,
          replyContent: updatedChat.replyContent,
        ),
      );

      // Move to top of list
      chats.removeAt(existingChatIndex);
      chats.insert(0, updatedChat);

      // Update filtered chats to trigger UI refresh
      filteredChats.value = List.from(chats);
    }

    // Send message acknowledgment to mark as delivered on sender's side
    debugPrint('🔄 Attempting to send message acknowledgment for: $messageId');
    debugPrint('🔗 Socket connected: ${_socketService.isConnected.value}');

    if (_socketService.isConnected.value) {
      _socketService.sendMessageAck(messageId);
      debugPrint('✅ Message acknowledgment sent for: $messageId');
    } else {
      debugPrint('❌ Cannot send acknowledgment - socket not connected');
    }

    // Update filtered chats
    filteredChats.value = List.from(chats);
  }

  Future<void> _handlePendingMessages(
      List<Map<String, dynamic>> messages) async {
    foundation.debugPrint('📬 Handling ${messages.length} pending messages');

    // Sort messages by timestamp to maintain order
    messages.sort((a, b) {
      final timestampA = a['timestamp'] ?? 0;
      final timestampB = b['timestamp'] ?? 0;
      return timestampA.compareTo(timestampB);
    });

    // Collect message IDs for delivery acknowledgments
    final List<String> messageIdsToAck = [];

    // Route each message through the full onMessageReceived chain so that
    // ChatController (if open) also adds the message to its list.
    // If ChatController is not active, onMessageReceived == _handleIncomingMessage
    // so the behavior is identical to before.
    for (final message in messages) {
      final messageId = message['messageId'];
      if (messageId == null) continue;

      // Always collect for delivery acknowledgment — FCM may have saved the
      // message while offline but never sent message_ack, so the sender never
      // got a 'delivered' status. Sending the ack here fixes that.
      messageIdsToAck.add(messageId);

      if (!_messageExists(messageId)) {
        final handler = _socketService.onMessageReceived;
        if (handler != null) {
          final result = handler(message);
          if (result is Future) await result;
        } else {
          await _handleIncomingMessage(message);
        }
      } else {
        foundation.debugPrint(
          '📋 Message already in Hive (FCM), skipping insert but sending ack: $messageId',
        );
      }
    }

    // Send delivery acknowledgments for all received messages
    if (messageIdsToAck.isNotEmpty) {
      foundation.debugPrint(
        '📤 Sending delivery acknowledgments for ${messageIdsToAck.length} messages',
      );
      for (final messageId in messageIdsToAck) {
        _socketService.sendMessageAck(messageId);
      }
    }
  }

  /// Handle an incoming group message.
  Future<void> _handleGroupMessage(Map<String, dynamic> data) async {
    debugPrint('📬 CHAT LIST LOG: _handleGroupMessage called');
    debugPrint('🔍 CHAT LIST LOG: Incoming group message data: $data');

    final groupId = data['groupId']?.toString();
    final senderId = data['senderDeviceId']?.toString();
    final messageId = data['messageId']?.toString() ?? _uuid.v4();
    final cipherText = data['encryptedPayload']?.toString() ?? '';
    final timestamp =
        data['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;

    if (groupId == null || senderId == null) {
      debugPrint('⚠️ CHAT LIST LOG: Invalid group message payload: $data');
      return;
    }

    if (_processedMessageIds.contains(messageId)) {
      debugPrint('⚠️ Group message already processed, skipping: $messageId');
      return;
    }
    _processedMessageIds.add(messageId);

    if (_storageService.messageExists(messageId)) {
      debugPrint('🔁 Group message $messageId already in storage, skipping');
      return;
    }

    // Parse reply metadata if present
    ReplyToEntity? replyToEntity;
    if (data['replyTo'] != null) {
      try {
        replyToEntity = ReplyToEntity.fromJson(
          Map<String, dynamic>.from(data['replyTo'] as Map),
        );
      } catch (e) {
        debugPrint('⚠️ Failed to parse group reply metadata: $e');
      }
    }

    final decryptedContent = SocketService.decryptMessage(cipherText);
    final messageTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final isImageMessage = decryptedContent.startsWith('MEDIA:') ||
        decryptedContent.startsWith('IMAGE:');
    final isAudioMessage = decryptedContent.startsWith('AUDIO:');
    final isFileMessage = decryptedContent.startsWith('FILE:');
    final content = decryptedContent;
    final messageType = isAudioMessage
        ? MessageType.audio
        : isFileMessage
            ? MessageType.file
            : isImageMessage
                ? MessageType.image
                : MessageType.text;

    // Ensure the group chat exists locally; fetch from server if missing.
    ChatEntity? groupChat = _storageService.getChat(groupId);
    if (groupChat == null) {
      try {
        final deviceId = _storageService.deviceId ?? '';
        if (deviceId.isNotEmpty) {
          final response =
              await _apiService.getGroup(groupId: groupId, deviceId: deviceId);
          final groupData = response['group'] as Map<String, dynamic>?;
          if (groupData != null) {
            groupChat = await _storageService.saveGroupChatFromApi(groupData,
                myDeviceId: deviceId);
          }
        }
      } catch (e) {
        debugPrint('⚠️ Failed to fetch group info for $groupId: $e');
      }
    }

    // Save message
    final message = MessageEntity(
      id: messageId,
      chatId: groupId,
      senderId: senderId,
      receiverId: groupId,
      content: content,
      timestamp: messageTime,
      status: MessageStatus.delivered,
      isMe: senderId == _storageService.deviceId,
      type: messageType,
      replyTo: replyToEntity,
    );
    await _storageService.saveMessage(message);

    // Send delivery ack
    if (_socketService.isConnected.value) {
      _socketService.sendGroupMessageAck(
          messageId: messageId, groupId: groupId);
    }

    // Update UI
    loadChats();

    // Show notification if not currently viewing this group
    if (FCMService.activeChatId != groupId) {
      final badgeService = Get.find<BadgeService>();
      await badgeService.incrementBadge();
    }
  }

  /// Handle group_created event (e.g. when added to a new group).
  Future<void> _onGroupCreated(Map<String, dynamic> data) async {
    debugPrint('👥 CHAT LIST LOG: group_created: $data');
    final groupData = data['group'] as Map<String, dynamic>?;
    if (groupData == null) return;
    await _saveGroupAndRefresh(groupData);
  }

  /// Handle group member added/removed/left events.
  Future<void> _onGroupMemberChange(Map<String, dynamic> data) async {
    debugPrint('👥 CHAT LIST LOG: group member change: $data');
    final groupId = data['groupId']?.toString();
    if (groupId == null) return;
    await _refreshGroupFromServer(groupId);
  }

  /// Handle group_info_updated event.
  Future<void> _onGroupInfoUpdated(Map<String, dynamic> data) async {
    debugPrint('👥 CHAT LIST LOG: group_info_updated: $data');
    final groupId = data['groupId']?.toString();
    if (groupId == null) return;
    await _refreshGroupFromServer(groupId);
  }

  /// Handle group_dissolved event.
  Future<void> _onGroupDissolved(Map<String, dynamic> data) async {
    debugPrint('👥 CHAT LIST LOG: group_dissolved: $data');
    final groupId = data['groupId']?.toString();
    if (groupId == null) return;
    await _storageService.deleteChat(groupId);
    loadChats();
  }

  Future<void> _saveGroupAndRefresh(Map<String, dynamic> groupData) async {
    final deviceId = _storageService.deviceId;
    if (deviceId == null || deviceId.isEmpty) return;
    await _storageService.saveGroupChatFromApi(groupData, myDeviceId: deviceId);
    loadChats();
  }

  Future<void> _refreshGroupFromServer(String groupId) async {
    final deviceId = _storageService.deviceId;
    if (deviceId == null || deviceId.isEmpty) return;
    try {
      final response =
          await _apiService.getGroup(groupId: groupId, deviceId: deviceId);
      final groupData = response['group'] as Map<String, dynamic>?;
      if (groupData != null) {
        await _storageService.saveGroupChatFromApi(groupData,
            myDeviceId: deviceId);
        loadChats();
      }
    } catch (e) {
      debugPrint('⚠️ Failed to refresh group $groupId: $e');
    }
  }

  /// Check if message already exists locally (deduplication)
  bool _messageExists(String messageId) {
    try {
      return _storageService.messageExists(messageId);
    } catch (e) {
      debugPrint('⚠️ Error checking message existence: $e');
      return false;
    }
  }

  void loadChats() {
    try {
      final allChats = _storageService.getAllChats();
      debugPrint('📦 Loaded ${allChats.length} chats from storage');

      chats.clear();
      for (final chat in allChats) {
        chats.add(
          ChatListModel(
            id: chat.id,
            userName: chat.isGroupChat
                ? (chat.groupName ?? chat.userName)
                : chat.userName,
            lastMessage: chat.lastMessage ?? '',
            lastMessageTime: chat.lastMessageTime ?? DateTime.now(),
            unreadCount: chat.unreadCount,
            isGroup: chat.isGroupChat,
          ),
        );
      }

      // Sort by last message time (most recent first)
      chats.sort((a, b) {
        final aTime =
            a.lastMessageTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime =
            b.lastMessageTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });

      filteredChats.value = List.from(chats);

      // Recalculate total unread count and update badge
      recalculateTotalUnreadCount();
    } catch (e) {
      debugPrint('❌ Error loading chats: $e');
    }
  }

  void loadConnectionRequests() {
    try {
      final requests = _storageService.getPendingConnectionRequests();
      pendingConnectionRequests.clear();
      pendingConnectionRequests.addAll(requests);
      debugPrint(
        '📦 DEBUG: Loaded ${requests.length} pending connection requests',
      );
      for (var request in requests) {
        debugPrint(
          '📋 DEBUG: Request - ID: ${request.id}, Sender: ${request.senderDeviceId}, Content: ${request.messageContent}',
        );
      }
    } catch (e) {
      debugPrint('❌ ERROR: Loading connection requests: $e');
    }
  }

  void removeConnectionRequest(String requestId) {
    pendingConnectionRequests.removeWhere((request) => request.id == requestId);
    debugPrint('🗑️ Removed connection request from UI: $requestId');
  }

  void searchChats(String query) {
    if (query.isEmpty) {
      filteredChats.value = chats;
    } else {
      filteredChats.value = chats
          .where(
            (chat) =>
                chat.userName.toLowerCase().contains(query.toLowerCase()) ||
                (chat.lastMessage?.toLowerCase().contains(
                          query.toLowerCase(),
                        ) ??
                    false),
          )
          .toList();
    }
  }

  /// Create a new group and open it.
  Future<void> createGroup({
    required String name,
    required List<String> memberDeviceIds,
  }) async {
    try {
      final deviceId = _storageService.deviceId;
      if (deviceId == null || deviceId.isEmpty) {
        Get.snackbar('Error', 'Device ID not available');
        return;
      }

      final response = await _apiService.createGroup(
        name: name.trim(),
        createdBy: deviceId,
        memberDeviceIds: memberDeviceIds,
      );
      final groupData = response['group'] as Map<String, dynamic>?;
      if (groupData == null) {
        Get.snackbar('Error', 'Failed to create group');
        return;
      }

      final chat = await _storageService.saveGroupChatFromApi(
        groupData,
        myDeviceId: deviceId,
      );
      if (chat == null) {
        Get.snackbar('Error', 'Failed to save group');
        return;
      }

      loadChats();

      Get.toNamed(
        AppRoutes.chat,
        arguments: {
          'chatId': chat.id,
          'userName': chat.groupName ?? chat.userName,
          'recipientDeviceId': chat.id,
          'myDeviceId': deviceId,
          'isGroup': true,
          'members': chat.members.map((m) => m.toJson()).toList(),
        },
      );
    } catch (e) {
      debugPrint('❌ Error creating group: $e');
      Get.snackbar('Error', 'Failed to create group: $e');
    }
  }

  void openChat(ChatListModel chat) {
    // Check if this is a pending connection request for the sender
    bool isPendingConnection = false;
    bool firstMessageSent = false;

    // Check if the last message indicates a pending connection
    if (chat.lastMessage == 'Connection request sent...') {
      isPendingConnection = true;
      firstMessageSent = true; // Since they already sent the request
    }

    final isGroup = chat.isGroup;
    final chatEntity = _storageService.getChat(chat.id);

    Get.toNamed(
      AppRoutes.chat,
      arguments: {
        'chatId': chat.id,
        'userName': chat.userName,
        'recipientDeviceId': chat.id, // Use chat ID as recipient device ID
        'myDeviceId': _storageService.deviceId, // Add current user's device ID
        'isPendingConnection': isPendingConnection,
        'firstMessageSent': firstMessageSent,
        'isGroup': isGroup,
        'members': chatEntity?.members.map((m) => m.toJson()).toList() ?? [],
      },
    );
  }

  void showChatOptions(ChatListModel chat) {
    final nameController = TextEditingController(text: chat.userName);

    Get.bottomSheet(
      Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(AppSizes.paddingL),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: const BoxDecoration(
                    color: AppColors.senderBubble,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.person,
                    color: AppColors.textPrimary,
                    size: 30,
                  ),
                ),
                const SizedBox(width: AppSizes.paddingM),
                Expanded(
                  child: Text('Edit Contact', style: Get.textTheme.titleLarge),
                ),
              ],
            ),
            const SizedBox(height: AppSizes.paddingXL),

            // Name field
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Contact Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSizes.paddingXL),

            // Action buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      final newName = nameController.text.trim();
                      if (newName.isNotEmpty) {
                        _renameChatUser(chat, newName);
                      }
                      Get.back();
                    },
                    icon: const Icon(Icons.save),
                    label: const Text('Save'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: AppSizes.paddingM),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Get.back();
                      _showDeleteConfirmation(chat);
                    },
                    icon: const Icon(Icons.delete),
                    label: const Text('Delete Chat'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.error,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
      isScrollControlled: true,
    );
  }

  void _renameChatUser(ChatListModel chat, String newName) {
    // Update the chat in storage
    final chatEntity = ChatEntity(
      id: chat.id,
      userName: newName,
      lastMessage: chat.lastMessage,
      lastMessageTime: chat.lastMessageTime,
      unreadCount: chat.unreadCount,
      isReply: chat.isReply,
      replyContent: chat.replyContent,
    );
    _storageService.saveChat(chatEntity);

    // Update the local list
    final index = chats.indexWhere((c) => c.id == chat.id);
    if (index != -1) {
      chats[index] = ChatListModel(
        id: chat.id,
        userName: newName,
        lastMessage: chat.lastMessage,
        lastMessageTime: chat.lastMessageTime,
        unreadCount: chat.unreadCount,
      );

      // Update filtered chats as well
      final filteredIndex = filteredChats.indexWhere((c) => c.id == chat.id);
      if (filteredIndex != -1) {
        filteredChats[filteredIndex] = chats[index];
      }
    }

    Get.snackbar(
      'Success',
      'Chat name updated to "$newName"',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  void _deleteChat(ChatListModel chat) async {
    try {
      debugPrint('🗑️ Attempting to delete chat: ${chat.id}');

      // Delete chat and all its messages from local storage
      await _storageService.deleteChat(chat.id);

      // Remove from UI list
      chats.removeWhere((c) => c.id == chat.id);

      // Update filtered chats as well
      filteredChats.value = List.from(chats);

      Get.snackbar(
        'Deleted',
        'Chat deleted successfully',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );

      debugPrint('✅ Chat deleted from UI: ${chat.id}');
    } catch (e) {
      debugPrint('❌ Failed to delete chat: $e');
      Get.snackbar(
        'Error',
        'Failed to delete chat: $e',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
      );
    }
  }

  /// Calculate actual unread count for a chat by counting unread messages in storage
  Future<int> _calculateUnreadCount(String chatId) async {
    try {
      final messages = await _storageService.getChatMessages(chatId);
      return messages
          .where((msg) => !msg.isMe && msg.status != MessageStatus.read)
          .length;
    } catch (e) {
      debugPrint('📊 Error calculating unread count for $chatId: $e');
      return 0;
    }
  }

  /// Recalculate total unread count across all chats and update badge
  Future<void> recalculateTotalUnreadCount() async {
    try {
      final allChats = _storageService.getAllChats();
      final totalUnread = allChats.fold<int>(
        0,
        (sum, chat) => sum + chat.unreadCount,
      );
      debugPrint('📊 Total unread count recalculated: $totalUnread');

      final badgeService = Get.find<BadgeService>();
      await badgeService.setTotalUnreadCount(totalUnread);
    } catch (e) {
      debugPrint('⚠️ Error recalculating total unread count: $e');
    }
  }

  void _showDeleteConfirmation(ChatListModel chat) {
    Get.defaultDialog(
      title: 'Delete Chat',
      middleText:
          'Are you sure you want to delete this conversation with ${chat.userName}? This action cannot be undone.',
      textConfirm: 'Delete',
      textCancel: 'Cancel',
      confirmTextColor: Colors.white,
      cancelTextColor: Colors.blue,
      buttonColor: Colors.red,
      onConfirm: () {
        _deleteChat(chat);
        Get.back(); // Close dialog
      },
    );
  }

  /// Get current device ID for sharing
  String getDeviceId() {
    return _storageService.deviceId ?? 'Unknown Device';
  }

  /// Initialize chat from scanned QR code - now sends connection request
  Future<void> initializeChatFromQR(String deviceId,
      {String? userName}) async {
    try {
      // Check if chat already exists in memory list
      ChatListModel? existingChatModel = chats.firstWhereOrNull(
        (chat) => chat.id == deviceId,
      );

      // If not in memory, check storage
      if (existingChatModel == null) {
        final storedChat = _storageService.getChat(deviceId);
        if (storedChat != null) {
          // Convert stored chat to model
          existingChatModel = ChatListModel(
            id: storedChat.id,
            userName: storedChat.userName,
            lastMessage: storedChat.lastMessage,
            lastMessageTime: storedChat.lastMessageTime,
            unreadCount: storedChat.unreadCount,
          );
          // Add to memory list
          chats.insert(0, existingChatModel);
        }
      }

      if (existingChatModel != null) {
        // Chat exists, show message and navigate
        Get.snackbar(
          'Opening Chat',
          'Continuing conversation with ${existingChatModel.userName}',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.blue,
          colorText: Colors.white,
          duration: const Duration(seconds: 2),
        );

        // Navigate to existing chat (replacing QR scanner screen)
        Get.offAllNamed(
          AppRoutes.chat,
          arguments: {
            'chatId': deviceId,
            'userName': existingChatModel.userName,
            'recipientDeviceId': deviceId,
            'myDeviceId':
                _storageService.deviceId, // Add current user's device ID
          },
          predicate: (route) => route.settings.name == AppRoutes.chatList,
        );
        return;
      }

      // New contact - navigate to chat screen with pending connection state
      // Connection request will be sent when user types their first message
      try {
        // Resolve the real display name: QR-carried name -> saved contact ->
        // server profile -> friendly fallback. The bare getDisplayName()
        // used to return the generated @user_xxxxx handle for new contacts.
        final friendlyName = await CallerNameResolver.resolve(
          deviceId,
          payloadName: userName,
        );

        debugPrint(
          '📱 DEBUG: Navigating to chat screen for new contact: $deviceId',
        );

        // Persist the chat so it survives app restarts
        final newChatEntity = ChatEntity(
          id: deviceId,
          userName: friendlyName,
          lastMessage: '',
          lastMessageTime: DateTime.now(),
          unreadCount: 0,
          isReply: false,
          replyContent: null,
        );
        await _storageService.saveChat(newChatEntity);

        // Add to in-memory list so it shows immediately in the chat list
        final newChatModel = ChatListModel(
          id: deviceId,
          userName: friendlyName,
          lastMessage: '',
          lastMessageTime: DateTime.now(),
          unreadCount: 0,
        );
        chats.insert(0, newChatModel);
        filteredChats.value = List.from(chats);

        // Navigate to chat screen so user can send first message
        // Do NOT send connection request here - wait for first message
        Get.offAllNamed(
          AppRoutes.chat,
          arguments: {
            'chatId': deviceId,
            'userName': friendlyName,
            'recipientDeviceId': deviceId,
            'myDeviceId':
                _storageService.deviceId, // Add current user's device ID
            'isPendingConnection': true,
            'firstMessageSent': false,
          },
          predicate: (route) => route.settings.name == AppRoutes.chatList,
        );
      } catch (e) {
        Get.snackbar(
          'Error',
          'Failed to process QR code: ${e.toString()}',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 3),
        );
      }
    } catch (e) {
      Get.snackbar(
        'Error',
        'Failed to initialize chat from QR: ${e.toString()}',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
      );
    }
  }

  @override
  void onClose() {
    searchController.dispose();
    super.onClose();
  }
}
