import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/string_utils.dart';
import '../../routes/app_routes.dart';
import '../../storage/models/message_entity.dart';
import 'local_storage_service.dart';
import 'socket_service.dart';
import 'block_service.dart';
import 'app_lifecycle_service.dart';

// Global notification settings for our custom notifications
const androidNotificationDetails = AndroidNotificationDetails(
  'high_importance_channel',
  'High Importance Notifications',
  channelDescription: 'This channel is used for important notifications.',
  importance: Importance.max,
  priority: Priority.max,
  playSound: true,
  enableVibration: true,
);

// Disabled channel for Firebase automatic notifications
const disabledAndroidNotificationDetails = AndroidNotificationDetails(
  'disabled_channel',
  'Disabled Notifications',
  channelDescription: 'Channel for disabled automatic notifications',
  importance: Importance.none,
  priority: Priority.min,
  playSound: false,
  enableVibration: false,
  enableLights: false,
  showWhen: false,
);

const iosNotificationDetails = DarwinNotificationDetails(
  presentAlert: true,
  presentBadge: true,
  presentSound: true,
);

const notificationDetails = NotificationDetails(
  android: androidNotificationDetails,
  iOS: iosNotificationDetails,
);

/// Top-level function to handle notification taps
Future<void> onNotificationTap(NotificationResponse response) async {
  try {
    if (response.payload == null) return;

    final data = jsonDecode(response.payload!) as Map<String, dynamic>;
    final senderId = data['senderId'] as String?;

    if (senderId != null) {
      // Store pending navigation in SharedPreferences so we can navigate
      // even if app was terminated and GetX services aren't ready yet
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_notification_sender', senderId);

      // Try to navigate immediately if services are already initialized
      try {
        final storageService = Get.find<LocalStorageService>();
        final chat = storageService.getChat(senderId);
        final displayName =
            chat?.userName ?? StringUtils.generateFriendlyName(senderId);

        // Clear pending navigation since we're handling it now
        await prefs.remove('pending_notification_sender');

        // Navigate to chat screen
        Get.toNamed(
          AppRoutes.chat,
          arguments: {
            'chatId': senderId,
            'userName': displayName,
            'recipientDeviceId': senderId,
          },
        );
      } catch (_) {
        // Services not ready yet (app was terminated) — navigation will be
        // handled by checkPendingNotificationNavigation() after app init
        debugPrint(
            '📱 Services not ready, pending navigation stored for: $senderId');
      }
    }
  } catch (e) {
    debugPrint('Error handling notification tap: $e');
  }
}

/// Call this after all services are initialized to handle notification taps
/// that arrived while the app was terminated
Future<void> checkPendingNotificationNavigation() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final senderId = prefs.getString('pending_notification_sender');
    if (senderId == null || senderId.isEmpty) return;

    await prefs.remove('pending_notification_sender');

    final storageService = Get.find<LocalStorageService>();
    final chat = storageService.getChat(senderId);
    final displayName =
        chat?.userName ?? StringUtils.generateFriendlyName(senderId);

    // Use a small delay to ensure the navigator is ready
    await Future.delayed(const Duration(milliseconds: 500));
    Get.toNamed(
      AppRoutes.chat,
      arguments: {
        'chatId': senderId,
        'userName': displayName,
        'recipientDeviceId': senderId,
      },
    );
    debugPrint('📱 Pending notification navigation completed for: $senderId');
  } catch (e) {
    debugPrint('⚠️ Error handling pending notification navigation: $e');
  }
}

