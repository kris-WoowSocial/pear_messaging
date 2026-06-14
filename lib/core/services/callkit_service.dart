import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/entities/ios_params.dart';
import 'package:flutter_callkit_incoming/entities/notification_params.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

/// CallKit Service - Handles native system incoming call UI
/// This service runs in background isolate via FCM data messages
/// MUST be self-contained - NO GetX dependencies (no Get.find())
///
/// Works with flutter_callkit_incoming to display Android system-level
/// incoming call notifications that wake up the app even when closed
class CallKitService {
  static final CallKitService _instance = CallKitService._internal();
  factory CallKitService() => _instance;
  CallKitService._internal();

  // Event controller for UI layer to listen to call events
  final StreamController<CallKitEvent> _eventController =
      StreamController<CallKitEvent>.broadcast();
  Stream<CallKitEvent> get eventStream => _eventController.stream;

  /// Initialize CallKit listeners
  /// Must be called from main.dart after Firebase initialization
  Future<void> initialize() async {
    debugPrint('📞 CallKitService: Initializing...');

    // Listen to CallKit events (accept, decline, end)
    FlutterCallkitIncoming.onEvent.listen(_handleCallKitEvent);

    debugPrint('📞 CallKitService: Initialized');
  }

  /// Show incoming call notification via native system UI
  /// This works even when app is completely closed via FCM data message
  Future<void> showIncomingCall({
    required String callId,
    required String callerId,
    required String callerName,
    required String sdpOffer,
  }) async {
    debugPrint('📞 CallKitService: Showing incoming call from $callerName');

    try {
      // Build CallKit params for Android native notification
      final params = CallKitParams(
        id: callId,
        nameCaller: callerName,
        appName: 'Vant Chat',
        avatar: 'https://i.pravatar.cc/100?u=$callerId', // Placeholder avatar
        handle: callerId,
        type: 0, // 0 = audio call, 1 = video call
        textAccept: 'Accept',
        textDecline: 'Decline',
        duration: 30000, // Ring for 30 seconds
        extra: <String, dynamic>{
          'callerId': callerId,
          'callId': callId,
          'sdpOffer': sdpOffer,
        },
        headers: <String, dynamic>{
          'apiKey': 'Bearer abc',
          'platform': 'flutter',
        },
        missedCallNotification: const NotificationParams(
          showNotification: true,
          isShowCallback: true,
          subtitle: 'Missed call',
          callbackText: 'Call back',
        ),
        callingNotification: const NotificationParams(
          showNotification: true,
          isShowCallback: true,
          subtitle: 'Calling...',
          callbackText: 'Hang Up',
        ),
        android: const AndroidParams(
          isCustomNotification: true,
          isShowLogo: false,
          isShowCallID: false,
          ringtonePath: 'system_ringtone_default',
          backgroundColor: '#0955fa',
          backgroundUrl: 'https://i.pravatar.cc/500',
          actionColor: '#4CAF50',
          textColor: '#ffffff',
          incomingCallNotificationChannelName: 'Incoming Call',
          missedCallNotificationChannelName: 'Missed Call',
        ),
        ios: const IOSParams(
          iconName: 'CallKitLogo',
          handleType: 'generic',
          supportsVideo: false,
          maximumCallGroups: 2,
          maximumCallsPerCallGroup: 1,
          audioSessionMode: 'default',
          audioSessionActive: true,
          audioSessionPreferredSampleRate: 44100.0,
          audioSessionPreferredIOBufferDuration: 0.005,
          supportsDTMF: true,
          supportsHolding: true,
          supportsGrouping: false,
          supportsUngrouping: false,
          ringtonePath: 'system_ringtone_default',
        ),
      );

      // Display native incoming call UI
      await FlutterCallkitIncoming.showCallkitIncoming(params);

      debugPrint('📞 CallKitService: Incoming call UI displayed');
    } catch (e) {
      debugPrint('❌ CallKitService: Error showing incoming call: $e');
    }
  }

  /// Accept call from CallKit UI
  /// Triggers when user taps "Accept" on native incoming call screen
  Future<void> acceptCall(String callId) async {
    debugPrint('📞 CallKitService: Accepting call $callId');

    // acceptCall is not available in this version, use setCallConnected instead
    await FlutterCallkitIncoming.setCallConnected(callId);

    _eventController.add(CallKitEvent(
      type: CallKitEventType.accept,
      callId: callId,
    ));
  }

  /// Decline call from CallKit UI
  /// Triggers when user taps "Decline" on native incoming call screen
  Future<void> declineCall(String callId) async {
    debugPrint('📞 CallKitService: Declining call $callId');

    await FlutterCallkitIncoming.endCall(callId);

    _eventController.add(CallKitEvent(
      type: CallKitEventType.decline,
      callId: callId,
    ));
  }

