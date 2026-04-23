import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_branch_sdk/flutter_branch_sdk.dart';
import 'package:get/get.dart';
import 'package:pear_messaging/routes/app_routes.dart';
import 'package:share_plus/share_plus.dart';
import 'package:http/http.dart' as http;
import '../../storage/models/connection_request_entity.dart';
import '../../storage/models/message_entity.dart';
import '../../features/chat_list/chat_list_controller.dart';
import 'local_storage_service.dart';
import 'invitation_storage_service.dart';

class BranchService extends GetxService {
  final LocalStorageService _storageService = Get.find();

  // Global flag to prevent duplicate navigation across services
  static bool isGloballyNavigating = false;
  static String? lastGlobalDeviceId;
  static DateTime? lastGlobalNavigationTime;

  // Flag to prevent duplicate navigation within this service
  static bool _isNavigating = false;
  static String? _lastNavigatedDeviceId;
  static DateTime? _lastNavigationTime;

  // Flag to prevent duplicate listener calls
  static String? _lastProcessedDeviceId;
  static DateTime? _lastProcessedTime;

  /// Initialize Branch SDK
  Future<BranchService> init() async {
    debugPrint('🌿 Initializing Branch SDK...');

    try {
      // Initialize Branch SDK first
      await FlutterBranchSdk.init();
      debugPrint('✅ Branch SDK init() called');

      // Get initial session data first (for cold start deep links and deferred deep links)
      try {
        final initialData = await FlutterBranchSdk.getLatestReferringParams();
        if (initialData.isNotEmpty) {
          final isFirstSession =
              initialData['+is_first_session'] as bool? ?? false;
          final clickedBranchLink =
              initialData['+clicked_branch_link'] as bool? ?? false;

          debugPrint('🔗 Initial Branch data (cold start): $initialData');
          debugPrint(
            '🔗 First session: $isFirstSession, Clicked Branch link: $clickedBranchLink',
          );

          // This handles both cold start and deferred deep linking (fresh app install)
          if (isFirstSession && clickedBranchLink) {
            debugPrint(
              '🎉 Deferred deep link detected - fresh app install with preserved link data',
            );
          }

          await _processDeepLinkData(initialData, isColdStart: true);
        } else {
          debugPrint('🔗 No initial Branch data found');
        }
      } catch (e) {
        debugPrint('⚠️ Error getting initial Branch data: $e');
      }

      // Then listen for deep links
      FlutterBranchSdk.initSession().listen((data) async {
        debugPrint('🔗 Branch deep link data: $data');

        // Check if this is a first session from a deep link
        final isFirstSession = data['+is_first_session'] as bool? ?? false;
        final clickedBranchLink =
            data['+clicked_branch_link'] as bool? ?? false;

        debugPrint(
          '🔗 Branch session info: isFirstSession=$isFirstSession, clickedBranchLink=$clickedBranchLink',
        );

        await _processDeepLinkData(data, isColdStart: false);
      });

      // Check for pending invitations after a short delay (only if app is already running)
      Future.delayed(const Duration(seconds: 2), () {
        _checkPendingInvitations();
      });

      // Additional check for first session - check more frequently for the first 10 seconds
      _checkFirstSessionInvitations();

      debugPrint('✅ Branch SDK initialized');
      return this;
    } catch (e) {
      debugPrint('❌ Error initializing Branch SDK: $e');
      rethrow;
    }
  }

