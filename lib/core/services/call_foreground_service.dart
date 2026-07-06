import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Call Foreground Service - keeps the app process alive on Android while
/// a WebRTC call is active. Without this Android kills the process when the
/// app is backgrounded, dropping the call.
class CallForegroundService {
  static final CallForegroundService _instance =
      CallForegroundService._internal();
  factory CallForegroundService() => _instance;
  CallForegroundService._internal();

  static const _notificationChannelId = 'call_foreground';
  static const _notificationId = 888;
  bool _isRunning = false;

  /// Initialize notification channel (call once at app startup)
  static Future<void> initialize() async {
    final notifications = FlutterLocalNotificationsPlugin();
    const androidChannel = AndroidNotificationChannel(
      _notificationChannelId,
      'Active Call',
      description: 'Shown while a call is in progress',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    );

    await notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(androidChannel);

    await FlutterBackgroundService().configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onServiceStart,
        isForegroundMode: true,
        autoStart: false,
        notificationChannelId: _notificationChannelId,
        initialNotificationTitle: 'Call in progress',
        initialNotificationContent: 'Tap to return to call',
        foregroundServiceNotificationId: _notificationId,
        foregroundServiceTypes: [AndroidForegroundType.microphone],
      ),
      iosConfiguration: IosConfiguration(autoStart: false),
    );

    debugPrint('📞 CallForegroundService initialized');
  }

  /// Start the foreground service when a call begins
  Future<void> start() async {
    if (_isRunning) return;
    try {
      await FlutterBackgroundService().startService();
      _isRunning = true;
      debugPrint(
        '📞 CallForegroundService started — call protected from background kill',
      );
    } catch (e) {
      debugPrint('⚠️ CallForegroundService start failed: $e');
    }
  }

  /// Stop the foreground service when the call ends
  Future<void> stop() async {
    try {
      FlutterBackgroundService().invoke('stop');
      debugPrint('📞 CallForegroundService stop requested');
    } catch (e) {
      debugPrint('⚠️ CallForegroundService stop failed: $e');
    } finally {
      _isRunning = false;
    }
  }

  bool get isRunning => _isRunning;
}

/// Background isolate entry point — must be a top-level function
@pragma('vm:entry-point')
void _onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
    service.setForegroundNotificationInfo(
      title: 'Call in progress',
      content: 'Tap to return to call',
    );
  }

  // Listen for stop signal from the main isolate
  service.on('stop').listen((_) {
    service.stopSelf();
  });
}
