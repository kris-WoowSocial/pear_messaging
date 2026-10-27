import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'local_storage_service.dart';
import 'caller_name_resolver.dart';
import '../../routes/app_routes.dart';
import '../../storage/models/connection_request_entity.dart';
import '../../storage/models/message_entity.dart';
import '../../features/chat_list/chat_list_controller.dart';

class DeepLinkService extends GetxService {
  final LocalStorageService _storageService = Get.find();
  static const MethodChannel _channel = MethodChannel(
    'com.pear.messaging/deeplink',
  );

  /// Initialize deep link service
  Future<DeepLinkService> init() async {
    debugPrint('🔗 Initializing Deep Link Service...');

    try {
      // Set up method channel handler for deep links
      _channel.setMethodCallHandler(_handleMethodCall);

      debugPrint('✅ Deep Link Service initialized');
      return this;
    } catch (e) {
      debugPrint('❌ Error initializing Deep Link Service: $e');
      return this;
    }
  }

  /// Handle method calls from native Android
  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onDeepLink') {
      final arguments = call.arguments as Map<dynamic, dynamic>;
      final url = arguments['url'] as String?;

      if (url != null) {
        debugPrint('🔗 Deep link received from native: $url');
        final uri = Uri.parse(url);
        _handleDeepLink(uri);
      }
    }
  }

  /// Handle incoming deep link
  void _handleDeepLink(Uri uri) {
    debugPrint('🔗 Handling deep link: $uri');

    if (uri.scheme == 'pearmessaging' && uri.host == 'chat') {
      final deviceId = uri.queryParameters['device_id'];

      if (deviceId != null && deviceId.isNotEmpty) {
        _openChat(deviceId, userName: uri.queryParameters['user_name']);
      } else {
        debugPrint('⚠️ No device_id found in deep link');
      }
    }
  }

  /// Open chat with device ID
  void _openChat(String deviceId, {String? userName}) async {
    debugPrint('📱 Opening chat with device: $deviceId');

    // Check if chat exists
    final existingChat = _storageService.getChat(deviceId);

    if (existingChat != null) {
      // Chat exists, navigate to it
      debugPrint('📱 Opening existing chat with: ${existingChat.userName}');
      Get.toNamed(
        AppRoutes.chat,
        arguments: {
          'chatId': deviceId,
          'userName': existingChat.userName,
          'recipientDeviceId': deviceId,
        },
      );
    } else {
      // No chat exists - create a connection request for the person clicking the link
      // Resolve the real name (saved contact -> server profile) rather than
      // the generated @user_xxxxx handle.
      final friendlyName = await CallerNameResolver.resolve(
        deviceId,
        payloadName: userName,
      );
      debugPrint(
        '📱 No existing chat found, creating connection request for: $friendlyName',
      );

      // Create a connection request entity for the shared link scenario
      final connectionRequest = ConnectionRequestEntity(
        id: 'req_${DateTime.now().millisecondsSinceEpoch}',
        senderDeviceId: deviceId, // The person who shared the link
        receiverDeviceId: _storageService.deviceId!,
        timestamp: DateTime.now(),
        status: ConnectionRequestStatus.pending,
        messageContent: null,
        messageType: MessageType.text,
      );

      // Save the connection request
      await _storageService.saveConnectionRequest(connectionRequest);

      // Add to chat list controller
      try {
        final chatListController = Get.find<ChatListController>();
        chatListController.pendingConnectionRequests.add(connectionRequest);
        chatListController.loadChats();

        debugPrint('✅ Connection request added to chat list');

        // Navigate to chat list to show the connection request
        Get.offAllNamed(AppRoutes.chatList);

        Get.snackbar(
          'Connection Request',
          'Check your chat list for the new connection request',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.blue.shade100,
          colorText: Colors.blue.shade800,
        );
      } catch (e) {
        debugPrint('⚠️ Could not update chat list: $e');
        // Fallback: navigate to chat list anyway
        Get.offAllNamed(AppRoutes.chatList);
      }
    }
  }
}