  /// Check for pending invitations and process them
  void _checkPendingInvitations() {
    try {
      final invitationService = Get.find<InvitationStorageService>();
      final pendingInvitation = invitationService.getPendingInvitation();

      if (pendingInvitation != null) {
        debugPrint(
          '📋 Processing pending invitation: ${pendingInvitation['deviceId']}',
        );

        // Check if we're already in a chat screen to avoid double navigation
        final currentRoute = Get.currentRoute;
        if (currentRoute == '/chat') {
          debugPrint(
            '📋 Already in chat screen, skipping pending invitation navigation',
          );
          invitationService.clearPendingInvitation();
          return;
        }

        // For fresh install or first launch, let splash controller handle this
        // Don't process here to avoid duplicate connection requests
        if (currentRoute == '/splash' || currentRoute == '/onboarding') {
          debugPrint(
            '📋 App still initializing, letting splash controller handle invitation',
          );
          return; // Don't clear - let splash controller process it
        }

        _handleDeepLink(pendingInvitation['deviceId']!);

        // Clear the pending invitation after processing
        invitationService.clearPendingInvitation();
      } else {
        debugPrint('📋 No pending invitations found');
      }
    } catch (e) {
      debugPrint('⚠️ Error checking pending invitations: $e');
    }
  }

  /// Check for first session invitations more frequently
  void _checkFirstSessionInvitations() {
    int attempts = 0;
    const maxAttempts = 5; // Check 5 times over 10 seconds

    Timer.periodic(const Duration(seconds: 2), (timer) {
      attempts++;
      debugPrint('🔍 First session invitation check #$attempts');

      try {
        if (!Get.isRegistered<InvitationStorageService>()) {
          debugPrint('⚠️ InvitationStorageService not registered yet');
          if (attempts >= maxAttempts) {
            timer.cancel();
          }
          return;
        }

        // Skip processing if app is still initializing - let splash controller handle it
        final currentRoute = Get.currentRoute;
        if (currentRoute == '/splash' || currentRoute == '/onboarding') {
          debugPrint('🔍 App still initializing, skipping first session check');
          if (attempts >= maxAttempts) {
            timer.cancel();
          }
          return;
        }

        final invitationService = Get.find<InvitationStorageService>();
        final pendingInvitation = invitationService.getPendingInvitation();

        if (pendingInvitation != null) {
          debugPrint(
            '📋 Found pending invitation during first session check: ${pendingInvitation['deviceId']}',
          );

          // Check if we're already in a chat screen
          final currentRoute = Get.currentRoute;
          if (currentRoute == '/chat') {
            debugPrint(
              '📋 Already in chat screen, clearing pending invitation',
            );
            invitationService.clearPendingInvitation();
            timer.cancel();
            return;
          }

          // Navigate to chat
          _handleDeepLink(pendingInvitation['deviceId']!);
          invitationService.clearPendingInvitation();
          timer.cancel();
          return;
        }

        if (attempts >= maxAttempts) {
          debugPrint(
            '📋 No pending invitations found after $maxAttempts checks',
          );
          timer.cancel();
        }
      } catch (e) {
        debugPrint('⚠️ Error in first session invitation check: $e');
        if (attempts >= maxAttempts) {
          timer.cancel();
        }
      }
    });
  }

