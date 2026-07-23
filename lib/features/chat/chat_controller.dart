import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pear_messaging/features/chat_list/chat_list_model.dart';
import 'package:uuid/uuid.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/fcm_service.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/services/socket_service.dart';
import '../../core/services/block_service.dart';
import '../../core/services/image_cache_service.dart';
import '../../core/services/url_preview_service.dart';
import '../../core/services/badge_service.dart';
import '../../core/utils/presence_utils.dart';
import '../../storage/models/message_entity.dart';
import '../../storage/models/chat_entity.dart';
import '../../storage/models/reply_to_entity.dart';
import '../chat_list/chat_list_controller.dart';
import 'chat_message_model.dart';

class ChatController extends GetxController with WidgetsBindingObserver {
  final LocalStorageService _storageService = Get.find();
  final SocketService _socketService = Get.find();
  final BlockService _blockService = Get.find();
  final UrlPreviewService _urlPreviewService = Get.find();
  final _uuid = const Uuid(); // Initialize UUID generator

  bool _isDisposed = false;
  bool _isScreenActive = false;
  final Map<String, Timer> _messageTimeouts = {};
  static const int _messageTimeoutSeconds = 45;

  /// Upload progress per messageId (0.0 → 1.0). Consumed by the bubble widget.
  final Map<String, RxDouble> uploadProgressMap = {};

  // URL Preview
  final Rx<UrlPreview?> currentUrlPreview = Rx<UrlPreview?>(null);
  final RxBool isPreviewLoading = false.obs;

  late String chatId;
  late String
      recipientDeviceId; // The recipient's device ID for socket messaging
  late String myDeviceId;

  final TextEditingController messageController = TextEditingController();
  final ScrollController scrollController = ScrollController();
  final FocusNode messageFocusNode = FocusNode();

  final RxList<ChatMessageModel> messages = <ChatMessageModel>[].obs;
  final RxBool isConnected = false.obs;
  final RxString connectionStatus = 'Offline'.obs;
  final RxBool isTyping = false.obs;

  final RxBool recipientTyping = false.obs;
  final RxBool recipientOnline = false.obs;
  final Rx<DateTime?> recipientLastSeen = Rx<DateTime?>(null);
  final RxString displayName = ''.obs;
  final RxBool isBlockedByMe = false.obs;
  final RxBool hasBlockedMe = false.obs;
  final RxBool isBlocked = false.obs; // true if either direction is blocked
  final RxDouble scrollPosition = 0.0.obs; // For floating button visibility
  final RxString recipientStatus = ''.obs; // For UI display
  final RxBool isMuted = false.obs; // Notification mute status for this chat

  // Reply state management
  final Rx<ReplyToEntity?> replyToMessage = Rx<ReplyToEntity?>(null);

  // Pagination
  static const int _pageSize = 30;
  final RxBool hasMoreMessages = true.obs;
  final RxBool isLoadingMore = false.obs;
  List<MessageEntity> _allMessageEntities = [];