/// Background message handler (must be top-level function).
/// Runs in a separate Dart isolate — initialises Hive independently so that
/// the message is persisted to local storage before the user even opens the app.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('📱 Background FCM message received: ${message.data}');
  debugPrint('📱 Message notification: ${message.notification}');
  debugPrint('📱 Platform: ${Platform.isIOS ? "iOS" : "Android"}');

  // Initialize Flutter Local Notifications
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@drawable/ic_stat_ic_notification');
  const DarwinInitializationSettings initializationSettingsIOS =
      DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsIOS,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  // Create Android notification channel
  const androidChannel = AndroidNotificationChannel(
    'high_importance_channel',
    'High Importance Notifications',
    description: 'This channel is used for important notifications.',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
    enableLights: true,
    showBadge: true,
  );

  final androidPlugin =
      flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.createNotificationChannel(androidChannel);

  // Get sender info
  final senderId =
      message.data['senderDeviceId'] ?? message.data['sender'] ?? '';

  if (senderId.isEmpty) {
    debugPrint('⚠️ Background FCM: No sender ID found, skipping');
    return;
  }

  // Show notification immediately
  try {
    final title = message.notification?.title ?? 'New Message';
    final body = message.notification?.body ?? 'You have a new message';
    final payload = jsonEncode({'senderId': senderId});

    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'high_importance_channel',
          'High Importance Notifications',
          channelDescription:
              'This channel is used for important notifications.',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: payload,
    );

    debugPrint('📱 Background notification shown for sender: $senderId');
  } catch (e) {
    debugPrint('❌ Error showing background notification: $e');
  }

  // Now try to save message to storage (non-critical)
  try {
    await Hive.initFlutter();
    final storageService = LocalStorageService();
    await storageService.init();

    final messageId = message.data['messageId'] ?? '';
    final timestampMs = int.tryParse(message.data['timestamp'] ?? '') ??
        DateTime.now().millisecondsSinceEpoch;
    final encryptedContent = message.data['originalMessage'] ?? '';

    if (messageId.isNotEmpty && senderId.isNotEmpty) {
      String contentToStore;
      MessageType msgType = MessageType.text;

      // Always try to decrypt encrypted content first to detect image messages
      if (encryptedContent.isNotEmpty) {
        try {
          debugPrint(
              '📱 Background: Attempting to decrypt encrypted content...');
          contentToStore = SocketService.decryptMessage(encryptedContent);
          debugPrint(
              '📱 Background: Decryption successful, content length: ${contentToStore.length}');

          // Detect media messages only after successful decryption
          // Check for exact MEDIA: or IMAGE: prefix at the start
          if (contentToStore.startsWith('IMAGE:') ||
              contentToStore.startsWith('MEDIA:')) {
            msgType = MessageType.image;
            debugPrint('📱 Background: Detected as media message');
          } else {
            // For text messages, we can use notification body if it's more readable
            final notificationBody = message.notification?.body;
            if (notificationBody != null && notificationBody.isNotEmpty) {
              debugPrint(
                  '📱 Background: Using notification body as content for text message');
              contentToStore = notificationBody;
            }
          }
        } catch (e) {
          debugPrint('⚠️ Background: Decryption failed: $e');
          debugPrint('⚠️ Background: Falling back to notification body');
          final notificationBody = message.notification?.body;
          if (notificationBody != null && notificationBody.isNotEmpty) {
            contentToStore = notificationBody;
            msgType = MessageType.text;
          } else {
            contentToStore = 'New message';
            msgType = MessageType.text;
          }
        }
      } else {
        // No encrypted content, fall back to notification body
        final notificationBody = message.notification?.body;
        if (notificationBody != null && notificationBody.isNotEmpty) {
          debugPrint(
              '📱 Background: Using notification body as content (no encrypted content)');
          contentToStore = notificationBody;
          msgType = MessageType.text;
        } else {
          contentToStore = 'New message';
          msgType = MessageType.text;
        }
      }

      await storageService.saveMessage(
        MessageEntity(
          id: messageId,
          chatId: senderId,
          senderId: senderId,
          receiverId: '',
          content: contentToStore,
          timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs),
          status: MessageStatus.delivered,
          isMe: false,
          type: msgType,
        ),
      );
      debugPrint(
          '💾 Background: saved message $messageId to local DB with status: delivered');
      // Queue delivery ack so sender gets 'delivered' status when socket reconnects
      FCMService._storeAcknowledgmentRequestStatic(messageId, senderId);
    }
  } catch (e) {
    debugPrint('⚠️ Background: Could not save message to storage: $e');
    // Don't fail the notification if storage fails
  }
}

