import 'package:get/get.dart';
import 'package:flutter/material.dart';
import 'local_storage_service.dart';
import 'socket_service.dart';
import '../utils/string_utils.dart';
import '../../storage/models/connection_request_entity.dart';
import '../../storage/models/chat_entity.dart';
import '../../storage/models/message_entity.dart';
import '../../features/chat_list/chat_list_controller.dart';
import '../constants/app_colors.dart';

// Use foundation debugPrint to avoid conflicts
import 'package:flutter/foundation.dart' as foundation;

class ConnectionRequestService extends GetxService {
  final LocalStorageService _storageService = Get.find();
  final SocketService _socketService = Get.find();

  final RxList<ConnectionRequestEntity> pendingRequests =
      <ConnectionRequestEntity>[].obs;

  @override
  void onInit() {
    super.onInit();
    _loadPendingRequests();
    _setupSocketListeners();
    _setupAppLifecycleListener();

    // Enhanced cleanup: Run cleanup on service initialization
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 500), () {
        cleanupDuplicateConnections();
      });
    });
  }

  /// Setup app lifecycle listener for iOS-specific handling
  void _setupAppLifecycleListener() {
    // Clean up duplicate connection requests on app resume (iOS specific issue)
    WidgetsBinding.instance.addObserver(_AppLifecycleObserver(this));
  }

  /// Clean up duplicate connection requests and chats
  Future<void> cleanupDuplicateConnections() async {
    try {
      foundation.debugPrint(
        '🧹 Cleaning up duplicate connections on app resume/startup...',
      );

      // Get all chats and connection requests
      final allChats = _storageService.getAllChats();
      final allRequests = pendingRequests.toList();

      // Find and remove duplicate chats for the same users
      final Map<String, List<ChatEntity>> chatsByDeviceId = {};
      for (final chat in allChats) {
        chatsByDeviceId.putIfAbsent(chat.id, () => []).add(chat);
      }

      // Remove duplicate chats, keeping the most recent one
      for (final entry in chatsByDeviceId.entries) {
        if (entry.value.length > 1) {
          foundation.debugPrint(
            '🔍 Found duplicate chats for ${entry.key}: ${entry.value.length}',
          );

          // Sort by last message time, keep the most recent
          entry.value.sort((a, b) {
            final aTime = a.lastMessageTime ?? DateTime.now();
            final bTime = b.lastMessageTime ?? DateTime.now();
            return bTime.compareTo(aTime);
          });

          // Remove all but the most recent
          for (int i = 1; i < entry.value.length; i++) {
            final duplicateChat = entry.value[i];
            await _storageService.deleteChat(duplicateChat.id);
            foundation.debugPrint(
              '🗑️ Removed duplicate chat: ${duplicateChat.id}',
            );
          }
        }
      }

      // Enhanced cleanup: Remove connection requests for users we already have chats with
      for (final request in allRequests) {
        final existingChat = _storageService.getChat(request.senderDeviceId);
        if (existingChat != null) {
          _removeConnectionRequest(request.id);
          foundation.debugPrint(
            '🗑️ Removed connection request for existing chat: ${request.senderDeviceId}',
          );
        }
      }

      // Enhanced cleanup: Remove duplicate connection requests (same sender/receiver pair)
      final Map<String, List<ConnectionRequestEntity>> requestsByPair = {};
      for (final request in allRequests) {
        // Create a key that represents the unique pair of devices
        final pairKey = [request.senderDeviceId, request.receiverDeviceId]
          ..sort();
        final key = '${pairKey[0]}-${pairKey[1]}';
        requestsByPair.putIfAbsent(key, () => []).add(request);
      }

      for (final entry in requestsByPair.entries) {
        if (entry.value.length > 1) {
          foundation.debugPrint(
            '🔍 Found duplicate connection requests for pair ${entry.key}: ${entry.value.length}',
          );

          // Sort by timestamp, keep the most recent
          entry.value.sort((a, b) => b.timestamp.compareTo(a.timestamp));

          // Remove all but the most recent
          for (int i = 1; i < entry.value.length; i++) {
            final duplicateRequest = entry.value[i];
            _removeConnectionRequest(duplicateRequest.id);
            foundation.debugPrint(
              '🗑️ Removed duplicate connection request: ${duplicateRequest.id}',
            );
          }
        }
      }

      // Refresh chat list
      try {
        final chatListController = Get.find<ChatListController>();
        chatListController.loadChats();
        foundation.debugPrint('✅ Chat list refreshed after cleanup');
      } catch (e) {
        foundation.debugPrint('⚠️ Could not refresh chat list: $e');
      }

      foundation.debugPrint('✅ Duplicate connection cleanup completed');
    } catch (e) {
      foundation.debugPrint('⚠️ Error during connection cleanup: $e');
    }
  }

  /// Load pending connection requests from storage
  void _loadPendingRequests() {
    final requests = _storageService.getPendingConnectionRequests();
    pendingRequests.value = requests;
  }

  /// Setup socket listeners for connection requests
  void _setupSocketListeners() {
    _socketService.onConnectionRequest = _handleIncomingConnectionRequest;
    _socketService.onConnectionRequestResponse =
        _handleConnectionRequestResponse;
  }

  /// Send a connection request to another device
  Future<void> sendConnectionRequest(
    String targetDeviceId, {
    String? messageContent,
  }) async {
    final myDeviceId = _storageService.deviceId;
    debugPrint('🚀 SENDER LOG: sendConnectionRequest called');
    debugPrint('  - myDeviceId (sender): $myDeviceId');
    debugPrint('  - targetDeviceId (recipient): $targetDeviceId');
    debugPrint('  - messageContent: $messageContent');

    if (myDeviceId == null) {
      debugPrint('❌ Cannot send connection request: Device ID is null');
      return;
    }

    // Check if we already have a chat with this user
    final existingChat = _storageService.getChat(targetDeviceId);
    if (existingChat != null) {
      debugPrint('📱 SENDER LOG: Chat already exists, navigating directly');
      _navigateToExistingChat(existingChat);
      return;
    }

    // Check if there's already a pending connection request to avoid duplicates
    final existingRequest = pendingRequests.firstWhereOrNull(
      (request) =>
          request.senderDeviceId == myDeviceId &&
          request.receiverDeviceId == targetDeviceId,
    );
    if (existingRequest != null) {
      debugPrint('🔄 SENDER LOG: Connection request already exists, skipping');
      return;
    }

    // Enhanced validation: Check if there's an incoming request from this user
    final incomingRequest = pendingRequests.firstWhereOrNull(
      (request) =>
          request.senderDeviceId == targetDeviceId &&
          request.receiverDeviceId == myDeviceId,
    );
    if (incomingRequest != null) {
      debugPrint(
        '🔄 SENDER LOG: Incoming request already exists from this user, skipping outgoing request',
      );
      return;
    }

    // Send connection request via socket with message content
    final success = await _socketService.sendConnectionRequest(
      targetDeviceId,
      messageContent: messageContent,
    );

    if (success) {
      debugPrint(
        '📤 SENDER LOG: Connection request sent successfully to: $targetDeviceId',
      );

      // Don't create a chat immediately - wait for acceptance
      // This prevents duplicate chats on iOS
      try {
        final chatListController = Get.find<ChatListController>();
        final friendlyName = _storageService.getDisplayName(targetDeviceId);

        debugPrint('🏗️ SENDER LOG: Creating PENDING chat entry for sender');
        debugPrint('  - targetDeviceId: $targetDeviceId');
        debugPrint('  - friendlyName: $friendlyName');

        // Create a PENDING chat entity that will be updated on acceptance
        final pendingChat = ChatEntity(
          id: targetDeviceId,
          userName: friendlyName,
          lastMessage: 'Invitation sent - waiting for response...',
          lastMessageTime: DateTime.now(),
          unreadCount: 0,
        );

        // Save to storage with a special marker to indicate it's pending
        await _storageService.saveChat(pendingChat);
        debugPrint('💾 SENDER LOG: Pending chat saved to storage');

        // Add to chat list UI
        chatListController.loadChats(); // Refresh the chat list
        debugPrint('🔄 SENDER LOG: Chat list refreshed');

        debugPrint(
          '✅ SENDER LOG: Pending chat created - will be updated on acceptance',
        );
      } catch (e) {
        debugPrint('⚠️ Could not update sender\'s chat list: $e');
      }

      // // Show pending status
      // Get.snackbar(
      //   'Connection Request Sent',
      //   'Waiting for response...',
      //   snackPosition: SnackPosition.BOTTOM,
      //   backgroundColor: Colors.blue.shade100,
      //   colorText: Colors.blue.shade800,
      //   duration: const Duration(seconds: 3),
      // );
    } else {
      Get.snackbar(
        'Failed to Send',
        'Could not send connection request. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
    }
  }

  /// Handle incoming connection request
  void _handleIncomingConnectionRequest(Map<String, dynamic> data) async {
    debugPrint('� RECIPIENT LOG: _handleIncomingConnectionRequest called');
    debugPrint('�� RECIPIENT LOG: Incoming connection request data: $data');

    final senderDeviceId = data['senderDeviceId'] as String;
    final requestId = data['requestId'] as String;
    final timestamp = DateTime.fromMillisecondsSinceEpoch(
      data['timestamp'] as int,
    );

    debugPrint('📋 RECIPIENT LOG: Parsed connection request data:');
    debugPrint('  - senderDeviceId: $senderDeviceId');
    debugPrint('  - requestId: $requestId');
    debugPrint('  - timestamp: $timestamp');

    // Extract message content if present
    String? messageContent;
    final encryptedPayload = data['encryptedPayload'] as String?;
    if (encryptedPayload != null && encryptedPayload.isNotEmpty) {
      messageContent = SocketService.decryptMessage(encryptedPayload);
      debugPrint('🔍 DEBUG: Decrypted message content: $messageContent');
    }

    // Check if we already have a chat with this user
    final existingChat = _storageService.getChat(senderDeviceId);
    if (existingChat != null) {
      // Auto-accept if chat already exists
      debugPrint(
        '📱 RECIPIENT LOG: Chat already exists with $senderDeviceId, auto-accepting',
      );
      acceptConnectionRequest(requestId, senderDeviceId);
      return;
    }

    // Enhanced validation: Check if we already have a pending request from this user
    final existingRequest = pendingRequests.firstWhereOrNull(
      (request) =>
          request.senderDeviceId == senderDeviceId &&
          request.receiverDeviceId == _storageService.deviceId,
    );
    if (existingRequest != null) {
      debugPrint(
        '🔄 RECIPIENT LOG: Connection request already exists from $senderDeviceId, skipping duplicate',
      );
      return;
    }

    // Enhanced validation: Check if we already sent a request to this user
    final outgoingRequest = pendingRequests.firstWhereOrNull(
      (request) =>
          request.senderDeviceId == _storageService.deviceId &&
          request.receiverDeviceId == senderDeviceId,
    );
    if (outgoingRequest != null) {
      debugPrint(
        '🔄 RECIPIENT LOG: Already sent request to $senderDeviceId, auto-accepting incoming request',
      );
      // Accept the incoming request and remove our outgoing one
      _removeConnectionRequest(outgoingRequest.id);
      acceptConnectionRequest(requestId, senderDeviceId);
      return;
    }

    // Use @user_ format - no name fetching for privacy
    final senderName = StringUtils.generateFriendlyName(senderDeviceId);
    debugPrint(
      '🔍 DEBUG: Using @user_ format for connection request: $senderDeviceId -> $senderName',
    );

    // Create connection request entity with message content and sender name
    final request = ConnectionRequestEntity(
      id: requestId,
      senderDeviceId: senderDeviceId,
      receiverDeviceId: _storageService.deviceId!,
      timestamp: timestamp,
      status: ConnectionRequestStatus.pending,
      messageContent: messageContent,
      messageType: MessageType.text,
      senderName: senderName,
    );

    debugPrint('🔍 DEBUG: Created connection request: ${request.toJson()}');

    // Save to storage
    _storageService.saveConnectionRequest(request);

    // Add to pending list
    pendingRequests.add(request);

    // Update chat list controller
    try {
      final chatListController = Get.find<ChatListController>();
      chatListController.pendingConnectionRequests.add(request);
      debugPrint('✅ DEBUG: Added to chat list pending requests');
    } catch (e) {
      debugPrint('⚠️ DEBUG: Could not update chat list: $e');
    }

    // Don't show popup dialog - user will see accept/reject when they open the chat
    // showConnectionRequestDialog(request);
    debugPrint('✅ DEBUG: Connection request ready - no popup shown');
  }

  /// Show connection request dialog
  void showConnectionRequestDialog(ConnectionRequestEntity request) {
    final senderName = StringUtils.generateFriendlyName(request.senderDeviceId);

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
              // Icon
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.person_add,
                  size: 30,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 16),

              // Title
              const Text(
                'Connection Request',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 12),

              // Message
              Text(
                '$senderName wants to start a conversation with you',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Colors.black54),
              ),
              const SizedBox(height: 24),

              // Buttons
              Row(
                children: [
                  // Block button
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Get.back();
                        blockConnectionRequest(
                          request.id,
                          request.senderDeviceId,
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        'Block',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Accept button
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Get.back();
                        acceptConnectionRequest(
                          request.id,
                          request.senderDeviceId,
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        elevation: 2,
                      ),
                      child: const Text(
                        'Accept',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      barrierDismissible: false,
    );
  }

  /// Accept connection request
  Future<void> acceptConnectionRequest(
    String requestId,
    String senderDeviceId,
  ) async {
    // Send acceptance response via socket with senderDeviceId so server knows who to notify
    await _socketService.respondToConnectionRequest(
      requestId,
      true,
      senderDeviceId: senderDeviceId,
    );

    // Create chat entity for the accepted connection
    final senderName = _storageService.getDisplayName(senderDeviceId);
    final myDeviceId = _storageService.deviceId!;

    // Create default acceptance message
    final defaultMessage =
        "Hey, I've accepted the request—let's get this chat started.";

    // Create and save the default message
    final messageId = 'msg_${DateTime.now().millisecondsSinceEpoch}';
    final messageEntity = MessageEntity(
      id: messageId,
      chatId: senderDeviceId,
      senderId: myDeviceId,
      receiverId: senderDeviceId,
      content: defaultMessage,
      timestamp: DateTime.now(),
      status: MessageStatus.sent,
      isMe: true,
      type: MessageType.text,
    );

    // Save message to storage
    await _storageService.saveMessage(messageEntity);

    // Send the default message to the recipient via socket
    await _socketService.sendMessage(
      messageId: messageId,
      recipientDeviceId: senderDeviceId,
      content: defaultMessage,
    );
    debugPrint(
      '✅ Default acceptance message sent to recipient: $senderDeviceId',
    );

    final newChat = ChatEntity(
      id: senderDeviceId,
      userName: senderName,
      lastMessage: defaultMessage,
      lastMessageTime: DateTime.now(),
      unreadCount: 0,
    );

    await _storageService.saveChat(newChat);

    // Remove from pending requests
    _removeConnectionRequest(requestId);

    // Remove from chat list UI
    try {
      final chatListController = Get.find<ChatListController>();
      chatListController.removeConnectionRequest(requestId);
      chatListController.loadChats(); // Refresh to show new chat
    } catch (e) {
      debugPrint('⚠️ Could not update chat list: $e');
    }

    // Navigate to the new chat
    Get.toNamed(
      '/chat',
      arguments: {
        'chatId': senderDeviceId,
        'userName': senderName,
        'recipientDeviceId': senderDeviceId,
      },
    );

    Get.snackbar(
      'Connection Accepted',
      'You can now chat with $senderName',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.green.shade100,
      colorText: Colors.green.shade800,
    );
  }

  /// Block connection request
  Future<void> blockConnectionRequest(
    String requestId,
    String senderDeviceId,
  ) async {
    debugPrint(
      '🚫 Blocking connection request: $requestId from: $senderDeviceId',
    );

    // Enhanced validation: Check if there's an existing chat before blocking
    final existingChat = _storageService.getChat(senderDeviceId);
    if (existingChat != null) {
      debugPrint(
        '⚠️ WARNING: Chat exists with $senderDeviceId - blocking request will NOT delete chat',
      );
      debugPrint(
        '🛡️ PROTECTION: Preserving existing chat from accidental deletion',
      );

      // Only remove the connection request, NOT the chat
      _removeConnectionRequest(requestId);

      // Remove from chat list UI
      try {
        final chatListController = Get.find<ChatListController>();
        chatListController.removeConnectionRequest(requestId);
      } catch (e) {
        debugPrint('⚠️ Could not update chat list: $e');
      }

      final senderName = existingChat.userName; // Use chat name for consistency
      Get.snackbar(
        'Connection Request Blocked',
        'Request blocked but chat with $senderName preserved',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.orange.shade100,
        colorText: Colors.orange.shade800,
      );
      return;
    }

    // Send rejection response with senderDeviceId so server knows who to notify
    await _socketService.respondToConnectionRequest(
      requestId,
      false,
      senderDeviceId: senderDeviceId,
    );

    // Add to blocked users
    // Note: This would integrate with your existing block service

    // Remove from pending requests
    _removeConnectionRequest(requestId);

    // Remove from chat list UI
    try {
      final chatListController = Get.find<ChatListController>();
      chatListController.removeConnectionRequest(requestId);
    } catch (e) {
      debugPrint('⚠️ Could not update chat list: $e');
    }

    final senderName = _storageService.getDisplayName(senderDeviceId);
    Get.snackbar(
      'Connection Blocked',
      '$senderName has been blocked',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.red.shade100,
      colorText: Colors.red.shade800,
    );
  }

  /// Handle connection request response
  void _handleConnectionRequestResponse(Map<String, dynamic> data) {
    debugPrint('📨 SENDER LOG: _handleConnectionRequestResponse called');
    debugPrint('🔍 SENDER LOG: Response data: $data');

    final accepted = data['accepted'] as bool;
    final targetDeviceId = data['targetDeviceId'] as String;

    debugPrint('📋 SENDER LOG: Parsed response data:');
    debugPrint('  - accepted: $accepted');
    debugPrint('  - targetDeviceId: $targetDeviceId');

    if (accepted) {
      debugPrint('✅ SENDER LOG: Connection was accepted by recipient');

      // Connection accepted - UPDATE existing chat instead of creating duplicate
      final targetName = _storageService.getDisplayName(targetDeviceId);
      debugPrint('👤 SENDER LOG: Target name: $targetName');

      // Check if chat already exists and update it
      final existingChat = _storageService.getChat(targetDeviceId);
      ChatEntity updatedChat;

      // Default acceptance message so the sender sees it as the first message too
      const defaultAcceptMessage =
          "Hey, I've accepted the request—let's get this chat started.";

      if (existingChat != null) {
        // Preserve the real message if the chat already has one; otherwise show the
        // default acceptance text until the socket message arrives and overwrites it.
        final lastMessage =
            (existingChat.lastMessage != null &&
                existingChat.lastMessage!.isNotEmpty &&
                existingChat.lastMessage !=
                    'Connection accepted - start chatting!')
            ? existingChat.lastMessage
            : defaultAcceptMessage;
        updatedChat = existingChat.copyWith(
          lastMessage: lastMessage,
          lastMessageTime: DateTime.now(),
        );
        debugPrint('🔄 SENDER LOG: Updated existing chat to accepted status');
      } else {
        // Create new chat only if it doesn't exist (fallback)
        updatedChat = ChatEntity(
          id: targetDeviceId,
          userName: targetName,
          lastMessage: defaultAcceptMessage,
          lastMessageTime: DateTime.now(),
          unreadCount: 0,
        );
        debugPrint('🆕 SENDER LOG: Created new chat (fallback)');
      }

      _storageService.saveChat(updatedChat);
      debugPrint('💾 SENDER LOG: Chat saved/updated to storage');

      // Update chat list to show the accepted chat
      try {
        final chatListController = Get.find<ChatListController>();
        chatListController.loadChats(); // Refresh to show updated chat
        debugPrint(
          '✅ SENDER LOG: Chat list refreshed - sender should see accepted chat now',
        );
      } catch (e) {
        debugPrint('⚠️ SENDER LOG: Could not update sender chat list: $e');
      }

      // Don't auto-navigate - let user choose when to open chat
      // Just show success message
      Get.snackbar(
        'Connection Accepted',
        '$targetName accepted your request! You can now chat.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.green.shade100,
        colorText: Colors.green.shade800,
      );
    } else {
      debugPrint('❌ SENDER LOG: Connection was rejected by recipient');

      // Connection rejected - remove the pending chat
      try {
        final existingChat = _storageService.getChat(targetDeviceId);
        if (existingChat != null &&
            existingChat.lastMessage?.contains('Invitation sent') == true) {
          // Remove the pending chat entry
          _storageService.deleteChat(targetDeviceId);
          debugPrint('🗑️ SENDER LOG: Removed pending chat after rejection');

          // Update chat list
          final chatListController = Get.find<ChatListController>();
          chatListController.loadChats();
        }
      } catch (e) {
        debugPrint('⚠️ SENDER LOG: Could not remove pending chat: $e');
      }

      final targetName = _storageService.getDisplayName(targetDeviceId);
      Get.snackbar(
        'Connection Declined',
        '$targetName declined your request',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.orange.shade100,
        colorText: Colors.orange.shade800,
      );
    }
  }

  /// Remove connection request from pending list and storage
  void _removeConnectionRequest(String requestId) {
    pendingRequests.removeWhere((request) => request.id == requestId);
    _storageService.removeConnectionRequest(requestId);
  }

  /// Navigate to existing chat
  void _navigateToExistingChat(ChatEntity chat) {
    Get.toNamed(
      '/chat',
      arguments: {
        'chatId': chat.id,
        'userName': chat.userName,
        'recipientDeviceId': chat.id,
      },
    );
  }
}

/// App lifecycle observer for iOS-specific cleanup
class _AppLifecycleObserver extends WidgetsBindingObserver {
  final ConnectionRequestService _service;

  _AppLifecycleObserver(this._service);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Run cleanup asynchronously to avoid blocking UI
      _service.cleanupDuplicateConnections();
    }
  }
}