  @override
  void onInit() {
    final initStart = DateTime.now();
    debugPrint(
        '⏱️ ChatController.onInit() START: ${initStart.millisecondsSinceEpoch}');
    super.onInit();

    // Get arguments
    final args = Get.arguments as Map<String, dynamic>;
    chatId = args['chatId'] ?? '';
    displayName.value = args['userName'] ?? 'Unknown';
    recipientDeviceId = args['recipientDeviceId'] ?? '';
    myDeviceId = args['myDeviceId'] ?? '';

    // Initialize scroll position
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollPosition.value = scrollController.offset;
      }
    });

    // Add scroll listener for floating button
    scrollController.addListener(() {
      if (scrollController.hasClients) {
        scrollPosition.value = scrollController.offset;
      }
    });

    // Initialize block state from global service
    _updateLocalBlockState();

    // Listen to global block state changes
    ever(_blockService.blockedUsersRx, (Map<String, bool> blockedUsers) {
      // Update local block state when global block state changes
      _updateLocalBlockState();
    });

    // Setup socket listeners
    _setupSocketListeners();
    unawaited(_socketService.processPendingMessages());

    // Listen to connection status
    ever(_socketService.isConnected, (bool connected) {
      isConnected.value = connected;
      connectionStatus.value = connected ? 'Online' : 'Offline';

      // Check recipient presence and block status when we connect
      if (connected) {
        _checkRecipientPresence();
        _checkBlockStatus();
      } else {
        recipientOnline.value = false;
        _updatePresenceStatus();
      }
    });

    // Set initial connection status
    isConnected.value = _socketService.isConnected.value;
    connectionStatus.value =
        _socketService.isConnected.value ? 'Online' : 'Offline';

    // Load last seen timestamp from storage
    _loadLastSeenFromStorage();

    // Check recipient presence if already connected
    if (_socketService.isConnected.value) {
      _checkRecipientPresence();
      _checkBlockStatus();
    }

    // Mark this chat as active so foreground notifications are suppressed
    FCMService.activeChatId = recipientDeviceId;

    // Dismiss any existing notification for this sender
    _dismissNotificationForSender(recipientDeviceId);

    // Load messages after first frame so navigation animation starts instantly
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMessages();
      _markMessagesAsRead();

      // Decrement badge count by this chat's unread count
      _decrementBadgeForChat();

      // Also refresh from storage to catch any messages saved by background FCM handler
      // This ensures messages from notifications are visible immediately
      refreshMessagesFromStorage();

      // Add another refresh after a short delay to catch any race conditions
      Future.delayed(const Duration(milliseconds: 500), () {
        refreshMessagesFromStorage();
        _markMessagesAsRead();
      });
    });
    _isScreenActive = true;
    debugPrint('📱 ChatController.onInit: _isScreenActive set to true');

    // Register lifecycle observer to detect app background/foreground
    WidgetsBinding.instance.addObserver(this);

    final initEnd = DateTime.now();
    debugPrint(
        '⏱️ ChatController.onInit() END: ${initEnd.millisecondsSinceEpoch} (${initEnd.difference(initStart).inMicroseconds}μs)');
  }

  Future<void> _loadMessages() async {
    final loadStart = DateTime.now();
    debugPrint('⏱️ _loadMessages() START: ${loadStart.millisecondsSinceEpoch}');
    try {
      final storageStart = DateTime.now();
      _allMessageEntities = await _storageService.getChatMessages(chatId);
      final storageEnd = DateTime.now();
      debugPrint(
          '⏱️ getChatMessages() took: ${storageEnd.difference(storageStart).inMicroseconds}μs');

      final totalCount = _allMessageEntities.length;

      // Load only the last _pageSize messages initially
      final startIndex = (totalCount - _pageSize).clamp(0, totalCount);

      final mapStart = DateTime.now();
      messages.value = _allMessageEntities
          .sublist(startIndex)
          .map((msg) => ChatMessageModel.fromEntity(msg))
          .toList();
      final mapEnd = DateTime.now();
      debugPrint(
          '⏱️ Message mapping took: ${mapEnd.difference(mapStart).inMicroseconds}μs');

      hasMoreMessages.value = startIndex > 0;

      final loadEnd = DateTime.now();
      debugPrint(
          '📨 Loaded ${messages.length} of $totalCount messages for chat: $chatId');
      debugPrint(
          '⏱️ _loadMessages() TOTAL: ${loadEnd.difference(loadStart).inMicroseconds}μs');

      // Mark any delivered messages as read since user is now viewing the chat
      _markMessagesAsRead();
    } catch (e) {
      debugPrint('📨 Error getting messages: $e');
    }
  }

  /// Load older messages when user scrolls to top
  void loadMoreMessages() {
    if (isLoadingMore.value || !hasMoreMessages.value) return;
    isLoadingMore.value = true;

    try {
      final currentDisplayed = messages.length;
      final totalCount = _allMessageEntities.length;
      final remainingCount = totalCount - currentDisplayed;

      if (remainingCount <= 0) {
        hasMoreMessages.value = false;
        isLoadingMore.value = false;
        return;
      }

      // Load next batch of older messages
      final loadCount = remainingCount.clamp(0, _pageSize);
      final startIndex = remainingCount - loadCount;
      final olderMessages = _allMessageEntities
          .sublist(startIndex, startIndex + loadCount)
          .map((msg) => ChatMessageModel.fromEntity(msg))
          .toList();

      // Prepend older messages to the beginning
      messages.insertAll(0, olderMessages);

      hasMoreMessages.value = startIndex > 0;
      debugPrint(
          '📨 Loaded ${olderMessages.length} more messages. Total displayed: ${messages.length}');
    } catch (e) {
      debugPrint('📨 Error loading more messages: $e');
    } finally {
      isLoadingMore.value = false;
    }
  }

  /// Refresh messages from local storage (called when app resumes from background)
  Future<void> refreshMessagesFromStorage() async {
    try {
      debugPrint('🔄 Refreshing messages from storage for chat: $chatId');
      _allMessageEntities = await _storageService.getChatMessages(chatId);
      final totalCount = _allMessageEntities.length;

      if (totalCount == 0) {
        messages.clear();
        hasMoreMessages.value = false;
        return;
      }

      // Keep showing at least as many messages as currently displayed
      final currentCount = messages.length;
      final maxDisplay = totalCount > 0 ? totalCount : 0;
      final displayCount = currentCount > 0
          ? currentCount.clamp(_pageSize.clamp(0, maxDisplay), maxDisplay)
          : _pageSize.clamp(0, maxDisplay);

      // Ensure startIndex is valid
      final startIndex = (totalCount - displayCount).clamp(0, totalCount);

      // Safety check before sublist
      if (startIndex >= totalCount) {
        debugPrint(
            '⚠️ Invalid startIndex: $startIndex >= $totalCount, using 0');
        messages.value = _allMessageEntities
            .map((msg) => ChatMessageModel.fromEntity(msg))
            .toList();
        hasMoreMessages.value = false;
        return;
      }

      final newMessages = _allMessageEntities
          .sublist(startIndex)
          .map((msg) => ChatMessageModel.fromEntity(msg))
          .toList();

      final lastNewId = newMessages.isNotEmpty ? newMessages.last.id : null;
      final lastCurrentId = messages.isNotEmpty ? messages.last.id : null;
      if (newMessages.length != messages.length || lastNewId != lastCurrentId) {
        debugPrint(
            '📬 Found new messages from storage (${messages.length} → ${newMessages.length})');
        messages.value = newMessages;
        hasMoreMessages.value = startIndex > 0;
      }
    } catch (e, stackTrace) {
      debugPrint('🔄 Error refreshing messages from storage: $e');
      debugPrint('Stack trace: $stackTrace');
    }
  }

  // Store the previous handler to chain calls
  Function(Map<String, dynamic>)? _previousMessageHandler;

  /// Check recipient's online presence
  void _checkRecipientPresence() {
    _socketService.checkPresence(recipientDeviceId);
  }

  /// Check block status with the recipient
  void _checkBlockStatus() {
    _socketService.checkBlockStatus(recipientDeviceId);
  }

  /// Block the current chat recipient
  void blockUser() {
    _blockService.blockUser(recipientDeviceId);
    // Update local state to match global state
    _updateLocalBlockState();
  }

  /// Unblock the current chat recipient
  void unblockUser() {
    _blockService.unblockUser(recipientDeviceId);
    // Update local state to match global state
    _updateLocalBlockState();
  }

  /// Update local block state from global BlockService
  void _updateLocalBlockState() {
    final isBlockedGlobally = _blockService.isUserBlocked(recipientDeviceId);
    final wasBlocked = isBlockedByMe.value;
    isBlockedByMe.value = isBlockedGlobally;
    isBlocked.value = isBlockedGlobally || hasBlockedMe.value;

    // Log when block state changes
    if (wasBlocked != isBlockedGlobally) {
      debugPrint(
          '🔄 Chat block state updated for $recipientDeviceId: ${wasBlocked ? "blocked" : "unblocked"} → ${isBlockedGlobally ? "blocked" : "unblocked"}');
    }
  }

  /// Update presence status using PresenceUtils
  void _updatePresenceStatus() {
    recipientStatus.value = PresenceUtils.getPresenceText(
      recipientOnline.value,
      recipientLastSeen.value,
    );
  }

  /// Load last seen timestamp from storage
  void _loadLastSeenFromStorage() {
    try {
      final timestamp = _storageService.getLastSeen(recipientDeviceId);
      if (timestamp != null) {
        recipientLastSeen.value =
            DateTime.fromMillisecondsSinceEpoch(timestamp);
        _updatePresenceStatus();
      }
    } catch (e) {
      debugPrint('⚠️ Error loading last seen from storage: $e');
    }
  }

  /// Save last seen timestamp to storage
  void _saveLastSeenToStorage() {
    try {
      if (recipientLastSeen.value != null) {
        _storageService.setLastSeen(
          recipientDeviceId,
          recipientLastSeen.value!.millisecondsSinceEpoch,
        );
      }
    } catch (e) {
      debugPrint('⚠️ Error saving last seen to storage: $e');
    }
  }

  /// Mark all unread messages from this chat as read
  Future<void> _markMessagesAsRead() async {
    debugPrint('📖 Marking messages as read...');
    debugPrint('📖 Total messages in chat: ${messages.length}');

    // Debug: Show all message statuses
    for (final msg in messages) {
      debugPrint(
          '📖 Message ${msg.id}: isMe=${msg.isMe}, status=${msg.status}');
    }

    // Find all unread messages from the recipient in this chat
    final unreadMessages = messages
        .where((msg) => !msg.isMe && msg.status != MessageStatus.read)
        .toList();

    debugPrint(
        '📖 Found ${unreadMessages.length} unread messages to mark as read');
    for (final msg in unreadMessages) {
      debugPrint(
          '📖 Unread message: ${msg.id} - isMe: ${msg.isMe} - status: ${msg.status}');
    }

    // Update message status in storage and UI
    for (final message in unreadMessages) {
      debugPrint('📖 Marking message as read: ${message.id}');

      try {
        // Check original status before updating to determine if we should send read acknowledgment
        final originalStatus = message.status;
        debugPrint(
            '📖 Original message status: ${message.id} -> $originalStatus');

        // Update in storage first
        await _storageService.updateMessageStatus(
            message.id, MessageStatus.read);

        // Update in UI
        final index = messages.indexWhere((msg) => msg.id == message.id);
        if (index != -1) {
          messages[index] = ChatMessageModel(
            id: messages[index].id,
            content: messages[index].content,
            isMe: messages[index].isMe,
            timestamp: messages[index].timestamp,
            status: MessageStatus.read,
            type: messages[index].type,
            mediaToken: messages[index].mediaToken,
            mediaExpiryTimestamp: messages[index].mediaExpiryTimestamp,
            replyTo: messages[index].replyTo,
          );
        }

        // Send read acknowledgment to sender for delivered messages
        // This ensures sender sees blue checkmarks even if message was delivered while app was in background
        // Check original status BEFORE it was updated to read
        if (originalStatus == MessageStatus.delivered) {
          debugPrint(
              '📖 Sending read acknowledgment for delivered message: ${message.id} to recipient: $recipientDeviceId');
          _socketService.sendReadAck(message.id, recipientDeviceId);
        } else {
          debugPrint(
              '📖 Not sending read acknowledgment for message ${message.id} - original status: $originalStatus');
        }
      } catch (e) {
        debugPrint('❌ Error marking message as read: ${message.id}, $e');
      }
    }

    if (unreadMessages.isNotEmpty) {
      debugPrint(
          '📖 Marked ${unreadMessages.length} messages as read for chat: $chatId');

      // Update chat entity's unreadCount to 0 in storage
      try {
        final chat = _storageService.getChat(chatId);
        if (chat != null) {
          final updatedChat = chat.copyWith(unreadCount: 0);
          await _storageService.saveChat(updatedChat);
          debugPrint('📖 Reset unreadCount to 0 for chat: $chatId');
        }
      } catch (e) {
        debugPrint('⚠️ Error resetting unreadCount for chat $chatId: $e');
      }

      // Recalculate total unread count and update badge
      try {
        final chatListController = Get.find<ChatListController>();
        await chatListController.recalculateTotalUnreadCount();
        debugPrint('📖 Recalculated total unread count and updated badge');
      } catch (e) {
        debugPrint('⚠️ Error recalculating total unread count: $e');
      }

      // Notify ChatListController to refresh unread counts
      try {
        final chatListController = Get.find<ChatListController>();
        debugPrint('📖 Refreshing chat list to update unread counts');
        chatListController.loadChats();
      } catch (e) {
        debugPrint(
            '⚠️ ChatListController not found, unread count will update on restart');
      }
    } else {
      debugPrint('📖 No unread messages found to mark as read');
    }
  }

  void _setupSocketListeners() {
    // Store the previous handler (from ChatListController)
    _previousMessageHandler = _socketService.onMessageReceived;

    // Setup presence listeners when socket connects
    _setupPresenceListeners();

    // Re-setup listeners when socket reconnects
    ever(_socketService.isConnected, (bool connected) {
      if (connected) {
        _setupPresenceListeners();
        // Flush any messages that were queued while the socket was offline
        _flushOutbox();
        // Safety net: refresh from storage after reconnect to catch any messages
        // that arrived via FCM or other paths while socket was disconnected.
        // Delay allows pending_messages to arrive and be processed first.
        Future.delayed(const Duration(milliseconds: 1000), () {
          refreshMessagesFromStorage();
          _markMessagesAsRead();
        });
      }
    });
  }

  void _setupPresenceListeners() {
    // Remove existing listeners to avoid duplicates
    _socketService.socket?.off('presence_status');
    _socketService.socket?.off('device_online');
    _socketService.socket?.off('device_offline');

    // Setup block event listeners
    _setupBlockListeners();

    // Connection request listener is now handled in onMessageReceived above

    // Handle presence status responses
    _socketService.socket?.on('presence_status', (data) {
      debugPrint('📡 Presence status received: $data');
      if (data['deviceId'] == recipientDeviceId) {
        recipientOnline.value = data['online'] ?? false;

        // Update last seen if user was online
        if (recipientOnline.value) {
          recipientLastSeen.value = DateTime.now();
          _saveLastSeenToStorage();
        }

        _updatePresenceStatus();
      }
    });

    // Handle device online/offline broadcasts
    _socketService.socket?.on('device_online', (data) {
      debugPrint('📡 Device came online: $data');
      if (data['deviceId'] == recipientDeviceId) {
        recipientOnline.value = true;
        recipientLastSeen.value = DateTime.now();
        _saveLastSeenToStorage();
        _updatePresenceStatus();
      }
    });

    _socketService.socket?.on('device_offline', (data) {
      debugPrint('📡 Device went offline: $data');
      if (data['deviceId'] == recipientDeviceId) {
        recipientOnline.value = false;
        recipientLastSeen.value = DateTime.now();
        _saveLastSeenToStorage();
        _updatePresenceStatus();
      }
    });

    // Handle incoming messages - chain with previous handler
    _socketService.onMessageReceived = (Map<String, dynamic> data) async {
      debugPrint('📩 ChatController received message: $data');

      // Always call the previous handler first (ChatListController)
      // This ensures chat list is updated
      final previousResult = _previousMessageHandler?.call(data);
      if (previousResult is Future) await previousResult;

      // Match backend field names: messageId, senderDeviceId, encryptedPayload, timestamp
      final senderId = data['senderDeviceId'] as String;
      // Only add to UI if message is from the current chat recipient
      if (senderId == recipientDeviceId) {
        // Check if sender is blocked by current user
        if (isBlockedByMe.value) {
          debugPrint('🚫 Message from blocked user $senderId ignored');
          return;
        }

        var decryptedContent =
            SocketService.decryptMessage(data['encryptedPayload'] ?? '');
        final timestamp =
            DateTime.fromMillisecondsSinceEpoch(data['timestamp'] ?? 0);

        // Check if message already exists in Hive (FCM may have saved it) or UI
        final messageId = data['messageId'] ?? _uuid.v4();
        final existsInUi = messages.any((m) => m.id == messageId);
        if (existsInUi) {
          debugPrint('🔁 Socket message $messageId already in UI, skipping');
          return;
        }

        // Check if message exists in Hive but not in UI (race condition fix)
        final existsInHive = _storageService.messageExists(messageId);
        if (existsInHive) {
          debugPrint(
              '🔁 Socket message $messageId exists in Hive but not UI, adding to UI');
          // Load the message from Hive and add to UI
          final savedMessages =
              await _storageService.getChatMessages(recipientDeviceId);
          final savedMessage =
              savedMessages.firstWhere((m) => m.id == messageId,
                  orElse: () => MessageEntity(
                        id: '',
                        chatId: '',
                        senderId: '',
                        receiverId: '',
                        content: '',
                        timestamp: DateTime.now(),
                        status: MessageStatus.sending,
                        isMe: false,
                      ));
          if (savedMessage.id.isNotEmpty) {
            messages.add(ChatMessageModel.fromEntity(savedMessage));
            _scrollToBottom();
            // Mark as read if screen is active
            if (_isScreenActive) {
              _updateMessageStatusIfNotRead(messageId, MessageStatus.read);
              _socketService.sendReadAck(messageId, senderId);
            }
            return;
          }
        }

        // Determine message type
        MessageType messageType = MessageType.text;
        if (decryptedContent.startsWith('MEDIA:') ||
            decryptedContent.startsWith('IMAGE:')) {
          messageType = MessageType.image;
        }

        // Parse reply metadata if present
        ReplyToEntity? replyTo;
        if (data['replyTo'] != null) {
          try {
            replyTo =
                ReplyToEntity.fromJson(data['replyTo'] as Map<String, dynamic>);
            debugPrint('🔁 Reply metadata parsed: ${replyTo.messageId}');
          } catch (e) {
            debugPrint('⚠️ Failed to parse reply metadata: $e');
          }
        }

        // Check if message already exists in storage (saved by FCM background handler)
        final messageExists = _storageService.messageExists(messageId);
        debugPrint(
            '📨 Socket message: $messageId, chatId: $chatId, messageExists: $messageExists, _isScreenActive: $_isScreenActive');

        // Mark as read only if:
        // 1. User is actively viewing this chat screen AND
        // 2. Message doesn't already exist in storage (to prevent overwriting FCM-saved delivered status)
        final messageStatus = (_isScreenActive && !messageExists)
            ? MessageStatus.read
            : MessageStatus.delivered;

        debugPrint('📨 Socket message status: $messageStatus');

        final message = MessageEntity(
          id: messageId,
          chatId: chatId,
          senderId: senderId,
          receiverId: myDeviceId,
          content: decryptedContent,
          timestamp: timestamp,
          status: messageStatus,
          isMe: false,
          type: messageType,
          replyTo: replyTo,
        );

        await _storageService.saveMessage(message);

        // Add message to chat
        messages.add(ChatMessageModel.fromEntity(message));

        // Send read ack only if screen is active
        if (_isScreenActive) {
          _socketService.sendReadAck(messageId, senderId);
          // Update storage status to read (saved as delivered by ChatListController)
          _updateMessageStatusIfNotRead(messageId, MessageStatus.read);
        }

        _scrollToBottom();
      }
    };

    // Handle message status updates
    _socketService.onMessageStatus = (String messageId, String status) {
      debugPrint('📊 Message status update: $messageId -> $status');
      final index = messages.indexWhere((msg) => msg.id == messageId);
      if (index != -1) {
        MessageStatus newStatus;
        switch (status) {
          case 'sent':
            newStatus = MessageStatus.sent;
            break;
          case 'delivered':
            newStatus = MessageStatus.delivered;
            break;
          case 'stored':
            newStatus = MessageStatus.sent; // Backend stored message = sent
            break;
          case 'read':
            newStatus = MessageStatus.read;
            break;
          case 'failed':
            // Never downgrade from sent/delivered/read to failed
            // Server might send stale 'failed' status after message is already delivered
            if (messages[index].status != MessageStatus.sending) {
              debugPrint(
                  '📊 Ignoring failed status for $messageId - current status: ${messages[index].status} (not sending)');
              return;
            }
            newStatus = MessageStatus.failed;
            break;
          default:
            newStatus = MessageStatus.sending;
        }

        // If message is already read, don't downgrade to any other status
        if (messages[index].status == MessageStatus.read) {
          debugPrint('📊 Skipping status update for $messageId - already read');
          return;
        }

        debugPrint(
            '📊 Updating message status: $messageId ${messages[index].status} -> $newStatus');

        // Prevent status downgrade (e.g., from delivered back to sent, or from sent back to failed)
        final currentStatus = messages[index].status;
        if (_isStatusDowngrade(currentStatus, newStatus)) {
          debugPrint(
              '📊 Ignoring status downgrade for $messageId: $currentStatus -> $newStatus');
          return;
        }

        // Cancel timeout if message is successfully sent/delivered/read
        if (newStatus == MessageStatus.sent ||
            newStatus == MessageStatus.delivered ||
            newStatus == MessageStatus.read) {
          _messageTimeouts[messageId]?.cancel();
          _messageTimeouts.remove(messageId);
        }

        // Delegate to _updateMessageStatusIfNotRead which persists to Hive
        // and updates UI while preserving all fields (type, mediaToken, replyTo, etc.)
        _updateMessageStatusIfNotRead(messageId, newStatus);
      }
    };

    // Handle user offline notification
    _socketService.onUserOffline = (String recipientId) {
      if (recipientId == recipientDeviceId) {
        debugPrint('👤 Recipient is offline, message will be stored');
      }
    };
  }

  /// Setup block event listeners
  void _setupBlockListeners() {
    // Handle block status response
    _socketService.onBlockStatus = (Map<String, dynamic> data) {
      debugPrint('🚫 Block status received: $data');
      if (data['status'] == 'success' &&
          data['targetDeviceId'] == recipientDeviceId) {
        // Redis returns 0/1 integers instead of booleans
        isBlockedByMe.value =
            data['isBlockedByMe'] == true || data['isBlockedByMe'] == 1;
        hasBlockedMe.value =
            data['hasBlockedMe'] == true || data['hasBlockedMe'] == 1;
        isBlocked.value = isBlockedByMe.value || hasBlockedMe.value;
        debugPrint(
            '🚫 Block state updated - blockedByMe: ${isBlockedByMe.value}, blockedMe: ${hasBlockedMe.value}');
      }
    };

    // Handle user blocked notification (real-time)
    _socketService.onUserBlocked = (Map<String, dynamic> data) {
      debugPrint('🚫 User blocked event: $data');
      final status = data['status'] as String?;
      if (status == 'success' && data['targetDeviceId'] == recipientDeviceId) {
        // I blocked the recipient
        isBlockedByMe.value = true;
        isBlocked.value = true;
      } else if (status == 'blocked_by_other' &&
          data['blockerDeviceId'] == recipientDeviceId) {
        // Recipient blocked me
        hasBlockedMe.value = true;
        isBlocked.value = true;
      }
    };

    // Handle user unblocked notification (real-time)
    _socketService.onUserUnblocked = (Map<String, dynamic> data) {
      debugPrint('✅ User unblocked event: $data');
      final status = data['status'] as String?;
      if (status == 'success' && data['targetDeviceId'] == recipientDeviceId) {
        // I unblocked the recipient
        isBlockedByMe.value = false;
        isBlocked.value = hasBlockedMe.value;
      } else if (status == 'unblocked_by_other' &&
          data['unblockerDeviceId'] == recipientDeviceId) {
        // Recipient unblocked me
        hasBlockedMe.value = false;
        isBlocked.value = isBlockedByMe.value;

        // Check global block state before sending
        _updateLocalBlockState();

        // Prevent sending if blocked
        if (isBlocked.value) {
          debugPrint('🚫 Cannot send message - user is blocked');
          Get.snackbar(
            'Blocked',
            'You cannot send messages to this user',
            snackPosition: SnackPosition.BOTTOM,
            backgroundColor: Colors.red.shade100,
            colorText: Colors.red.shade800,
            duration: const Duration(seconds: 3),
          );
          messageController.clear();
          return;
        }

        final messageId = _uuid.v4();
        final timestamp = DateTime.now();

        // Create message entity for text message with sending status
        final message = MessageEntity(
          id: messageId,
          chatId: chatId,
          senderId: myDeviceId,
          receiverId: recipientDeviceId,
          content: 'Hello',
          timestamp: timestamp,
          status: MessageStatus.sending,
          isMe: true,
        );

        // Add to UI immediately with sending status
        messages.add(ChatMessageModel.fromEntity(message));
        messages.refresh(); // Force UI update

        // Save locally
        _storageService.saveMessage(message);

        // Update chat list immediately after sending
        _updateChatListAfterSending('Hello', timestamp);

        // Send via socket
        _socketService
            .sendMessage(
          messageId: messageId,
          recipientDeviceId: recipientDeviceId,
          content: 'Hello',
        )
            .then((success) {
          if (success) {
            _updateMessageStatusIfNotRead(messageId, MessageStatus.sent);
          }
          // If !success (socket disconnected): message stays in 'sending' state.
          // _flushOutbox() will retry automatically when socket reconnects.
          // Do not mark as failed immediately - let timeout mechanism handle it.
        });

        _scrollToBottom();
      }
    };
  }

  void sendMessage() {
    final text = messageController.text.trim();
    if (text.isEmpty) return;

    // Prevent sending if blocked
    if (isBlocked.value) {
      debugPrint('🚫 Cannot send message - user is blocked');
      return;
    }

    // Clear URL preview when sending message
    clearUrlPreview();

    final messageId = _uuid.v4();
    final timestamp = DateTime.now();

    // Create message entity with reply metadata if present
    final message = MessageEntity(
      id: messageId,
      chatId: chatId,
      senderId: myDeviceId,
      receiverId: recipientDeviceId,
      content: text,
      timestamp: timestamp,
      status: MessageStatus.sending,
      isMe: true,
      replyTo: replyToMessage.value,
    );

    // Add to UI
    messages.add(ChatMessageModel.fromEntity(message));

    // Clear input and reply state
    messageController.clear();
    final replyToData = replyToMessage.value?.toJson();
    cancelReply();

    // Save locally
    _storageService.saveMessage(message);

    // Update chat list immediately after sending
    _updateChatListAfterSending(text, timestamp);

    // Send via socket with reply metadata
    _socketService
        .sendMessage(
      messageId: messageId,
      recipientDeviceId: recipientDeviceId,
      content: text,
      replyTo: replyToData,
    )
        .then((success) {
      // Don't update status locally - wait for server status update
      // This prevents race condition where server sends 'failed' before local 'sent' update
      // Server will send 'sent'/'delivered'/'read' status via onMessageStatus callback
      if (!success) {
        debugPrint(
            '⚠️ Socket send failed for $messageId - keeping in sending state for retry');
      }
    });

    // Schedule timeout so message eventually shows as failed if never delivered
    _scheduleMessageTimeout(messageId);

    _scrollToBottom();
  }

  void onTyping(String text) {
    // Typing indicator could be added here if server supports it

    // Handle URL preview
    _handleUrlPreview(text);
  }

  /// Handle URL preview while typing
  void _handleUrlPreview(String text) {
    final urls = _urlPreviewService.extractUrls(text);

    if (urls.isEmpty) {
      // Clear preview if no URLs
      currentUrlPreview.value = null;
      return;
    }

    // Show loading state
    isPreviewLoading.value = true;

    // Preview the first URL found (WhatsApp shows one preview at a time)
    final firstUrl = urls.first;
    _urlPreviewService.previewUrlWithDebounce(firstUrl, (preview) {
      if (!_isDisposed) {
        currentUrlPreview.value = preview;
        isPreviewLoading.value = false;
      }
    });
  }

  /// Clear URL preview (call when sending message)
  void clearUrlPreview() {
    currentUrlPreview.value = null;
    isPreviewLoading.value = false;
  }

  /// Update chat list after sending a message
  void _updateChatListAfterSending(String messageContent, DateTime timestamp) {
    try {
      final chatListController = Get.find<ChatListController>();

      // Find the current chat in the list
      final chatIndex = chatListController.chats
          .indexWhere((chat) => chat.id == recipientDeviceId);

      if (chatIndex != -1) {
        // Update existing chat
        final existingChat = chatListController.chats[chatIndex];
        final updatedChat = ChatListModel(
          id: existingChat.id,
          userName: existingChat.userName,
          lastMessage: messageContent,
          lastMessageTime: timestamp,
          unreadCount: existingChat.unreadCount, // Keep existing unread count
        );

        // Move to top of list and update
        chatListController.chats.removeAt(chatIndex);
        chatListController.chats.insert(0, updatedChat);

        // Persist last-message update to storage
        _storageService.saveChat(
          ChatEntity(
            id: updatedChat.id,
            userName: updatedChat.userName,
            lastMessage: updatedChat.lastMessage,
            lastMessageTime: updatedChat.lastMessageTime,
            unreadCount: updatedChat.unreadCount,
            isReply: replyToMessage.value != null,
            replyContent: replyToMessage.value?.content,
          ),
        );

        // Update filtered chats to trigger UI refresh
        chatListController.filteredChats.value =
            List.from(chatListController.chats);

        debugPrint('✅ Chat list updated after sending message');
      } else {
        // Chat doesn't exist in list yet — create and persist it now so it
        // survives app restarts and appears in the chat list immediately.
        debugPrint(
            '📝 Chat not in list yet — creating new chat entry for: $recipientDeviceId');

        final newChat = ChatEntity(
          id: recipientDeviceId,
          userName: displayName.value,
          lastMessage: messageContent,
          lastMessageTime: timestamp,
          unreadCount: 0,
          isReply: replyToMessage.value != null,
          replyContent: replyToMessage.value?.content,
        );
        _storageService.saveChat(newChat);

        final newChatModel = ChatListModel(
          id: recipientDeviceId,
          userName: displayName.value,
          lastMessage: messageContent,
          lastMessageTime: timestamp,
          unreadCount: 0,
          isReply: replyToMessage.value != null,
          replyContent: replyToMessage.value?.content,
        );
        chatListController.chats.insert(0, newChatModel);
        chatListController.filteredChats.value =
            List.from(chatListController.chats);

        debugPrint(
            '✅ New chat entry created and persisted for: $recipientDeviceId');
      }
    } catch (e) {
      debugPrint(
          '⚠️ ChatListController not found, chat list will update on next load: $e');
    }
  }

  /// Step 1 of WhatsApp-style image send:
  /// Add the bubble immediately with [localBytes] preview and uploading state.
  /// Returns the messageId so the caller can track progress and finalize.
  Future<String?> createPendingImageMessage(Uint8List localBytes) async {
    _updateLocalBlockState();
    if (isBlocked.value) {
      debugPrint('🚫 Cannot send image - user is blocked');
      return null;
    }

    final messageId = _uuid.v4();
    final timestamp = DateTime.now();

    uploadProgressMap[messageId] = 0.0.obs;

    try {
      final cacheService = Get.find<ImageCacheService>();
      await cacheService.cacheImageById(messageId, localBytes);
    } catch (_) {}

    final message = MessageEntity(
      id: messageId,
      chatId: chatId,
      senderId: myDeviceId,
      receiverId: recipientDeviceId,
      content: 'MEDIA:pending',
      timestamp: timestamp,
      status: MessageStatus.sending,
      isMe: true,
      type: MessageType.image,
    );

    messages.add(ChatMessageModel.fromEntity(message));
    messages.refresh();
    _scrollToBottom();
    return messageId;
  }

  /// Step 2 of WhatsApp-style image send:
  /// Called after upload completes. Updates bubble content with real token
  /// and fires the socket event.
  Future<bool> finalizeImageMessage(String messageId, String token) async {
    uploadProgressMap.remove(messageId);

    final index = messages.indexWhere((msg) => msg.id == messageId);
    if (index == -1) return false;

    final timestamp = messages[index].timestamp;

    final message = MessageEntity(
      id: messageId,
      chatId: chatId,
      senderId: myDeviceId,
      receiverId: recipientDeviceId,
      content: 'MEDIA:$token',
      timestamp: timestamp,
      status: MessageStatus.sending,
      isMe: true,
      type: MessageType.image,
    );

    messages[index] = ChatMessageModel.fromEntity(message);
    messages.refresh();
    _storageService.saveMessage(message);
    _updateChatListAfterSending('📷 Photo', timestamp);

    try {
      final success = await _socketService.sendMediaMessage(
        messageId: messageId,
        recipientDeviceId: recipientDeviceId,
        mediaToken: token,
      );

      if (success) {
        final idx = messages.indexWhere((msg) => msg.id == messageId);
        if (idx != -1) {
          _updateMessageStatusIfNotRead(messageId, MessageStatus.sent);
          _messageTimeouts[messageId]?.cancel();
          _messageTimeouts.remove(messageId);
        }
      }
      _scheduleMessageTimeout(messageId);
      return true;
    } catch (e) {
      debugPrint('❌ Error finalizing image message: $e');
      _scheduleMessageTimeout(messageId);
      return true;
    }
  }

  /// Legacy entry point kept for backward compatibility.
  Future<bool> sendImageMessage(String token, Uint8List localBytes) async {
    final msgId = await createPendingImageMessage(localBytes);
    if (msgId == null) return false;
    return finalizeImageMessage(msgId, token);
  }

  /// Update contact name for this chat
  Future<void> updateContactName(String newName) async {
    try {
      final chat = _storageService.getChat(chatId);
      if (chat != null) {
        // Update name
        final updatedChat = chat.copyWith(userName: newName);
        await _storageService.saveChat(updatedChat);
        displayName.value = newName;

        // Notify ChatListController to refresh
        try {
          final chatListController = Get.find<ChatListController>();
          chatListController.loadChats();
        } catch (e) {
          debugPrint(
              '⚠️ ChatListController not found, changes will be visible on restart');
        }

        Get.snackbar(
          'Success',
          'Contact name updated',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      }
    } catch (e) {
      debugPrint('❌ Error updating contact name: $e');
      Get.snackbar(
        'Error',
        'Failed to update contact name',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    }
  }

  void showDeleteConfirmation() {
    Get.defaultDialog(
      title: 'Delete Chat',
      middleText:
          'Are you sure you want to delete this chat? This action cannot be undone.',
      textConfirm: 'Delete',
      textCancel: 'Cancel',
      confirmTextColor: Colors.white,
      buttonColor: AppColors.error,
      onConfirm: () async {
        try {
          await _storageService.deleteChat(chatId);

          // Notify ChatListController to refresh
          try {
            final chatListController = Get.find<ChatListController>();
            chatListController.loadChats();
          } catch (e) {
            debugPrint(
                '⚠️ ChatListController not found, changes will be visible on restart');
          }

          Get.back(); // Close dialog
          Get.back(); // Go back to chat list
          Get.snackbar(
            'Success',
            'Chat deleted successfully',
            snackPosition: SnackPosition.BOTTOM,
            duration: const Duration(seconds: 2),
          );
        } catch (e) {
          debugPrint('❌ Error deleting chat: $e');
          Get.snackbar(
            'Error',
            'Failed to delete chat',
            snackPosition: SnackPosition.BOTTOM,
            duration: const Duration(seconds: 2),
          );
        }
      },
    );
  }

  /// Clear all messages from this chat (keep chat object, remove only messages)
  Future<void> clearChatMessages() async {
    try {
      debugPrint('🧹 Clearing all messages for chat: $chatId');

      // Clear messages from UI
      messages.clear();

      // Clear messages from storage but keep chat
      await _storageService.clearChatMessages(chatId);

      // Update chat in storage to reset last message and unread count
      final chat = _storageService.getChat(chatId);
      if (chat != null) {
        final updatedChat = chat.copyWith(
          unreadCount: 0,
          clearLastMessage: true,
          clearLastMessageTime: true,
        );
        await _storageService.saveChat(updatedChat);
      }

      // Notify ChatListController to refresh
      try {
        final chatListController = Get.find<ChatListController>();
        chatListController.loadChats();
      } catch (e) {
        debugPrint(
            '⚠️ ChatListController not found, changes will be visible on restart');
      }

      debugPrint('✅ All messages cleared successfully for chat: $chatId');
    } catch (e) {
      debugPrint('❌ Error clearing chat messages: $e');
      rethrow; // Re-throw to handle in UI
    }
  }

  /// Scroll to bottom of chat
  void _scrollToBottom({bool requiredAnimation = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        // Add a small delay to ensure new message is fully rendered
        Future.delayed(const Duration(milliseconds: 100), () {
          if (scrollController.hasClients) {
            // Since ListView has reverse: true, scroll to 0.0 to show newest messages
            scrollController.animateTo(
              0.0,
              duration: requiredAnimation
                  ? const Duration(milliseconds: 300)
                  : Duration(milliseconds: 100),
              curve: Curves.easeOut,
            );
          }
        });
      }
    });
  }

  /// Public method to scroll to bottom (for floating button)
  void scrollToBottom() {
    _scrollToBottom(requiredAnimation: true);
  }

  /// Update display name for this chat
  void updateDisplayName(String newName) {
    displayName.value = newName;

    // Update the chat entity in storage
    final existingChat = _storageService.getChat(chatId);
    if (existingChat != null) {
      final updatedChat = ChatEntity(
        id: existingChat.id,
        userName: newName,
        lastMessage: existingChat.lastMessage,
        lastMessageTime: existingChat.lastMessageTime,
        unreadCount: existingChat.unreadCount,
      );
      _storageService.saveChat(updatedChat);

      // Update chat list
      try {
        final chatListController = Get.find<ChatListController>();
        chatListController.loadChats();
      } catch (e) {
        debugPrint('⚠️ Could not update chat list: $e');
      }
    }

    Get.snackbar(
      'Updated',
      'Contact name updated to $newName',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.green.shade100,
      colorText: Colors.green.shade800,
    );
  }

  /// Save test message (for debugging)
  Future<void> saveTestMessage(MessageEntity message) async {
    await _storageService.saveMessage(message);
  }

  /// Delete this chat
  void deleteChat() {
    // Delete from storage
    _storageService.deleteChat(recipientDeviceId);
    // Note: Individual message deletion not implemented in storage service
    // Messages will be cleaned up when chat is deleted

    // Update chat list
    try {
      final chatListController = Get.find<ChatListController>();
      chatListController.loadChats();
    } catch (e) {
      debugPrint('⚠️ Could not update chat list: $e');
    }

    Get.back(); // Go back to chat list
    Get.snackbar(
      'Deleted',
      'Chat deleted successfully',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.red.shade100,
      colorText: Colors.red.shade800,
    );
  }

  /// Dismiss the notification for a specific sender from the notification shade
  void _dismissNotificationForSender(String senderId) {
    if (senderId.isEmpty) return;
    try {
      Get.find<FCMService>().cancelNotificationForSender(senderId);
    } catch (e) {
      debugPrint('⚠️ Could not dismiss notification: $e');
    }
  }

  /// Flush all messages currently in 'sending' state through the socket.
  /// Called automatically every time the socket (re)connects.
  Future<void> _flushOutbox() async {
    if (!_socketService.isConnected.value) return;

    final pendingMessages = messages
        .where((m) => m.isMe && m.status == MessageStatus.sending)
        .toList();

    if (pendingMessages.isEmpty) return;

    debugPrint('📤 Flushing ${pendingMessages.length} pending message(s)...');

    for (final msg in pendingMessages) {
      if (_isDisposed) break;
      bool success;
      if (msg.type == MessageType.image) {
        // Image was already uploaded; just resend the tiny socket event
        final token = msg.content.startsWith('MEDIA:')
            ? msg.content.substring(6)
            : msg.content;
        success = await _socketService.sendMediaMessage(
          messageId: msg.id,
          recipientDeviceId: recipientDeviceId,
          mediaToken: token,
        );
      } else {
        success = await _socketService.sendMessage(
          messageId: msg.id,
          recipientDeviceId: recipientDeviceId,
          content: msg.content,
        );
      }

      if (success) {
        final index = messages.indexWhere((m) => m.id == msg.id);
        if (index != -1) {
          _updateMessageStatusIfNotRead(msg.id, MessageStatus.sent);
          _messageTimeouts[msg.id]?.cancel();
          _messageTimeouts.remove(msg.id);
          debugPrint('✅ Outbox flushed message: ${msg.id}');
        }
      }
    }
  }

  /// Reset a failed message back to 'sending' and attempt delivery.
  /// Called when the user taps the retry button on a failed message.
  Future<void> retrySendMessage(String messageId) async {
    if (messages.indexWhere((msg) => msg.id == messageId) == -1) return;

    // Await so messages[index].status is 'sending' before _flushOutbox reads it
    await _updateMessageStatusIfNotRead(messageId, MessageStatus.sending);

    // Cancel any lingering timeout so we get a fresh window
    _messageTimeouts[messageId]?.cancel();
    _messageTimeouts.remove(messageId);

    if (_socketService.isConnected.value) {
      _flushOutbox();
    } else {
      // Socket offline — schedule timeout and wait for reconnect
      _scheduleMessageTimeout(messageId);
    }
    debugPrint('🔁 Retry queued for message: $messageId');
  }

  /// Update message status only if it's not already read (optimization)
  Future<void> _updateMessageStatusIfNotRead(
      String messageId, MessageStatus newStatus) async {
    try {
      // Get current message to check its status
      final index = messages.indexWhere((msg) => msg.id == messageId);
      if (index == -1) {
        debugPrint('⚠️ Message not found for status update: $messageId');
        return;
      }

      final currentStatus = messages[index].status;

      // If message is already read, don't update to any other status
      if (currentStatus == MessageStatus.read) {
        debugPrint(
            '📊 Skipping status update for $messageId - already read (current: $currentStatus, requested: $newStatus)');
        return;
      }

      debugPrint(
          '📊 Updating message status: $messageId $currentStatus -> $newStatus');

      // Update in storage
      await _storageService.updateMessageStatus(messageId, newStatus);

      // Update in UI
      messages[index] = ChatMessageModel(
        id: messages[index].id,
        content: messages[index].content,
        isMe: messages[index].isMe,
        timestamp: messages[index].timestamp,
        status: newStatus,
        type: messages[index].type,
        mediaToken: messages[index].mediaToken,
        mediaExpiryTimestamp: messages[index].mediaExpiryTimestamp,
        replyTo: messages[index].replyTo,
      );
    } catch (e) {
      debugPrint('❌ Error updating message status: $e');
    }
  }

  /// Start a timer for a message in 'sending' state.
  /// If the message is still undelivered after [_messageTimeoutSeconds], mark it failed.
  void _scheduleMessageTimeout(String messageId) {
    _messageTimeouts[messageId]?.cancel();
    _messageTimeouts[messageId] = Timer(
      const Duration(seconds: _messageTimeoutSeconds),
      () {
        if (_isDisposed) return;
        _messageTimeouts.remove(messageId);
        final index = messages.indexWhere(
          (msg) => msg.id == messageId && msg.status == MessageStatus.sending,
        );
        if (index != -1) {
          debugPrint('⏰ Message timeout → failed: $messageId');
          _updateMessageStatusIfNotRead(messageId, MessageStatus.failed);
        }
      },
    );
  }

  /// Check if a status change would be a downgrade
  /// Prevents reverting from higher status (sent/delivered/read) to lower status (sending/failed)
  bool _isStatusDowngrade(MessageStatus current, MessageStatus newStatus) {
    const statusOrder = [
      MessageStatus.sending,
      MessageStatus.failed,
      MessageStatus.sent,
      MessageStatus.delivered,
      MessageStatus.read,
    ];
    final currentIndex = statusOrder.indexOf(current);
    final newIndex = statusOrder.indexOf(newStatus);
    return newIndex < currentIndex;
  }

  /// Called when chat screen becomes visible (foreground)
  void setScreenActive() {
    _isScreenActive = true;
    debugPrint(
        '📱 Chat screen active - messages will be marked as read when user opens chat');

    // Refresh messages to ensure any background messages are loaded
    refreshMessagesFromStorage();

    // Don't auto-mark as read here - only mark when user explicitly opens the chat
    // This prevents marking messages as read when app resumes from background
  }

  /// Decrement badge count by this chat's unread count
  Future<void> _decrementBadgeForChat() async {
    try {
      final chat = _storageService.getChat(chatId);
      if (chat != null && chat.unreadCount > 0) {
        final badgeService = Get.find<BadgeService>();
        await badgeService.decrementBadge(chat.unreadCount);
        // Immediately update app icon to prevent ghost count
        final newTotal = await badgeService.getTotalUnreadCount();
        await badgeService.updateAppIconBadge(newTotal);
        debugPrint(
            '🔔 Badge decremented by ${chat.unreadCount} for chat $chatId');
      }
    } catch (e) {
      debugPrint('⚠️ Error decrementing badge for chat: $e');
    }
  }

  /// Called when chat screen goes to background
  void setScreenInactive() {
    _isScreenActive = false;
    debugPrint('📱 Chat screen inactive - messages will stay delivered');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('📱 App lifecycle changed: $state');
    switch (state) {
      case AppLifecycleState.resumed:
        // App came to foreground - refresh messages but don't auto-mark as read
        // Messages should only be marked as read when user explicitly opens the chat
        setScreenActive();
        // Refresh messages to catch any saved by background FCM handler
        refreshMessagesFromStorage();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        // App went to background - stop marking messages as read
        setScreenInactive();
        break;
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        setScreenInactive();
        break;
    }
  }

  @override
  void onClose() {
    _isDisposed = true;
    _isScreenActive = false;

    // Unregister lifecycle observer
    WidgetsBinding.instance.removeObserver(this);

    for (final timer in _messageTimeouts.values) {
      timer.cancel();
    }
    _messageTimeouts.clear();

    // Clear active chat so notifications resume for this sender
    if (FCMService.activeChatId == recipientDeviceId) {
      FCMService.activeChatId = null;
    }

    // Restore the previous handler when controller is disposed
    if (_previousMessageHandler != null) {
      _socketService.onMessageReceived = _previousMessageHandler;
    }

    // Safely dispose controllers
    try {
      messageController.dispose();
    } catch (e) {
      debugPrint('⚠️ Error disposing messageController: $e');
    }

    try {
      scrollController.dispose();
    } catch (e) {
      debugPrint('⚠️ Error disposing scrollController: $e');
    }

    try {
      messageFocusNode.dispose();
    } catch (e) {
      debugPrint('⚠️ Error disposing messageFocusNode: $e');
    }

    super.onClose();
  }

  /// Toggle mute notifications for this chat
  void toggleMute() {
    isMuted.value = !isMuted.value;
    // TODO: Persist mute status to local storage
    Get.snackbar(
      isMuted.value ? 'Muted' : 'Unmuted',
      isMuted.value
          ? 'Notifications muted for this chat'
          : 'Notifications enabled for this chat',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: AppColors.primary.withOpacity(0.1),
      colorText: Colors.black,
      duration: const Duration(seconds: 2),
    );
  }

  /// Show block confirmation dialog
  void showBlockConfirmation() {
    Get.dialog(
      Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: Colors.white,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.block,
                  size: 36,
                  color: Colors.orange.shade700,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Block User',
                style: Get.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade800,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Blocked users will no longer be able to send you messages. You can unblock them anytime.',
                style: Get.textTheme.bodyMedium?.copyWith(
                  color: Colors.grey.shade600,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Get.back(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Get.back();
                        blockUser();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange.shade600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text('Block'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Show report dialog
  void showReportDialog() {
    Get.bottomSheet(
      Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Text(
              'Report User',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            const Text(
              'Please select a reason for reporting this user:',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            _buildReportOption('Spam', 'Sending unsolicited messages'),
            _buildReportOption('Inappropriate Content',
                'Sharing offensive or harmful content'),
            _buildReportOption(
                'Harassment', 'Bullying or threatening behavior'),
            _buildReportOption('Fake Account', 'Impersonating someone else'),
            _buildReportOption('Other', 'Other reason not listed above'),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Get.back(),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReportOption(String title, String subtitle) {
    return ListTile(
      title: Text(title),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      onTap: () {
        Get.back(); // Close bottom sheet
        _submitReport(title);
      },
      contentPadding: EdgeInsets.zero,
    );
  }

  void _submitReport(String reason) {
    // For now, just show a confirmation message
    // In a real app, this would send the report to a server
    Get.snackbar(
      'Report Submitted',
      'Thank you for reporting. We will review this user.',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.green.shade100,
      colorText: Colors.green.shade800,
      duration: const Duration(seconds: 3),
    );

    debugPrint('📝 User reported: $recipientDeviceId for reason: $reason');
  }

  /// Show clear chat dialog
  void showClearChatDialog() {
    Get.dialog(
      Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: Colors.white,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.clear_all,
                  size: 36,
                  color: Colors.orange.shade700,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Clear All Messages',
                style: Get.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade800,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'This will permanently delete all messages in this chat. This action cannot be undone.',
                style: Get.textTheme.bodyMedium?.copyWith(
                  color: Colors.grey.shade600,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Get.back(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Get.back();
                        clearChatMessages();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange.shade600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text('Clear'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Start replying to a message
  void startReply(ChatMessageModel message) {
    debugPrint('🔁 Starting reply to message: ${message.id}');
    debugPrint('🔁 Message type: ${message.type}');
    debugPrint('🔁 Is image: ${message.isImage}');
    debugPrint('🔁 Media token: ${message.mediaToken}');

    String? thumbnailData;
    if (message.isImage) {
      thumbnailData = _getCachedImageData(message.id);
      debugPrint(
          '🔁 Thumbnail data available: ${thumbnailData != null ? "Yes (${thumbnailData.length} chars)" : "No"}');
    }

    replyToMessage.value = ReplyToEntity(
      messageId: message.id,
      content: message.content,
      senderName: message.isMe ? 'You' : displayName.value,
      senderId: message.isMe ? myDeviceId : recipientDeviceId,
      type: message.type,
      mediaThumbnail: thumbnailData,
    );

    // Focus on input field
    messageFocusNode.requestFocus();

    debugPrint('🔁 Started replying to message: ${message.id}');
  }

  /// Cancel reply mode
  void cancelReply() {
    replyToMessage.value = null;
    debugPrint('🔁 Reply mode cancelled');
  }

  /// Get cached image data as base64 string for reply thumbnails
  String? _getCachedImageData(String messageId) {
    try {
      final cacheService = Get.find<ImageCacheService>();
      // Try to get cached image by message ID first
      final cachedData = cacheService.getCachedImage(messageId);
      if (cachedData != null) {
        return base64Encode(cachedData);
      }

      // If not found by message ID, try to find the message and get its media token
      final message = messages.firstWhereOrNull((msg) => msg.id == messageId);
      if (message != null && message.mediaToken != null) {
        final mediaData = cacheService.getCachedImage(message.mediaToken!);
        if (mediaData != null) {
          return base64Encode(mediaData);
        }
      }
    } catch (e) {
      debugPrint('⚠️ Could not get cached image data for reply: $e');
    }
    return null;
  }

  /// Check if currently in reply mode
  bool get isReplying => replyToMessage.value != null;

  /// Scroll to a specific message by ID
  void scrollToMessage(String messageId) {
    final index = messages.indexWhere((msg) => msg.id == messageId);
    if (index != -1 && scrollController.hasClients) {
      try {
        // Since ListView is reversed, we need to calculate the correct position
        // In a reversed ListView, index 0 is at the bottom (newest)
        // The scroll position needs to account for this reversal
        final reversedIndex = messages.length - 1 - index;

        // Calculate approximate position based on reversed index
        final itemHeight = 80.0;
        final targetPosition = reversedIndex * itemHeight;

        // Clamp to valid scroll range
        final maxScroll = scrollController.position.maxScrollExtent;
        final clampedPosition = targetPosition.clamp(0.0, maxScroll);

        scrollController.animateTo(
          clampedPosition,
          duration: Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );

        debugPrint(
            '📍 Scrolled to message: $messageId at index $index (reversed: $reversedIndex)');
      } catch (e) {
        debugPrint('❌ Error scrolling to message: $e');
      }
    } else {
      debugPrint('⚠️ Message not found: $messageId');
    }
  }
}