  /// Generate share link with device ID using improved Branch.io approach
  Future<String> generateShareLink() async {
    try {
      final deviceId = _storageService.deviceId;
      if (deviceId == null) {
        throw Exception('Device ID not available');
      }

      final friendlyName = _storageService.getDisplayName(deviceId);
      debugPrint('📎 Generating Branch.io link for device: $deviceId');

      // Create Branch Content Metadata with rich data
      final contentMetadata = BranchContentMetaData()
        ..addCustomMetadata('page', 'chat')
        ..addCustomMetadata('device_id', deviceId)
        ..addCustomMetadata('user_name', friendlyName)
        ..addCustomMetadata('sender_device_id', deviceId)
        ..addCustomMetadata('chat_id', deviceId);

      // Create Branch Universal Object with proper structure
      final buo = BranchUniversalObject(
        canonicalIdentifier: 'chat/$deviceId',
        title: 'Chat with $friendlyName on Vant Chat',
        contentDescription: 'Start a secure conversation with $friendlyName',
        imageUrl: 'https://pearmessaging.com/icon.png',
        contentMetadata: contentMetadata,
        publiclyIndex: false,
        locallyIndex: true,
      );

      // Create Link Properties with proper configuration
      final lp = BranchLinkProperties(
        channel: 'share',
        feature: 'chat_invite',
        stage: 'user_share',
        campaign: 'vant_chat_share',
      );

      // Add control parameters for direct app opening
      lp.addControlParam('\$uri_redirect_mode', '2');
      lp.addControlParam('\$og_title', 'Chat with $friendlyName');
      lp.addControlParam('\$og_description', 'Start chatting on Vant Chat');
      lp.addControlParam(
        '\$og_image_url',
        'https://pearmessaging.com/icon.png',
      );

      lp.addControlParam('\$deeplink_no_attribution', 'true');
      lp.addControlParam('\$match_duration', '7200');
      lp.addControlParam('\$one_time_use', 'false');

      // iOS-specific configuration for better deep linking and App Store fallback
      lp.addControlParam('\$ios_deeplink_path', 'chat');

      // Add App Store ID for iOS fallback when app is not installed
      lp.addControlParam('\$ios_app_store_id', '6758916131');

      // Force direct App Store redirect without showing web page
      lp.addControlParam(
        '\$ios_url',
        'https://apps.apple.com/app/id6758916131',
      );
      lp.addControlParam('\$ios_redirect_timeout', '0');
      lp.addControlParam('\$ios_passive_deepview', 'false');

      // Additional iOS-specific parameters
      lp.addControlParam('\$ios_scheme', 'vantchat');
      lp.addControlParam('\$ios_package', 'com.vant.chatting');

      // Android-specific: redirect to Play Store when app is not installed
      lp.addControlParam(
        '\$android_url',
        'https://play.google.com/store/apps/details?id=com.vant.chat',
      );
      lp.addControlParam('\$android_package', 'com.vant.chat');
      lp.addControlParam('\$android_deeplink_path', 'chat');

      // Disable the web preview page (Journeys/Deepview)
      lp.addControlParam(
        '\$desktop_url',
        'https://pearmessaging.com',
      );
      lp.addControlParam(
        '\$fallback_url',
        'https://pearmessaging.com',
      );

      // Add device_id as control parameter for backup extraction
      lp.addControlParam('device_id', deviceId);
      lp.addControlParam('chat_device_id', deviceId);

      // Generate short link with timeout
      debugPrint('⏳ Requesting Branch.io short URL...');
      final response = await FlutterBranchSdk.getShortUrl(
        buo: buo,
        linkProperties: lp,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          debugPrint('⏱️ Branch.io request timed out after 15 seconds');
          throw Exception('Branch.io link generation timed out');
        },
      );

      if (response.success) {
        final url = response.result ?? '';
        debugPrint('✅ Generated Branch.io link: $url');
        return url;
      } else {
        debugPrint(
          '❌ Failed to generate Branch.io link: ${response.errorMessage} (Code: ${response.errorCode})',
        );

        // Try REST API fallback
        final fallbackUrl = await _generateLinkViaAPI(deviceId, friendlyName);
        if (fallbackUrl != null) {
          return fallbackUrl;
        }

        throw Exception('Failed to generate share link');
      }
    } catch (e) {
      debugPrint('❌ Error generating Branch.io link: $e');

      // Try REST API fallback
      try {
        final deviceId = _storageService.deviceId!;
        final friendlyName = _storageService.getDisplayName(deviceId);
        final fallbackUrl = await _generateLinkViaAPI(deviceId, friendlyName);
        if (fallbackUrl != null) {
          return fallbackUrl;
        }
      } catch (fallbackError) {
        debugPrint('❌ Fallback API also failed: $fallbackError');
      }

      rethrow;
    }
  }

  /// Generate link using Branch.io REST API as fallback
  Future<String?> _generateLinkViaAPI(
    String deviceId,
    String friendlyName,
  ) async {
    try {
      debugPrint('🌐 Attempting to generate link via Branch.io REST API...');

      final response = await http
          .post(
            Uri.parse('https://api2.branch.io/v1/url'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'branch_key': 'key_live_duxqKkJhod2Xdn2FEQ0Aujgjvxhu3F0E',
              'data': {
                'page': 'chat',
                'device_id': deviceId,
                'user_name': friendlyName,
                '\$og_title': 'Chat with $friendlyName',
                '\$og_description': 'Start chatting on Vant Chat',
                '\$uri_redirect_mode': 2,
                '\$always_deeplink': true,
                '\$ios_app_store_id': '6758916131',
                '\$ios_url': 'https://apps.apple.com/app/id6758916131',
                '\$ios_redirect_timeout': '0',
                '\$ios_passive_deepview': 'false',
                '\$ios_scheme': 'vantchat',
                '\$ios_package': 'com.vant.chatting',
                '\$android_url':
                    'https://play.google.com/store/apps/details?id=com.vant.chat',
                '\$android_package': 'com.vant.chat',
                '\$desktop_url': 'https://pearmessaging.com',
                '\$fallback_url': 'https://pearmessaging.com',
              },
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final url = data['url'] as String?;
        if (url != null && url.isNotEmpty) {
          debugPrint('✅ Generated link via REST API: $url');
          return url;
        }
      } else {
        debugPrint(
          '❌ Branch.io API error: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('❌ Branch.io API request failed: $e');
    }
    return null;
  }

  /// Share app with generated link
  Future<void> shareApp({Rect? sharePositionOrigin}) async {
    try {
      final deviceId = _storageService.deviceId;
      if (deviceId == null) {
        throw Exception('Device ID not available');
      }

      final friendlyName = _storageService.getDisplayName(deviceId);
      String link;

      try {
        // Try to generate proper Branch.io link
        link = await generateShareLink();
        debugPrint('✅ Generated Branch.io link: $link');
      } catch (e) {
        // Fallback to custom scheme if Branch.io fails
        debugPrint('⚠️ Branch.io failed, using custom scheme: $e');
        link = 'vantchat://chat?device_id=$deviceId';
      }

      final message = '''Hi! Let's chat on Vant Chat🔒

    I'm $friendlyName. Click this link to start chatting:

  $link

Once installed, the connection will be established automatically, and you can begin messaging me.

Experience total privacy with military-grade encryption and a direct, peer-to-peer connection that bypasses third-party servers entirely.''';

      await Share.share(
        message,
        subject: 'Chat with me on Vant Chat',
        sharePositionOrigin: sharePositionOrigin,
      );
      debugPrint('✅ App shared successfully');
    } catch (e) {
      debugPrint('❌ Error sharing app: $e');
      Get.snackbar(
        'Share Failed',
        'Unable to share the app. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  /// Generate custom scheme link for direct app opening (fallback)
  String generateCustomSchemeLink(String deviceId) {
    final userName = _storageService.getDisplayName(deviceId);
    return 'vantchat://chat?device_id=$deviceId&user_name=$userName';
  }

  /// Process deep link data and extract device_id
  Future<void> _processDeepLinkData(
    Map<dynamic, dynamic> data, {
    required bool isColdStart,
  }) async {
    String? deviceId;

    // Try direct keys first
    if (data.containsKey('device_id')) {
      deviceId = data['device_id'] as String?;
    } else if (data.containsKey('~device_id')) {
      deviceId = data['~device_id'] as String?;
    } else if (data.containsKey('\$device_id')) {
      deviceId = data['\$device_id'] as String?;
    } else if (data.containsKey('custom_data')) {
      // Check in custom_data object
      final customData = data['custom_data'] as Map<String, dynamic>?;
      if (customData != null) {
        deviceId = customData['device_id'] as String?;
      }
    } else if (data.containsKey('+clicked_branch_link') &&
        data['+clicked_branch_link'] == true) {
      // For direct link clicks, try to extract from the URL or other params
      debugPrint('🔗 Branch link was clicked directly');

      // Try to get from any available key that might contain device_id
      for (final key in data.keys) {
        final value = data[key];
        if (value is String && value.length > 10) {
          // Assume it's a device ID if it's reasonably long
          deviceId = value;
          debugPrint('🔗 Using device_id from key: $key');
          break;
        }
      }
    }

    // Check for Branch.io custom metadata format
    if (deviceId == null) {
      // Branch.io sometimes stores custom metadata under different keys
      if (data.containsKey('page') && data['page'] == 'chat') {
        // This is a chat link, try to find device_id in various locations
        for (final key in data.keys) {
          if (key.toLowerCase().contains('device') ||
              key.toLowerCase().contains('user') ||
              key.toLowerCase().contains('id')) {
            final value = data[key];
            if (value is String && value.length > 10) {
              deviceId = value;
              debugPrint('🔗 Found potential device_id in key: $key = $value');
              break;
            }
          }
        }
      }
    }

    // Try to extract from the canonical identifier
    if (deviceId == null && data.containsKey('~canonical_identifier')) {
      final canonical = data['~canonical_identifier'] as String?;
      if (canonical != null && canonical.startsWith('chat/')) {
        deviceId = canonical.substring(5); // Remove 'chat/' prefix
        debugPrint(
          '🔗 Extracted device_id from canonical identifier: $deviceId',
        );
      }
    }

    // Check for control parameters
    if (deviceId == null) {
      if (data.containsKey('chat_device_id')) {
        deviceId = data['chat_device_id'] as String?;
        debugPrint(
          '🔗 Found device_id in chat_device_id control param: $deviceId',
        );
      }
    }

    if (deviceId != null && deviceId.isNotEmpty) {
      debugPrint(
        '🔗 Found device_id: $deviceId ${isColdStart ? "(cold start)" : "(warm start)"}',
      );

      // Check for duplicate processing at listener level
      final now = DateTime.now();
      if (_lastProcessedDeviceId == deviceId &&
          _lastProcessedTime != null &&
          now.difference(_lastProcessedTime!).inSeconds < 5) {
        debugPrint(
          '📋 Branch listener: Duplicate listener call detected, skipping processing',
        );
        return;
      }

      // Enhanced duplicate check: Also check if we recently processed this device
      if (lastGlobalDeviceId == deviceId &&
          lastGlobalNavigationTime != null &&
          now.difference(lastGlobalNavigationTime!).inSeconds < 10) {
        debugPrint(
          '📋 Branch listener: Recently processed this device globally, skipping',
        );
        return;
      }

      // Set listener processing flags
      _lastProcessedDeviceId = deviceId;
      _lastProcessedTime = now;

      // Also check global navigation state
      if (isGloballyNavigating &&
          lastGlobalDeviceId == deviceId &&
          lastGlobalNavigationTime != null &&
          now.difference(lastGlobalNavigationTime!).inSeconds < 5) {
        debugPrint(
          '📋 Branch listener: Global navigation in progress, skipping processing',
        );
        return;
      }

      // Store invitation data for first-time installs
      try {
        final invitationService = Get.find<InvitationStorageService>();
        await invitationService.storeBranchInvitation(
          Map<String, dynamic>.from(data),
        );
      } catch (e) {
        debugPrint('⚠️ InvitationStorageService not available: $e');
      }

      // For cold start, add a small delay to ensure app is fully initialized
      if (isColdStart) {
        debugPrint('🔗 Cold start detected, adding delay before navigation');
        await Future.delayed(const Duration(milliseconds: 1000));
      }

      _handleDeepLink(deviceId, isColdStart: isColdStart);
    } else {
      debugPrint('⚠️ No device_id found in deep link data');
      debugPrint('🔗 Available keys: ${data.keys.toList()}');
    }
  }

  /// Handle incoming deep link
  void _handleDeepLink(String deviceId, {bool isColdStart = false}) async {
    debugPrint(
      '🔗 Handling deep link for device: $deviceId (coldStart: $isColdStart)',
    );

    // Check for global duplicate navigation across all services
    final now = DateTime.now();
    if (isGloballyNavigating &&
        lastGlobalDeviceId == deviceId &&
        lastGlobalNavigationTime != null &&
        now.difference(lastGlobalNavigationTime!).inSeconds < 3) {
      debugPrint(
        '📋 Global duplicate deep link detected for same device, skipping navigation',
      );
      return;
    }

    // Check for local duplicate navigation
    if (_isNavigating &&
        _lastNavigatedDeviceId == deviceId &&
        _lastNavigationTime != null &&
        now.difference(_lastNavigationTime!).inSeconds < 3) {
      debugPrint(
        '📋 Local duplicate deep link detected for same device, skipping navigation',
      );
      return;
    }

    // For cold start, wait longer and don't navigate - let splash handle it
    if (isColdStart) {
      debugPrint('🔗 Cold start detected - storing data for splash controller');

      // Wait for basic services to be ready
      int retries = 0;
      while (!Get.isRegistered<LocalStorageService>() && retries < 20) {
        debugPrint('⏳ Waiting for LocalStorageService... (${retries + 1}/20)');
        await Future.delayed(const Duration(milliseconds: 500));
        retries++;
      }

      if (!Get.isRegistered<LocalStorageService>()) {
        debugPrint(
          '❌ LocalStorageService not ready after 10 seconds, aborting',
        );
        return;
      }

      // Store the deep link data for splash controller to handle
      try {
        final invitationService = Get.find<InvitationStorageService>();
        final userName = _storageService.getDisplayName(deviceId);
        await invitationService.storePendingInvitation(
          deviceId: deviceId,
          userName: userName,
        );
        debugPrint(
          '💾 Cold start: Stored pending invitation for splash controller',
        );
        return; // Exit - let splash controller handle navigation
      } catch (e) {
        debugPrint('⚠️ Could not store pending invitation: $e');
        return;
      }
    }

    // Check if we're already in a chat screen to avoid double navigation
    final currentRoute = Get.currentRoute;
    if (currentRoute == AppRoutes.chat) {
      debugPrint('📋 Already in chat screen, skipping deep link navigation');
      return;
    }

    // Set global and local navigation flags
    isGloballyNavigating = true;
    lastGlobalDeviceId = deviceId;
    lastGlobalNavigationTime = now;
    _isNavigating = true;
    _lastNavigatedDeviceId = deviceId;
    _lastNavigationTime = now;

    // Add delay to ensure app is fully initialized and navigation is ready
    await Future.delayed(const Duration(milliseconds: 800));

    // Check if we're already in the app and navigation is ready
    if (!Get.isRegistered<LocalStorageService>()) {
      debugPrint('⚠️ Services not ready, retrying deep link in 2 seconds...');
      await Future.delayed(const Duration(seconds: 2));

      // Double check if services are ready now
      if (!Get.isRegistered<LocalStorageService>()) {
        debugPrint('❌ Services still not ready, cannot process deep link');
        _isNavigating = false;
        isGloballyNavigating = false;
        return;
      }
    }

    try {
      // Check if chat exists
      final existingChat = _storageService.getChat(deviceId);

      String userName;
      bool isNewChat;

      // Enhanced validation: Check for existing connection requests
      final existingRequests = _storageService.getPendingConnectionRequests();
      final hasExistingRequest = existingRequests.any((request) =>
          request.senderDeviceId == deviceId ||
          request.receiverDeviceId == deviceId);

      // For warm start (app already running), handle navigation normally
      if (existingChat != null) {
        // Chat exists - navigate to it
        userName = existingChat.userName;
        isNewChat = false;
        debugPrint('📱 Opening existing chat with: $userName');

        await _navigateToChat(
          deviceId: deviceId,
          userName: userName,
          isNewChat: isNewChat,
          isColdStart: isColdStart,
        );
      } else if (hasExistingRequest) {
        // Connection request already exists - navigate to chat list
        userName = _storageService.getDisplayName(deviceId);
        isNewChat = true;
        debugPrint(
            '📱 Connection request already exists for: $userName, navigating to chat list');

        Get.offAllNamed(AppRoutes.chatList);

        Get.snackbar(
          'Connection Request',
          'Connection request already pending for $userName',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.orange.shade100,
          colorText: Colors.orange.shade800,
        );
      } else {
        // New contact - create connection request and navigate to chat list
        userName = _storageService.getDisplayName(deviceId);
        isNewChat = true;
        debugPrint('📱 Creating connection request for: $userName');

        try {
          final connectionRequest = ConnectionRequestEntity(
            id: 'req_${DateTime.now().millisecondsSinceEpoch}',
            senderDeviceId: deviceId,
            receiverDeviceId: _storageService.deviceId!,
            timestamp: DateTime.now(),
            status: ConnectionRequestStatus.pending,
            messageContent: null,
            messageType: MessageType.text,
          );

          await _storageService.saveConnectionRequest(connectionRequest);

          // Add to chat list controller and navigate
          final chatListController = Get.find<ChatListController>();
          chatListController.pendingConnectionRequests.add(connectionRequest);
          chatListController.loadChats();

          debugPrint('✅ Connection request created, navigating to chat list');
          Get.offAllNamed(AppRoutes.chatList);

          Get.snackbar(
            'Connection Request',
            'New connection request from $userName',
            snackPosition: SnackPosition.BOTTOM,
            backgroundColor: Colors.blue.shade100,
            colorText: Colors.blue.shade800,
          );
        } catch (e) {
          debugPrint('⚠️ Error creating connection request: $e');
          Get.offAllNamed(AppRoutes.chatList);
        }
      }
    } catch (e) {
      debugPrint('❌ Error handling deep link: $e');
      debugPrint('❌ Stack trace: ${StackTrace.current}');
      // Don't navigate away on error - let user stay where they are
    } finally {
      // Reset both global and local navigation flags
      isGloballyNavigating = false;
      lastGlobalDeviceId = null;
      lastGlobalNavigationTime = null;
      _isNavigating = false;
      _lastNavigatedDeviceId = null;
      _lastNavigationTime = null;
    }
  }

  /// Navigate to chat with proper error handling and timing
  Future<void> _navigateToChat({
    required String deviceId,
    required String userName,
    required bool isNewChat,
    bool isColdStart = false,
  }) async {
    debugPrint('🚀 Starting navigation to chat: $deviceId');

    try {
      // Check current route to determine navigation strategy
      final currentRoute = Get.currentRoute;
      debugPrint('📍 Current route: $currentRoute');

      // If we're on splash or onboarding, wait for app to fully initialize
      if (currentRoute == AppRoutes.splash ||
          currentRoute == AppRoutes.onboarding ||
          currentRoute == '/') {
        debugPrint('⏳ App still initializing, waiting before navigation...');
        await Future.delayed(const Duration(seconds: 2));
      }

      // Prepare arguments
      final arguments = {
        'chatId': deviceId,
        'userName': userName,
        'recipientDeviceId': deviceId,
        'myDeviceId': _storageService.deviceId, // Add current user's device ID
      };

      if (isColdStart) {
        // For cold start, ensure chat list is in navigation stack first
        debugPrint('📱 Cold start: Setting up proper navigation stack...');

        // First navigate to chat list to establish proper navigation stack
        Get.offAllNamed(AppRoutes.chatList);

        // Wait a moment for chat list to initialize
        await Future.delayed(const Duration(milliseconds: 300));

        // Then navigate to chat with proper back navigation
        debugPrint("location 1");
        Get.toNamed(AppRoutes.chat, arguments: arguments);

        debugPrint(
          '✅ Cold start navigation: ChatList → Chat (back button will work)',
        );
      } else {
        // For warm start, use offAllNamed as before
        debugPrint(
          '📱 Warm start: Clearing navigation stack and going directly to chat...',
        );
        Get.offAllNamed(AppRoutes.chat, arguments: arguments);
        debugPrint('✅ Warm start navigation: Direct to chat');
      }

      debugPrint('✅ Navigation initiated to chat with: $userName');

      // Show snackbar for new chat
      if (isNewChat) {
        await Future.delayed(const Duration(milliseconds: 800));
        Get.snackbar(
          'New Chat',
          'Started conversation with $userName',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      }
    } catch (e) {
      debugPrint('❌ Navigation error: $e');
      debugPrint('❌ Stack trace: ${StackTrace.current}');
      // Don't do fallback navigation - it causes the auto-back issue
    }
  }
}
