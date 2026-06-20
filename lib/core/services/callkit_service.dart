import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../constants/network_constants.dart';
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/entities/ios_params.dart';
import 'package:flutter_callkit_incoming/entities/notification_params.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// CallKit Service - Handles native system incoming call UI
/// This service runs in background isolate via FCM data messages
/// MUST be self-contained - NO GetX dependencies (no Get.find())
///
/// Works with flutter_callkit_incoming to display Android system-level
/// incoming call notifications that wake up the app even when closed
///
/// TODO: iOS VoIP Push requires manual configuration:
/// 1. Apple Developer account with VoIP Services certificate
/// 2. APNs Authentication Key (.p8) configured in Firebase Console
///    → Project Settings → Cloud Messaging → iOS app configuration
/// 3. App ID with PushKit entitlement enabled in Xcode
/// Without these, iOS background calling will not work even though code is ready.
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
    // Using async/await to handle VoIP token registration
    FlutterCallkitIncoming.onEvent.listen((event) async {
      await _handleCallKitEvent(event);
    });

    debugPrint('📞 CallKitService: Initialized');
  }

  /// Show incoming call notification via native system UI
  /// This works even when app is completely closed via FCM data message
  /// sdpOffer is intentionally NOT stored here — server re-delivers via call_resync
  Future<void> showIncomingCall({
    required String callId,
    required String callerId,
    required String callerName,
  }) async {
    debugPrint('📞 CallKitService: Showing incoming call from $callerName');

    try {
      // Build CallKit params for full-screen incoming call UI
      // avatar: null ensures first letter of name is shown, no random images
      final params = CallKitParams(
        id: callId,
        nameCaller: callerName,
        appName: 'Vant Chat',
        avatar: null,
        handle: callerId,
        type: 0, // 0 = audio call, 1 = video call
        textAccept: 'Accept',
        textDecline: 'Decline',
        duration: 30000, // Ring for 30 seconds
        extra: <String, dynamic>{
          'callerId': callerId,
          'callId': callId,
          // sdpOffer intentionally excluded for security
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
          isShowLogo: true,
          isShowCallID: false,
          ringtonePath: 'system_ringtone_default',
          backgroundColor: '#0955fa',
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

    _eventController.add(
      CallKitEvent(type: CallKitEventType.accept, callId: callId),
    );
  }

  /// Decline call from CallKit UI
  /// Triggers when user taps "Decline" on native incoming call screen
  Future<void> declineCall(String callId) async {
    debugPrint('📞 CallKitService: Declining call $callId');

    await FlutterCallkitIncoming.endCall(callId);

    _eventController.add(
      CallKitEvent(type: CallKitEventType.decline, callId: callId),
    );
  }

  /// End active call
  Future<void> endCall(String callId) async {
    debugPrint('📞 CallKitService: Ending call $callId');

    await FlutterCallkitIncoming.endCall(callId);

    _eventController.add(
      CallKitEvent(type: CallKitEventType.end, callId: callId),
    );
  }

  /// Handle CallKit events (accept, decline, end, timeout)
  Future<void> _handleCallKitEvent(CallEvent? event) async {
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
        _eventController.add(
          CallKitEvent(
            type: CallKitEventType.accept,
            callId: event.body['id'] as String?,
            extra: event.body,
          ),
        );
        break;

      case Event.actionCallDecline:
        // User declined the call via native UI
        debugPrint('📞 CallKitService: Call declined via native UI');
        _eventController.add(
          CallKitEvent(
            type: CallKitEventType.decline,
            callId: event.body['id'] as String?,
            extra: event.body,
          ),
        );
        break;

      case Event.actionCallEnded:
        // Call ended
        debugPrint('📞 CallKitService: Call ended');
        _eventController.add(
          CallKitEvent(
            type: CallKitEventType.end,
            callId: event.body['id'] as String?,
          ),
        );
        break;

      case Event.actionCallTimeout:
        // Call timed out (no answer)
        debugPrint('📞 CallKitService: Call timeout');
        _eventController.add(
          CallKitEvent(
            type: CallKitEventType.timeout,
            callId: event.body['id'] as String?,
          ),
        );
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
        // iOS only - VoIP push token received from PushKit
        final token = event.body['deviceTokenVoIP'] as String?;
        if (token != null && token.isNotEmpty) {
          debugPrint(
            '📞 CallKitService: VoIP push token received: ${token.substring(0, 20)}...',
          );
          await _registerVoipToken(token);
        }
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
      final messageType = data['type'];

      // Handle call_cancelled — dismiss CallKit UI immediately (caller hung up)
      if (messageType == 'call_cancelled') {
        final callId = data['callId'];
        if (callId != null) {
          debugPrint(
            '📞 CallKitService: Call cancelled by caller, dismissing UI for $callId',
          );
          await FlutterCallkitIncoming.endCall(callId);
        }
        return;
      }

      // Handle incoming call
      if (messageType != 'incoming_call') {
        debugPrint('📞 CallKitService: Unhandled FCM type: $messageType');
        return;
      }

      final callId = data['callId'];
      final callerId = data['callerId'];
      final callerName = data['callerName'] ?? 'Unknown';

      if (callId == null || callerId == null) {
        debugPrint('❌ CallKitService: Missing required call data');
        return;
      }

      // Show native incoming call UI — no SDP needed at this stage
      // No avatar URL - plugin will show first letter of name
      final service = CallKitService();
      await service.showIncomingCall(
        callId: callId,
        callerId: callerId,
        callerName: callerName,
      );

      // Listen for accept/decline from the CallKit UI in this background isolate
      FlutterCallkitIncoming.onEvent.listen((CallEvent? event) async {
        if (event == null) return;
        if (event.body['id'] != callId) return;

        if (event.event == Event.actionCallAccept) {
          debugPrint(
            '📞 CallKitService [bg]: User accepted call $callId via native UI',
          );
          await _handleBackgroundAccept(callId);
        } else if (event.event == Event.actionCallDecline) {
          debugPrint(
            '📞 CallKitService [bg]: User declined call $callId via native UI',
          );
          await _handleBackgroundDecline(callId);
        }
      });

      debugPrint('📞 CallKitService: Background call display successful');
    } catch (e) {
      debugPrint('❌ CallKitService: Error handling background message: $e');
    }
  }

  /// Called from background isolate when user taps Accept on CallKit UI
  /// Uses REST (not socket) — reliable in headless isolates
  static Future<void> _handleBackgroundAccept(String callId) async {
    try {
      // Read device ID from SharedPreferences (used for authentication)
      final prefs = await SharedPreferences.getInstance();
      final deviceId = prefs.getString('device_id');

      if (deviceId != null) {
        final success = await _respondToCall(
          callId: callId,
          action: 'accept',
          deviceId: deviceId,
        );
        debugPrint('📞 CallKitService: REST accept result: $success');
      } else {
        debugPrint(
          '⚠️ CallKitService: No device ID in SharedPreferences for REST accept',
        );
      }

      // Store pending accepted call ID so main app handles WebRTC on cold start
      await prefs.setString('pendingAcceptedCallId', callId);
      debugPrint('📞 CallKitService: Stored pendingAcceptedCallId = $callId');
    } catch (e) {
      debugPrint('❌ CallKitService: Error in background accept: $e');
    }
  }

  /// Called from background isolate when user taps Decline on CallKit UI
  static Future<void> _handleBackgroundDecline(String callId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceId = prefs.getString('device_id');

      if (deviceId != null) {
        await _respondToCall(
          callId: callId,
          action: 'reject',
          deviceId: deviceId,
        );
      }

      await FlutterCallkitIncoming.endCall(callId);
      debugPrint('📞 CallKitService: Background decline complete for $callId');
    } catch (e) {
      debugPrint('❌ CallKitService: Error in background decline: $e');
    }
  }

  /// HTTP REST call to notify server of accept/reject (works in headless isolate)
  static Future<bool> _respondToCall({
    required String callId,
    required String action,
    required String deviceId,
  }) async {
    try {
      final uri = Uri.parse(
          '${NetworkConstants.apiBaseUrl}${NetworkConstants.callsRespondPath}/$callId/respond');
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'x-device-id': deviceId,
            },
            body: jsonEncode({'action': action}),
          )
          .timeout(const Duration(seconds: 10));

      debugPrint(
        '📞 CallKitService: REST respond $action → ${response.statusCode}',
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('❌ CallKitService: REST respond failed: $e');
      return false;
    }
  }

  /// Register VoIP push token with backend (iOS PushKit)
  /// Called from initialize() when actionDidUpdateDevicePushTokenVoip fires
  static Future<void> registerVoipToken(String token) async {
    try {
      const secureStorage = FlutterSecureStorage();
      final authToken = await secureStorage.read(key: 'auth_token');
      if (authToken == null) return;

      final uri = Uri.parse(
          '${NetworkConstants.apiBaseUrl}${NetworkConstants.voipTokenPath}');
      await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'x-device-id': authToken,
            },
            body: jsonEncode({'voipToken': token}),
          )
          .timeout(const Duration(seconds: 10));

      debugPrint('📞 CallKitService: VoIP token registered');
    } catch (e) {
      debugPrint('❌ CallKitService: Failed to register VoIP token: $e');
    }
  }

  /// Dismiss CallKit UI for a specific call (e.g. when call_cancelled FCM arrives in foreground)
  static Future<void> dismissCall(String callId) async {
    try {
      await FlutterCallkitIncoming.endCall(callId);
    } catch (e) {
      debugPrint('❌ CallKitService: Failed to dismiss call $callId: $e');
    }
  }

  /// Register iOS VoIP token with backend
  /// Called when PushKit provides a new VoIP push token
  Future<void> _registerVoipToken(String token) async {
    try {
      // Get device ID from secure storage
      const secureStorage = FlutterSecureStorage();
      final deviceId = await secureStorage.read(key: 'device_id');
      if (deviceId == null || deviceId.isEmpty) {
        debugPrint(
          '⚠️ CallKitService: Cannot register VoIP token - no device ID',
        );
        return;
      }

      // Get API base URL from flavor config
      final apiBaseUrl =
          '${NetworkConstants.apiBaseUrl}${NetworkConstants.apiPath}';

      // Register with backend
      final response = await http.post(
        Uri.parse('$apiBaseUrl/devices/voip-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceId': deviceId,
          'voipToken': token,
          'platform': 'ios',
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('📞 CallKitService: VoIP token registered successfully');
      } else {
        debugPrint(
          '⚠️ CallKitService: VoIP token registration failed: ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('❌ CallKitService: Error registering VoIP token: $e');
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

  CallKitEvent({required this.type, this.callId, this.extra});
}