  /// End active call
  Future<void> endCall(String callId) async {
    debugPrint('📞 CallKitService: Ending call $callId');

    await FlutterCallkitIncoming.endCall(callId);

    _eventController.add(CallKitEvent(
      type: CallKitEventType.end,
      callId: callId,
    ));
  }

  /// Handle CallKit events (accept, decline, end, timeout)
  void _handleCallKitEvent(CallEvent? event) {
    if (event == null) return;

    debugPrint('📞 CallKitService: Event received - ${event.event}');

    switch (event.event) {
      case Event.actionCallIncoming:
        // Incoming call is being shown
        debugPrint('📞 CallKitService: Incoming call showing');
        break;

      case Event.actionCallStart:
        // Started an outgoing call
        debugPrint('📞 CallKitService: Outgoing call started');
        break;

      case Event.actionCallAccept:
        // User accepted the call via native UI
        debugPrint('📞 CallKitService: Call accepted via native UI');
        _eventController.add(CallKitEvent(
          type: CallKitEventType.accept,
          callId: event.body['id'] as String?,
          extra: event.body,
        ));
        break;

      case Event.actionCallDecline:
        // User declined the call via native UI
        debugPrint('📞 CallKitService: Call declined via native UI');
        _eventController.add(CallKitEvent(
          type: CallKitEventType.decline,
          callId: event.body['id'] as String?,
          extra: event.body,
        ));
        break;

      case Event.actionCallEnded:
        // Call ended
        debugPrint('📞 CallKitService: Call ended');
        _eventController.add(CallKitEvent(
          type: CallKitEventType.end,
          callId: event.body['id'] as String?,
        ));
        break;

      case Event.actionCallTimeout:
        // Call timed out (no answer)
        debugPrint('📞 CallKitService: Call timeout');
        _eventController.add(CallKitEvent(
          type: CallKitEventType.timeout,
          callId: event.body['id'] as String?,
        ));
        break;

      case Event.actionCallCallback:
        // User tapped callback from missed call notification
        debugPrint('📞 CallKitService: Callback requested');
        break;

      case Event.actionCallToggleHold:
        // iOS only
        debugPrint('📞 CallKitService: Call toggle hold (iOS)');
        break;

      case Event.actionCallToggleMute:
        // iOS only
        debugPrint('📞 CallKitService: Call toggle mute (iOS)');
        break;

      case Event.actionCallToggleDmtf:
        // iOS only
        debugPrint('📞 CallKitService: Call toggle DMTF (iOS)');
        break;

      case Event.actionCallToggleGroup:
        // iOS only
        debugPrint('📞 CallKitService: Call toggle group (iOS)');
        break;

      case Event.actionCallToggleAudioSession:
        // iOS only
        debugPrint('📞 CallKitService: Call toggle audio session (iOS)');
        break;

      case Event.actionDidUpdateDevicePushTokenVoip:
        // iOS only
        debugPrint('📞 CallKitService: Device push token updated (iOS)');
        break;

      case Event.actionCallCustom:
        // Custom action
        debugPrint('📞 CallKitService: Custom action');
        break;

      default:
        debugPrint('📞 CallKitService: Unhandled event - ${event.event}');
    }
  }

  /// Handle FCM data message in background
  /// This is called from the FCM background handler when app is closed
  /// CRITICAL: Must be self-contained, no GetX dependencies!
  @pragma('vm:entry-point')
  static Future<void> handleBackgroundMessage(RemoteMessage message) async {
    debugPrint('📞 CallKitService.handleBackgroundMessage: Received FCM data');
    debugPrint('📞 Data: ${message.data}');

    try {
      final data = message.data;

      // Validate it's an incoming call message
      if (data['type'] != 'incoming_call') {
        debugPrint('📞 CallKitService: Not an incoming call message, ignoring');
        return;
      }

      final callId = data['callId'];
      final callerId = data['callerId'];
      final callerName = data['callerName'] ?? 'Unknown';
      final sdpOffer = data['sdpOffer'];

      if (callId == null || callerId == null || sdpOffer == null) {
        debugPrint('❌ CallKitService: Missing required call data');
        return;
      }

      // Show native incoming call UI
      // This works even when app is completely closed!
      final service = CallKitService();
      await service.showIncomingCall(
        callId: callId,
        callerId: callerId,
        callerName: callerName,
        sdpOffer: sdpOffer,
      );

      debugPrint('📞 CallKitService: Background call display successful');
    } catch (e) {
      debugPrint('❌ CallKitService: Error handling background message: $e');
    }
  }

  /// Dispose
  void dispose() {
    _eventController.close();
  }
}

/// CallKit event types
enum CallKitEventType {
  accept, // User accepted the call
  decline, // User declined the call
  end, // Call ended
  timeout, // Call timed out (no answer)
  missed, // Missed call
}

/// CallKit event data
class CallKitEvent {
  final CallKitEventType type;
  final String? callId;
  final Map<String, dynamic>? extra;

  CallKitEvent({
    required this.type,
    this.callId,
    this.extra,
  });
}