/// FCM Service for handling push notifications
class FCMService extends GetxService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final LocalStorageService _storageService = Get.find();
  SocketService? _socketService;
  String? _fcmToken;

  String? get fcmToken => _fcmToken;

  /// The device ID of the chat currently open on screen.
  /// Foreground notifications are suppressed for this sender.
  static String? activeChatId;

  /// Global app foreground state to suppress iOS notifications when app is open
  static bool isAppInForeground = false;

  /// Initialize FCM service
  Future<FCMService> init() async {
    debugPrint('🚀 Initializing FCM Service...');
    debugPrint('📱 Platform: ${Platform.isIOS ? "iOS" : "Android"}');

    try {
      // Find socket service if available
      _socketService = Get.find<SocketService>();
      debugPrint('✅ Found SocketService');
    } catch (e) {
      debugPrint('⚠️ SocketService not found, will register token later');
    }

    try {
      // Initialize notifications
      debugPrint('🔔 Initializing notifications...');
      const androidSettings =
          AndroidInitializationSettings('@drawable/ic_stat_ic_notification');
      final iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      final initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      // Initialize with tap handler
      await _notifications.initialize(
        initSettings,
        onDidReceiveNotificationResponse: onNotificationTap,
      );

      // Create notification channels
      const highImportanceChannel = AndroidNotificationChannel(
        'high_importance_channel',
        'High Importance Notifications',
        description: 'This channel is used for important notifications.',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        enableLights: true,
        showBadge: true,
      );
      const disabledChannel = AndroidNotificationChannel(
        'disabled_channel',
        'Disabled Notifications',
        description: 'Channel for disabled automatic notifications',
        importance: Importance.none,
        playSound: false,
        enableVibration: false,
        enableLights: false,
        showBadge: false,
      );

      // Register both channels
      final androidPlugin =
          _notifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(highImportanceChannel);
      await androidPlugin?.createNotificationChannel(disabledChannel);
      debugPrint('✅ Notifications initialized');

      // Get FCM token with error handling
      try {
        debugPrint('🔍 Getting FCM token...');
        _fcmToken = await _messaging.getToken();
        if (_fcmToken != null) {
          debugPrint('✅ FCM token obtained: ${_fcmToken!.substring(0, 20)}...');
          debugPrint('📏 Token length: ${_fcmToken!.length}');
        } else {
          debugPrint('⚠️ FCM token is null');
        }
      } catch (e) {
        debugPrint('❌ Failed to get FCM token: $e');
        // Continue without FCM token - app should still work
      }

      // Request notification permissions with error handling
      // Note: On Android 13+, permission is requested via NotificationPermissionScreen before app starts
      // This is a fallback check and handles iOS permissions
      try {
        if (Platform.isAndroid) {
          final status = await Permission.notification.status;
          debugPrint('📱 Android notification permission status: $status');

          if (!status.isGranted) {
            debugPrint(
                '⚠️ Android notification permission not granted - notifications may not work');
          }
        }

        // Request Firebase messaging permission (primarily for iOS)
        debugPrint('🔍 Requesting Firebase messaging permissions...');
        final settings = await _messaging.requestPermission(
          alert: true,
          announcement: false,
          badge: true,
          carPlay: false,
          criticalAlert: false,
          provisional: false,
          sound: true,
        );
        debugPrint(
            '✅ Firebase notification permission: ${settings.authorizationStatus}');

        // iOS-specific debugging
        if (Platform.isIOS) {
          debugPrint('📱 iOS FCM Configuration:');
          debugPrint(
              '   - Authorization Status: ${settings.authorizationStatus}');
          debugPrint('   - Alert: ${settings.alert}');
        }
      } catch (e) {
        debugPrint('❌ Failed to request notification permissions: $e');
      }

      // Set up message handlers with error handling
      try {
        FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
        FirebaseMessaging.onBackgroundMessage(
            firebaseMessagingBackgroundHandler);

        // Handle notification tap when app is opened from terminated state
        FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

        // Check if app was opened from a notification (terminated state)
        final initialMessage = await _messaging.getInitialMessage();
        if (initialMessage != null) {
          debugPrint('📱 App opened from notification: ${initialMessage.data}');
          _handleNotificationTap(initialMessage);
        }

        debugPrint('✅ Message handlers set up');
      } catch (e) {
        debugPrint('❌ Failed to set up message handlers: $e');
      }

      // Set up token refresh listener and register token
      if (_fcmToken != null && _fcmToken!.isNotEmpty) {
        debugPrint('🔧 Setting up token refresh listener...');
        _setupTokenRefreshListener();
        debugPrint('✅ Token refresh listener set up');

        // Register token with socket if available
        if (_socketService != null && _socketService!.isConnected.value) {
          debugPrint('📱 FCM init: Registering token with socket...');
          debugPrint('📱 Token to register: ${_fcmToken!.substring(0, 20)}...');
          await _socketService!.registerFCMToken(_fcmToken!);
          debugPrint('✅ FCM token registered with socket during init');
        } else {
          debugPrint(
              '📱 FCM init: Socket not ready, token will be registered later');
          debugPrint(
              '📱 Socket status: ${_socketService != null ? "Found but not connected" : "Not found"}');
        }
      } else {
        debugPrint('⚠️ FCM token is null or empty after init');
        debugPrint('⚠️ Token value: $_fcmToken');
      }

      debugPrint('✅ FCM Service initialization complete');
      return this;
    } catch (e) {
      debugPrint('❌ Error initializing FCM service: $e');
      debugPrint('📱 FCM Service will continue without full functionality');
      _fcmToken = null;
      return this; // Don't crash the app, continue without FCM
    }
  }

  /// Handle foreground message
  void _handleForegroundMessage(RemoteMessage message) async {
    debugPrint('📱 Foreground message received: ${message.data}');
    debugPrint(
        '📱 Firebase notification title: ${message.notification?.title}');
    debugPrint('📱 Firebase notification body: ${message.notification?.body}');

    // Get sender info first so we can check suppression
    final senderId =
        message.data['senderDeviceId'] ?? message.data['sender'] ?? '';
    debugPrint('📱 Foreground message sender id: $senderId');

    // ── Persist to local DB (socket may be disconnected or slow) ──
    final messageId = message.data['messageId'] ?? '';
    final timestampMs = int.tryParse(message.data['timestamp'] ?? '') ??
        DateTime.now().millisecondsSinceEpoch;
    final encryptedContent = message.data['originalMessage'] ?? '';

    if (messageId.isNotEmpty && senderId.isNotEmpty) {
      // Check bidirectional block status before processing message
      try {
        final blockService = Get.find<BlockService>();

        // Check if messaging is allowed in both directions
        if (!blockService.isMessagingAllowed(senderId)) {
          if (blockService.isUserBlocked(senderId)) {
            debugPrint('🚫 FCM message from user I blocked $senderId ignored');
          } else if (blockService.hasUserBlockedMe(senderId)) {
            debugPrint(
                '🚫 FCM message from user who blocked me $senderId ignored');
          } else {
            debugPrint('🚫 FCM message from $senderId ignored (blocking)');
          }
          return;
        }
      } catch (e) {
        debugPrint('⚠️ Could not check block status for FCM message: $e');
        // Continue processing if block service is not available
      }

      if (!_storageService.messageExists(messageId)) {
        String contentToStore;
        MessageType msgType = MessageType.text;

        // Always try to decrypt encrypted content first to detect image messages
        if (encryptedContent.isNotEmpty) {
          try {
            debugPrint(
                '📱 Foreground: Attempting to decrypt encrypted content...');
            contentToStore = SocketService.decryptMessage(encryptedContent);
            debugPrint(
                '📱 Foreground: Decryption successful, content length: ${contentToStore.length}');

            // Detect media messages only after successful decryption
            // Check for exact MEDIA: or IMAGE: prefix at the start
            if (contentToStore.startsWith('IMAGE:') ||
                contentToStore.startsWith('MEDIA:')) {
              msgType = MessageType.image;
              debugPrint('📱 Foreground: Detected as media message');
            } else {
              // For text messages, we can use notification body if it's more readable
              final notificationBody = message.notification?.body;
              if (notificationBody != null && notificationBody.isNotEmpty) {
                debugPrint(
                    '📱 Foreground: Using notification body as content for text message');
                contentToStore = notificationBody;
              }
            }
          } catch (e) {
            debugPrint('⚠️ Foreground: Decryption failed: $e');
            debugPrint('⚠️ Foreground: Falling back to notification body');
            final notificationBody = message.notification?.body;
            if (notificationBody != null && notificationBody.isNotEmpty) {
              contentToStore = notificationBody;
              msgType = MessageType.text;
            } else {
              contentToStore = 'New message';
              msgType = MessageType.text;
            }
          }
        } else {
          // No encrypted content, fall back to notification body
          final notificationBody = message.notification?.body;
          if (notificationBody != null && notificationBody.isNotEmpty) {
            debugPrint(
                '📱 Foreground: Using notification body as content (no encrypted content)');
            contentToStore = notificationBody;
            msgType = MessageType.text;
          } else {
            contentToStore = 'New message';
            msgType = MessageType.text;
          }
        }

        try {
          await _storageService.saveMessage(
            MessageEntity(
              id: messageId,
              chatId: senderId,
              senderId: senderId,
              receiverId: '',
              content: contentToStore, // Original MEDIA:token preserved
              timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs),
              status: MessageStatus.delivered,
              isMe: false,
              type: msgType, // Correct type for media messages
            ),
          );
          debugPrint(
              '💾 Foreground: saved message $messageId to local DB (type: $msgType)');
        } catch (e) {
          debugPrint('💾 Foreground: error saving message to local DB: $e');
        }
      } else {
        debugPrint(
            '💾 Foreground: message $messageId already in DB, skipping save');
      }
    }

    // ── Show notification for foreground messages ──
    // Only show notification if user is not currently in this chat
    // On iOS, also suppress if app is in foreground (like WhatsApp behavior)
    bool shouldSuppressNotification = false;
    String suppressReason = '';

    if (senderId.isNotEmpty && activeChatId == senderId) {
      shouldSuppressNotification = true;
      suppressReason = 'user is in chat with: $senderId';
    } else if (Platform.isIOS && AppLifecycleService.instance.isInForeground) {
      shouldSuppressNotification = true;
      suppressReason = 'app is in foreground on iOS';
    }

    if (!shouldSuppressNotification && senderId.isNotEmpty) {
      try {
        final title = message.notification?.title ?? 'New Message';
        final body = message.notification?.body ?? 'You have a new message';

        await showTestNotification(title, body, senderId);
        debugPrint('📱 Foreground notification shown for sender: $senderId');
      } catch (e) {
        debugPrint('❌ Error showing foreground notification: $e');
      }
    } else if (shouldSuppressNotification) {
      debugPrint('📱 Skipping notification - $suppressReason');
    }
  }

  /// Handle notification tap from Firebase (background/terminated state)
  void _handleNotificationTap(RemoteMessage message) {
    debugPrint('📱 Notification tapped: ${message.data}');

    final senderId =
        message.data['senderDeviceId'] ?? message.data['sender'] ?? '';

    if (senderId.isNotEmpty) {
      final chat = _storageService.getChat(senderId);
      final displayName =
          chat?.userName ?? StringUtils.generateFriendlyName(senderId);

      // Navigate to chat screen
      Get.toNamed(
        AppRoutes.chat,
        arguments: {
          'chatId': senderId,
          'userName': displayName,
          'recipientDeviceId': senderId,
        },
      );
      debugPrint('📱 Navigating to chat with: $displayName');
    }
  }

  /// Setup token refresh listener
  void _setupTokenRefreshListener() {
    _messaging.onTokenRefresh.listen((token) {
      debugPrint('🔄 FCM token refreshed: $token');
      _fcmToken = token;

      // Register new token with socket if available
      if (_socketService != null) {
        _socketService!.registerFCMToken(token).then((_) {
          debugPrint('✅ New FCM token registered with socket');
        }).catchError((e) {
          debugPrint('❌ Error registering token with socket: $e');
        });
      }
    });
  }

  /// Debug method to check FCM token status
  void debugTokenStatus() {
    debugPrint('🔍 FCM Token Status Debug:');
    debugPrint('   - Token exists: ${_fcmToken != null}');
    debugPrint('   - Token empty: ${_fcmToken?.isEmpty ?? true}');
    debugPrint('   - Token length: ${_fcmToken?.length ?? 0}');
    debugPrint(
        '   - Token preview: ${_fcmToken?.substring(0, math.min(20, _fcmToken?.length ?? 0))}...');
    debugPrint('   - Socket available: ${_socketService != null}');
    debugPrint(
        '   - Socket connected: ${_socketService?.isConnected.value ?? false}');
  }

  /// Cancel the notification shown for a specific sender (called when chat is opened)
  Future<void> cancelNotificationForSender(String senderId) async {
    if (senderId.isEmpty) return;
    final notificationId = senderId.hashCode.abs() % 100000;
    await _notifications.cancel(notificationId);
    debugPrint(
        '🔕 Notification cancelled for sender: $senderId (id: $notificationId)');
  }

  /// Register token if socket service becomes available
  Future<void> registerTokenIfAvailable() async {
    try {
      _socketService ??= Get.find<SocketService>();
      if (_fcmToken != null && _fcmToken!.isNotEmpty) {
        debugPrint(
            '📱 Registering FCM token: ${_fcmToken!.substring(0, 20)}...');
        await _socketService!.registerFCMToken(_fcmToken!);
        debugPrint('✅ FCM token registered with socket service');
      } else {
        debugPrint('⚠️ FCM token is null or empty, cannot register');
      }
    } catch (e) {
      debugPrint('⚠️ Error registering FCM token: $e');
    }
  }

  /// Show local notification (for testing purposes and iOS fallback)
  Future<void> showTestNotification(
      String title, String body, String senderId) async {
    try {
      debugPrint('🔔 DEBUG: showTestNotification called');
      debugPrint('🔔 DEBUG: title: $title, body: $body, senderId: $senderId');

      final payload = jsonEncode({'senderId': senderId});
      debugPrint('🔔 DEBUG: payload created: $payload');

      final notificationId =
          DateTime.now().millisecondsSinceEpoch.remainder(100000);
      debugPrint('🔔 DEBUG: notificationId: $notificationId');

      await _notifications.show(
        notificationId,
        title,
        body,
        notificationDetails,
        payload: payload,
      );

      debugPrint('📢 Local notification shown successfully: $title -> $body');
    } catch (e) {
      debugPrint('❌ Error showing notification: $e');
      debugPrint('❌ Stack trace: ${StackTrace.current}');
    }
  }

  /// Store acknowledgment request for later processing (static version)
  static void _storeAcknowledgmentRequestStatic(
      String messageId, String senderId) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Get existing acknowledgments
      final acknowledgments =
          prefs.getStringList('pending_acknowledgments') ?? [];

      // Add new acknowledgment
      acknowledgments.add('$messageId:$senderId');

      // Save back
      await prefs.setStringList('pending_acknowledgments', acknowledgments);

      debugPrint(
          '💾 Stored acknowledgment request (static) for $messageId from $senderId');
    } catch (e) {
      debugPrint('⚠️ Error storing acknowledgment request (static): $e');
    }
  }

  /// Send all pending delivery acknowledgments when socket connects
  static Future<void> sendPendingAcknowledgments() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final acknowledgments =
          prefs.getStringList('pending_acknowledgments') ?? [];

      if (acknowledgments.isEmpty) {
        debugPrint('📤 No pending acknowledgments to send');
        return;
      }

      debugPrint(
          '📤 Sending ${acknowledgments.length} pending acknowledgments');

      // Get socket service
      if (!Get.isRegistered<SocketService>()) {
        debugPrint(
            '⚠️ SocketService not registered, cannot send acknowledgments');
        return;
      }

      final socketService = Get.find<SocketService>();

      if (!socketService.isConnected.value) {
        debugPrint('⚠️ Socket not connected, keeping acknowledgments pending');
        return;
      }

      // Send acknowledgments
      final sentAcknowledgments = <String>[];
      for (final acknowledgment in acknowledgments) {
        try {
          final parts = acknowledgment.split(':');
          if (parts.length == 2) {
            final messageId = parts[0];
            socketService.sendMessageAck(messageId);
            sentAcknowledgments.add(acknowledgment);

            debugPrint('✅ Sent delivery acknowledgment for $messageId');
          }
        } catch (e) {
          debugPrint('⚠️ Error sending acknowledgment for $acknowledgment: $e');
        }
      }

      // Remove sent acknowledgments from pending list
      final remainingAcknowledgments = acknowledgments
          .where((ack) => !sentAcknowledgments.contains(ack))
          .toList();

      await prefs.setStringList(
          'pending_acknowledgments', remainingAcknowledgments);

      debugPrint(
          '📤 Sent ${sentAcknowledgments.length} acknowledgments, ${remainingAcknowledgments.length} remaining');
    } catch (e) {
      debugPrint('⚠️ Error sending pending acknowledgments: $e');
    }
  }
}
