import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

/// Notification Service - Handles high-priority call notifications with Accept/Reject buttons
/// This service uses flutter_local_notifications for reliable WhatsApp-style call notifications
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Stream controller for notification actions
  final StreamController<NotificationAction> _actionController =
      StreamController<NotificationAction>.broadcast();
  Stream<NotificationAction> get onAction => _actionController.stream;

  /// Initialize notification channels and settings
  Future<void> initialize() async {
    debugPrint('🔔 NotificationService: Initializing...');

    // Android initialization
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    // iOS initialization
    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        );

    // Combined initialization settings
    const InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    // Initialize plugin
    await _notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
      onDidReceiveBackgroundNotificationResponse:
          _handleBackgroundNotificationResponse,
    );

    // Create high-priority notification channels for Android
    await _createNotificationChannels();

    debugPrint('🔔 NotificationService: Initialized');
  }

  /// Create notification channels for Android
  Future<void> _createNotificationChannels() async {
    if (!Platform.isAndroid) return;

    // Incoming call channel - HIGH PRIORITY with full-screen intent
    // Sound/vibration disabled here — RingtoneService handles audio; notification is for UI only
    final AndroidNotificationChannel incomingCallChannel =
        AndroidNotificationChannel(
          'incoming_call_channel',
          'Incoming Calls',
          description: 'High priority notifications for incoming calls',
          importance: Importance.max,
          playSound: false,
          enableVibration: false,
          showBadge: true,
          enableLights: true,
        );

    // Missed call channel
    const AndroidNotificationChannel missedCallChannel =
        AndroidNotificationChannel(
          'missed_call_channel',
          'Missed Calls',
          description: 'Notifications for missed calls',
          importance: Importance.high,
          playSound: true,
          enableVibration: true,
        );

    // Create channels
    final androidPlugin = _notificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    await androidPlugin?.createNotificationChannel(incomingCallChannel);
    await androidPlugin?.createNotificationChannel(missedCallChannel);

    debugPrint('🔔 Notification channels created');
  }

  /// Show high-priority incoming call notification with Accept/Reject actions
  /// This shows a heads-up notification that appears on lock screen like WhatsApp
  Future<void> showIncomingCallNotification({
    required String callId,
    required String callerId,
    required String callerName,
    String? callerAvatarUrl,
  }) async {
    debugPrint('🔔 Showing incoming call notification for $callerName');

    try {
      // Android notification details with full-screen intent
      final AndroidNotificationDetails
      androidDetails = AndroidNotificationDetails(
        'incoming_call_channel',
        'Incoming Calls',
        channelDescription: 'High priority notifications for incoming calls',
        importance: Importance.max,
        priority: Priority.max,
        fullScreenIntent: true, // Shows over lock screen
        category: AndroidNotificationCategory.call,
        visibility: NotificationVisibility.public, // Show on lock screen
        ongoing: false,
        autoCancel: true,
        showWhen: true,
        playSound: false,
        enableVibration: false,
        enableLights: true,
        color: const Color(0xFF0955FA),
        largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
        styleInformation: const BigTextStyleInformation(
          'Incoming voice call',
          contentTitle: 'Tap to answer',
          summaryText: 'Vant Chat',
        ),
        actions: [
          // Accept action - green button
          const AndroidNotificationAction(
            'accept',
            'Accept',
            showsUserInterface: true,
            cancelNotification: true,
          ),
          // Reject action - red button
          const AndroidNotificationAction(
            'reject',
            'Reject',
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      );

      // iOS notification details
      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'ringtone.wav',
        interruptionLevel: InterruptionLevel.critical, // Bypass Do Not Disturb
        categoryIdentifier: 'incoming_call',
      );

      // Combined details
      final NotificationDetails details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      // Show notification
      await _notificationsPlugin.show(
        callId.hashCode, // Unique ID based on callId
        callerName,
        'Incoming voice call',
        details,
        payload: 'call:$callId:$callerId:$callerName',
      );

      debugPrint('🔔 Incoming call notification shown successfully');
    } catch (e) {
      debugPrint('❌ Failed to show notification: $e');
    }
  }

  /// Show missed call notification
  Future<void> showMissedCallNotification({
    required String callId,
    required String callerName,
  }) async {
    debugPrint('🔔 Showing missed call notification for $callerName');

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'missed_call_channel',
          'Missed Calls',
          channelDescription: 'Notifications for missed calls',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
        );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notificationsPlugin.show(
      callId.hashCode,
      'Missed call from $callerName',
      'Tap to call back',
      details,
      payload: 'missed_call:$callId:$callerName',
    );
  }

  /// Cancel a specific notification
  Future<void> cancelNotification(int id) async {
    await _notificationsPlugin.cancel(id);
  }

  /// Cancel all notifications
  Future<void> cancelAllNotifications() async {
    await _notificationsPlugin.cancelAll();
  }

  /// Handle notification response when app is in foreground
  void _handleNotificationResponse(NotificationResponse response) {
    debugPrint(
      '🔔 Notification response: ${response.actionId} - ${response.payload}',
    );

    final action = response.actionId ?? 'tap';
    final payload = response.payload ?? '';

    _actionController.add(NotificationAction(action: action, payload: payload));
  }

  /// Handle background notification response
  @pragma('vm:entry-point')
  static void _handleBackgroundNotificationResponse(
    NotificationResponse response,
  ) {
    debugPrint('🔔 Background notification response: ${response.actionId}');
    // Handle in background if needed
  }

  /// Dispose
  void dispose() {
    _actionController.close();
  }
}

/// Notification action data
class NotificationAction {
  final String action; // 'accept', 'reject', or 'tap'
  final String payload;

  NotificationAction({required this.action, required this.payload});

  /// Parse payload to get call details
  Map<String, String>? getCallDetails() {
    final parts = payload.split(':');
    if (parts.length >= 3 && parts[0] == 'call') {
      return {
        'callId': parts[1],
        'callerId': parts[2],
        'callerName': parts.length > 3 ? parts.sublist(3).join(':') : 'Unknown',
      };
    }
    return null;
  }
}
