import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../constants/network_constants.dart';
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/entities/ios_params.dart';
import 'package:flutter_callkit_incoming/entities/notification_params.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'call_breadcrumbs.dart';
import 'callkit_reconciler.dart';
import 'callkit_ghost_events.dart';
import 'package:flutter/services.dart';

/// CallKit Service - Handles native system incoming call UI
/// This service runs in background isolate via FCM data messages
/// MUST be self-contained - NO GetX dependencies (no Get.find())
///
/// Works with flutter_callkit_incoming to display Android system-level
/// incoming call notifications that wake up the app even when closed
///
/// IMPORTANT: CallKit is disabled for China region to comply with MIIT regulations
/// VoIP calling still works, just without native CallKit UI in China
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

  // Check if device is in China region (for CallKit compliance)
  bool _isChinaRegion() {
    try {
      final locale = Platform.localeName.toLowerCase();
      return locale.contains('zh') || locale.contains('cn');
    } catch (e) {
      debugPrint('❌ Error detecting region: $e');
      return false;
    }
  }

  // Check if CallKit should be enabled (disabled in China)
  bool get _isCallKitEnabled => !_isChinaRegion();

  /// APNs environment reported at VoIP token registration.
  /// Prefers the value read by native from the real aps-environment
  /// entitlement; falls back to the build mode if it is not yet available.
  static String _apnsEnvironmentFromPrefs(SharedPreferences prefs) {
    return prefs.getString('apns_environment') ??
        (kReleaseMode ? 'production' : 'sandbox');
  }

  // Event controller for UI layer to listen to call events
  final StreamController<CallKitEvent> _eventController =
      StreamController<CallKitEvent>.broadcast();
  Stream<CallKitEvent> get eventStream => _eventController.stream;

  // Map of callId -> callerId for callback actions from missed call notifications
  static final Map<String, String> _callIdToCallerId = {};

  // Track which calls are currently managed by CallKit to avoid ending non-existent calls
  static final Set<String> _activeCallKitCalls = {};
  // UUIDs with an in-flight FlutterCallkitIncoming.endCall request. Guards
  // against the decline-event path and a manual reject/end racing into a
  // second CXEndCallAction for the same call.
  static final Set<String> _endingCallKitUuids = {};

  // CallKit requires a valid UUID for the call id; our server callIds are not UUIDs.
  // Map callId <-> CallKit UUID so we can pass a valid UUID to the plugin while
  // still referencing calls by server callId everywhere else.
  static final Map<String, String> _callIdToCallKitUuid = {};
  static final Map<String, String> _callKitUuidToCallId = {};

  // Stable namespace for generating a deterministic UUID from a callId.
  static const String _uuidNamespace = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';

  String _getCallKitUuid(String callId) {
    if (_callIdToCallKitUuid.containsKey(callId)) {
      return _callIdToCallKitUuid[callId]!;
    }
    final uuid = const Uuid().v5(_uuidNamespace, callId);
    _callIdToCallKitUuid[callId] = uuid;
    _callKitUuidToCallId[uuid.toLowerCase()] = callId;
    return uuid;
  }

  String? _getCallIdFromUuid(String? uuid) {
    if (uuid == null || uuid.isEmpty) return null;
    return _callKitUuidToCallId[uuid.toLowerCase()];
  }

  /// Extract the server callId from a CallKit event body. The plugin sends
  /// back the UUID we provided as `id`, but the original server callId is
  /// preserved in `extra.callId` for easy lookup.
  String? _extractCallId(Map<dynamic, dynamic> body) {
    final extra = body['extra'] as Map<dynamic, dynamic>?;
    if (extra != null) {
      final fromExtra = extra['callId'] as String?;
      if (fromExtra != null && fromExtra.isNotEmpty) {
        return fromExtra;
      }
    }
    return _getCallIdFromUuid(body['id'] as String?);
  }

  bool _extractIsVideo(Map<dynamic, dynamic> body) {
    bool decode(dynamic value) =>
        value == true || value == 'true' || value == 1;
    final extra = body['extra'];
    if (extra is Map) {
      return decode(extra['isVideo']) || decode(extra['is_video']);
    }
    return decode(body['isVideo']) || decode(body['is_video']);
  }

  /// Initialize CallKit listeners
  /// Must be called from main.dart after Firebase initialization
  Future<void> initialize() async {
    debugPrint('📞 CallKitService: Initializing...');

    // Check if CallKit should be enabled (disabled in China per MIIT regulations)
    if (!_isCallKitEnabled) {
      debugPrint(
        '📞 CallKitService: CallKit disabled for China region - skipping initialization',
      );
      return;
    }

    // Listen to CallKit events (accept, decline, end)
    // Using async/await to handle VoIP token registration
    FlutterCallkitIncoming.onEvent.listen((event) async {
      await _handleCallKitEvent(event);
    });

    // Re-register any existing VoIP token that AppDelegate may have received
    // before Flutter was ready (race condition on first/early launch).
    if (Platform.isIOS) {
      await registerCachedVoipToken();
      await reconcileNativeCalls();
    }

    debugPrint('📞 CallKitService: Initialized');
  }

  /// Re-register the cached PushKit VoIP token with the backend.
  /// flutter_callkit_incoming caches the last token natively, so this can be
  /// called any time: app start, device_id (re)generation, token rotation.
  Future<void> registerCachedVoipToken() async {
    if (!Platform.isIOS) return;
    // Same regional gate as initialize(): registering a token for a
    // CallKit-disabled region would surface CallKit via the native push path.
    if (!_isCallKitEnabled) return;
    try {
      final cachedToken =
          await FlutterCallkitIncoming.getDevicePushTokenVoIP() as String?;
      if (cachedToken != null && cachedToken.isNotEmpty) {
        debugPrint(
          '📞 CallKitService: Registering cached VoIP token: ${cachedToken.substring(0, 10)}...',
        );
        await _registerVoipToken(cachedToken);
      }
    } catch (e) {
      debugPrint(
        '⚠️ CallKitService: Could not re-register cached VoIP token: $e',
      );
    }
  }

  /// Show incoming call notification via native system UI
  /// This works even when app is completely closed via FCM data message
  /// sdpOffer is intentionally NOT stored here — server re-delivers via call_resync
  Future<void> showIncomingCall({
    required String callId,
    required String callerId,
    required String callerName,
    bool isVideo = false,
  }) async {
    debugPrint('📞 CallKitService: Showing incoming call from $callerName');

    // Check if CallKit is enabled (disabled in China per MIIT regulations)
    if (!_isCallKitEnabled) {
      debugPrint(
        '📞 CallKitService: CallKit disabled for China region - using FCM notification instead',
      );
      // In China, rely on FCM notification instead of CallKit
      // The calling functionality still works, just without native CallKit UI
      return;
    }

    try {
      // Store mapping so missed call callback can look up the caller
      _callIdToCallerId[callId] = callerId;

      // CallKit requires a valid UUID as the call id.
      final callKitUuid = _getCallKitUuid(callId);

      // Clear any existing CallKit call to prevent conflicts
      // This fixes the issue where same user calling again shows no notification
      try {
        await FlutterCallkitIncoming.endCall(callKitUuid);
        debugPrint(
          '📞 CallKitService: Cleared existing call before showing new one',
        );
      } catch (e) {
        // Ignore error if no existing call
        debugPrint('📞 CallKitService: No existing call to clear (expected)');
      }

      // Build CallKit params for full-screen incoming call UI
      // Use empty string for avatar to avoid nil crash on iOS (plugin shows first letter)
      final params = buildIncomingCallParams(
        callId: callId,
        callKitUuid: callKitUuid,
        callerId: callerId,
        callerName: callerName,
        isVideo: isVideo,
      );

      // Display native incoming call UI
      await FlutterCallkitIncoming.showCallkitIncoming(params);

      // Track this call as active in CallKit
      _activeCallKitCalls.add(callKitUuid.toLowerCase());

      debugPrint('📞 CallKitService: Incoming call UI displayed');
    } catch (e) {
      debugPrint('❌ CallKitService: Error showing incoming call: $e');
    }
  }

  /// Build the CallKit params for an incoming call.
  /// Extracted so the audio-session choices (mode, sample rate, etc.) are
  /// source-order testable without invoking the native plugin.
  static CallKitParams buildIncomingCallParams({
    required String callId,
    required String callKitUuid,
    required String callerId,
    required String callerName,
    bool isVideo = false,
  }) {
    return CallKitParams(
      id: callKitUuid,
      nameCaller: callerName,
      appName: 'Vant Chat',
      avatar: '',
      handle: callerId,
      type: isVideo ? 1 : 0, // 0 = audio call, 1 = video call
      textAccept: 'Accept',
      textDecline: 'Decline',
      duration: 30000, // Ring for 30 seconds
      extra: <String, dynamic>{
        'callerId': callerId,
        'callId': callId,
        'isVideo': isVideo,
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
        isShowLogo: false, // Hide app logo, show person icon instead
        isShowCallID: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor:
            '#000000', // Black background to match IncomingCallScreen
        actionColor: '#4CAF50', // Green for accept button
        textColor: '#ffffff', // White text
        incomingCallNotificationChannelName: 'Incoming Call',
        missedCallNotificationChannelName: 'Missed Call',
        isShowFullLockedScreen: true, // Wake screen when device is locked
      ),
      ios: IOSParams(
        iconName: '',
        handleType: 'generic',
        supportsVideo: isVideo,
        maximumCallGroups: 2,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: isVideo ? 'videoChat' : 'voiceChat',
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
  }

  /// Accept call from CallKit UI
  /// Triggers when user taps "Accept" on native incoming call screen
  Future<void> acceptCall(String callId) async {
    debugPrint('📞 CallKitService: Accepting call $callId');

    final callKitUuid = _getCallKitUuid(callId);
    // acceptCall is not available in this version, use setCallConnected instead
    await FlutterCallkitIncoming.setCallConnected(callKitUuid);

    _eventController.add(
      CallKitEvent(type: CallKitEventType.accept, callId: callId),
    );
  }

  /// Mark the call as connected in the native CallKit UI without re-emitting the accept event
  Future<void> setCallConnected(String callId) async {
    try {
      debugPrint('📞 CallKitService: Marking call as connected $callId');
      final callKitUuid = _getCallKitUuid(callId);
      await FlutterCallkitIncoming.setCallConnected(callKitUuid);
    } catch (e) {
      debugPrint('⚠️ CallKitService: setCallConnected failed: $e');
    }
  }

  /// Decline call from CallKit UI
  /// Triggers when user taps "Decline" on native incoming call screen
  Future<void> declineCall(String callId) async {
    debugPrint('📞 CallKitService: Declining call $callId');

    final callKitUuid = _getCallKitUuid(callId);
    final activeCallKitUuid = callKitUuid.toLowerCase();
    // Only call endCall if CallKit is actually managing this call and no
    // end is already in flight (decline-event and manual-decline paths can
    // race — a second CXEndCallAction reaches the plugin's force-unwraps).
    if (_activeCallKitCalls.contains(activeCallKitUuid) &&
        _endingCallKitUuids.add(activeCallKitUuid)) {
      try {
        await FlutterCallkitIncoming.endCall(callKitUuid);
        _activeCallKitCalls.remove(activeCallKitUuid);
      } catch (e) {
        debugPrint('⚠️ CallKitService: endCall failed in decline: $e');
        _activeCallKitCalls.remove(activeCallKitUuid);
      } finally {
        _endingCallKitUuids.remove(activeCallKitUuid);
      }
    } else {
      debugPrint(
        '📞 CallKitService: Call not in active tracking, skipping endCall in decline',
      );
    }

    _eventController.add(
      CallKitEvent(type: CallKitEventType.decline, callId: callId),
    );
  }

  /// End active call
  static String Function() liveCallId = () => '';
  static final Set<String> _completedNativeCallIds = {};
  static final Set<String> _silentNativeUuids = {};
  static final ghostEvents = CallKitGhostEvents();
  static final _reconciler = CallKitReconciler(
    activeCalls: () async {
      final records = await FlutterCallkitIncoming.activeCalls();
      return records is List
          ? records.whereType<Map>().map((r) => Map<dynamic, dynamic>.from(r)).toList()
          : [];
    },
    endUuid: (uuid) async {
      _silentNativeUuids.add(uuid.toLowerCase());
      try {
        await const MethodChannel('com.pear.messaging/call')
            .invokeMethod('endOrphanedCallKitCall', {'uuid': uuid});
      } catch (_) {
        _silentNativeUuids.remove(uuid.toLowerCase());
        rethrow;
      }
    },
  );

  Future<void> reconcileNativeCalls({String? completedCallId}) async {
    if (!Platform.isIOS) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _completedNativeCallIds.addAll(
        prefs.getStringList('completed_callkit_call_ids') ?? [],
      );
      await _reconciler.reconcile(
        completedCallIds: _completedNativeCallIds,
        liveCallId: liveCallId,
        completedCallId: completedCallId,
        saveCompleted: (ids) async {
          await prefs.setStringList('completed_callkit_call_ids', ids.toList());
        },
      );
    } catch (e) {
      debugPrint('CallKit reconciliation failed: $e');
    }
  }

  Future<void> endCall(String callId) async {
    if (Platform.isIOS) {
      await reconcileNativeCalls(completedCallId: callId);
      return;
    }
    debugPrint('📞 CallKitService: Ending call $callId');

    final callKitUuid = _getCallKitUuid(callId);
    // Only call endCall if CallKit is actually managing this call and no
    // end is already in flight for it.
    final activeCallKitUuid = callKitUuid.toLowerCase();
    if (_activeCallKitCalls.contains(activeCallKitUuid) &&
        _endingCallKitUuids.add(activeCallKitUuid)) {
      try {
        await FlutterCallkitIncoming.endCall(callKitUuid);
        _activeCallKitCalls.remove(activeCallKitUuid);
        debugPrint('📞 CallKitService: Call removed from active tracking');
      } catch (e) {
        debugPrint(
          '⚠️ CallKitService: endCall failed (call may not exist): $e',
        );
        // Remove from tracking anyway to prevent repeated attempts
        _activeCallKitCalls.remove(activeCallKitUuid);
      } finally {
        _endingCallKitUuids.remove(activeCallKitUuid);
      }
    } else {
      debugPrint(
        '📞 CallKitService: Call not in active CallKit tracking, skipping endCall',
      );
    }

    _eventController.add(
      CallKitEvent(type: CallKitEventType.end, callId: callId),
    );
  }

  /// One-shot consume of a "ghost end" marker: the native foreground path
  /// reports every incoming VoIP push to CallKit (Apple's contract) and then
  /// immediately ends the record. The resulting decline/end event for that
  /// callId must be swallowed — the Flutter socket-driven screen owns the
  /// call and the caller must keep ringing.
  ///
  /// Only the FIRST event for a marked callId is silenced (the marker is
  /// removed on consume): a real decline/end of a different call is never
  /// affected, and a later real end for the same callId (e.g. after the
  /// Flutter screen accepted and CallKit re-engaged) processes normally.
  Future<bool> _consumeSilencedCallKitEvent(String? serverCallId) async {
    if (serverCallId == null || serverCallId.isEmpty) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('silenced_call_ids') ?? '';
      if (raw.isEmpty) return false;
      final ids =
          raw.split(',').where((s) => s.isNotEmpty).toSet();
      if (!ids.remove(serverCallId)) return false;
      await prefs.setString('silenced_call_ids', ids.join(','));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Handle CallKit events (accept, decline, end, timeout)
  @visibleForTesting
  Future<void> replayPluginEvent(CallEvent event) => _handleCallKitEvent(event);

  Future<void> _handleCallKitEvent(CallEvent? event) async {
    if (event == null) return;
    final eventUuid = event.body['id']?.toString().toLowerCase();
    if (ghostEvents.suppress(eventUuid)) {
      _activeCallKitCalls.remove(eventUuid);
      debugPrint('CallKitService: silenced ghost event ${event.event}');
      return;
    }
    if ((event.event == Event.actionCallEnded ||
            event.event == Event.actionCallDecline) &&
        eventUuid != null && _silentNativeUuids.remove(eventUuid)) {
      _activeCallKitCalls.remove(eventUuid);
      return;
    }

    debugPrint('📞 CallKitService: Event received - ${event.event}');

    switch (event.event) {
      case Event.actionCallIncoming:
        // CallKit UI is showing — proves the VoIP push was received and
        // reportNewIncomingCall completed (iOS requires it synchronously).
        debugPrint('📞 CallKitService: Incoming call showing');
        logCallBreadcrumb(CallBreadcrumb.pushkitReceived);
        logCallBreadcrumb(CallBreadcrumb.callkitReportDone);
        final incomingId = event.body['id'] as String?;
        if (incomingId != null) {
          _activeCallKitCalls.add(incomingId.toLowerCase());
        }
        break;

      case Event.actionCallStart:
        // Started an outgoing call
        debugPrint('📞 CallKitService: Outgoing call started');
        break;

      case Event.actionCallAccept:
        // User accepted the call via native UI
        debugPrint('📞 CallKitService: Call accepted via native UI');
        logCallBreadcrumb(CallBreadcrumb.accept);
        final acceptedCallId = _extractCallId(event.body);

        // iOS cold-start safety: when the app is launched from a killed state by
        // PushKit/CallKit, the onEvent stream may fire before CallController is
        // registered. Persist the accepted call so _checkPendingAutoAccept can
        // request the SDP resync and complete the call setup.
        if (acceptedCallId != null && acceptedCallId.isNotEmpty) {
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('pendingAcceptedCallId', acceptedCallId);
            await prefs.setBool(
              'pendingAcceptedCallIsVideo',
              _extractIsVideo(event.body),
            );
            await prefs.setBool('launchedForCall', true);
            debugPrint(
              '📞 CallKitService: persisted iOS accept for cold-start: $acceptedCallId',
            );
          } catch (e) {
            debugPrint('⚠️ CallKitService: failed to persist iOS accept: $e');
          }
        }

        _eventController.add(
          CallKitEvent(
            type: CallKitEventType.accept,
            callId: acceptedCallId,
            extra: event.body,
          ),
        );
        break;

      case Event.actionCallDecline:
        if (await _consumeSilencedCallKitEvent(_extractCallId(event.body))) {
          debugPrint(
            '📞 CallKitService: silenced ghost decline — foreground push reported for compliance, caller keeps ringing',
          );
          break;
        }
        // User declined the call via native UI
        debugPrint('📞 CallKitService: Call declined via native UI');
        logCallBreadcrumb(CallBreadcrumb.decline);
        // The call is already ended natively — drop it from active tracking
        // NOW so the downstream rejectCall() -> CallKitService.endCall() is
        // skipped. Without this we request a second CXEndCallAction through
        // the plugin, which reads self.data! and UUID(uuidString:)! on the
        // isFromPushKit path — both fatal force-unwraps in edge states.
        final declinedUuid = event.body['id'] as String?;
        if (declinedUuid != null) {
          _activeCallKitCalls.remove(declinedUuid.toLowerCase());
        }
        _eventController.add(
          CallKitEvent(
            type: CallKitEventType.decline,
            callId: _extractCallId(event.body),
            extra: event.body,
          ),
        );
        break;

      case Event.actionCallEnded:
        if (await _consumeSilencedCallKitEvent(_extractCallId(event.body))) {
          debugPrint(
            '📞 CallKitService: silenced ghost end — no caller-facing signal, Flutter screen untouched',
          );
          break;
        }
        // Call ended
        debugPrint('📞 CallKitService: Call ended');
        logCallBreadcrumb(CallBreadcrumb.ended);
        final uuid = event.body['id'] as String?;
        if (uuid != null) {
          _activeCallKitCalls.remove(uuid.toLowerCase());
        }
        _eventController.add(
          CallKitEvent(type: CallKitEventType.end, callId: _extractCallId(event.body)),
        );
        break;

      case Event.actionCallTimeout:
        // Call timed out (no answer)
        debugPrint('📞 CallKitService: Call timeout');
        final uuid = event.body['id'] as String?;
        if (uuid != null) {
          _activeCallKitCalls.remove(uuid.toLowerCase());
        }
        _eventController.add(
          CallKitEvent(type: CallKitEventType.timeout, callId: _extractCallId(event.body)),
        );
        break;

      case Event.actionCallCallback:
        // User tapped callback from missed call notification
        final callId = _extractCallId(event.body);
        // Try to get callerId from the event body (handle/extra) or fallback map
        var callerId = event.body['handle'] as String?;
        final extra = event.body['extra'] as Map<dynamic, dynamic>?;
        if ((callerId == null || callerId.isEmpty) && extra != null) {
          callerId = extra['callerId'] as String?;
        }
        if (callerId == null || callerId.isEmpty) {
          callerId = callId != null ? _callIdToCallerId[callId] : null;
        }
        debugPrint(
          '📞 CallKitService: Callback requested for callId=$callId callerId=$callerId',
        );
        if (callerId != null && callerId.isNotEmpty) {
          _eventController.add(
            CallKitEvent(
              type: CallKitEventType.callback,
              callId: callId,
              extra: {'callerId': callerId},
            ),
          );
        }
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

      // Handle call_cancelled — FCM fallback for Android when caller hangs up
      // On iOS the VoIP push is handled directly by AppDelegate, so skip here.
      if (messageType == 'call_cancelled') {
        if (!Platform.isIOS) {
          final callId = data['callId'];
          if (callId != null) {
            debugPrint(
              '📞 CallKitService: Call cancelled by caller, dismissing UI for $callId',
            );
            try {
              final service = CallKitService();
              final callKitUuid = service._getCallKitUuid(callId);
              await FlutterCallkitIncoming.endCall(callKitUuid);
            } catch (e) {
              debugPrint('⚠️ CallKitService: endCall failed in background: $e');
            }
          }
        }
        return;
      }

      // On iOS, incoming_call is delivered via PushKit VoIP push → AppDelegate
      // which calls showCallkitIncoming(fromPushKit: true) directly.
      // Processing it here again would create a duplicate CallKit UI, so we skip.
      if (Platform.isIOS && messageType == 'incoming_call') {
        debugPrint(
          '📞 CallKitService: Skipping FCM incoming_call on iOS — handled by PushKit/AppDelegate',
        );
        return;
      }

      if (messageType != 'incoming_call') {
        debugPrint('📞 CallKitService: Unhandled FCM type: $messageType');
        return;
      }

      final callId = data['callId'];
      final callerId = data['callerId'];
      final callerName = data['callerName'] ?? 'Unknown';
      final isVideo = data['isVideo'] == 'true' || data['is_video'] == 'true';

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
        isVideo: isVideo,
      );

      // Listen for accept/decline from the CallKit UI in this background isolate
      FlutterCallkitIncoming.onEvent.listen((CallEvent? event) async {
        if (event == null) return;
        final eventCallId = CallKitService()._extractCallId(event.body);
        if (eventCallId != callId) return;

        if (event.event == Event.actionCallAccept) {
          debugPrint(
            '📞 CallKitService [bg]: User accepted call $callId via native UI',
          );
          await _handleBackgroundAccept(
            callId,
            isVideo: CallKitService()._extractIsVideo(event.body),
          );
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
  static Future<void> _handleBackgroundAccept(
    String callId, {
    bool isVideo = false,
  }) async {
    try {
      // Read device ID from SharedPreferences (used for authentication)
      final prefs = await SharedPreferences.getInstance();
      final deviceId = prefs.getString('device_id');

      if (deviceId != null) {
        final success = await respondToCall(
          callId: callId,
          action: 'accept',
          deviceId: deviceId,
        );
        debugPrint('📞 CallKitService: REST accept result: $success');

        // Only store pending accepted call ID if REST accept succeeded
        if (success) {
          await prefs.setString('pendingAcceptedCallId', callId);
          await prefs.setBool('pendingAcceptedCallIsVideo', isVideo);
          await prefs.setBool('launchedForCall', true);
          debugPrint(
            '📞 CallKitService: Stored pendingAcceptedCallId = $callId (launchedForCall=true)',
          );
        } else {
          debugPrint(
            '⚠️ CallKitService: REST accept failed, not storing pending call ID',
          );
        }
      } else {
        debugPrint(
          '⚠️ CallKitService: No device ID in SharedPreferences for REST accept',
        );
      }
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
        await respondToCall(
          callId: callId,
          action: 'reject',
          deviceId: deviceId,
        );
      }

      try {
        final service = CallKitService();
        final callKitUuid = service._getCallKitUuid(callId);
        await FlutterCallkitIncoming.endCall(callKitUuid);
      } catch (e) {
        debugPrint(
          '⚠️ CallKitService: endCall failed in background decline: $e',
        );
      }
      debugPrint('📞 CallKitService: Background decline complete for $callId');
    } catch (e) {
      debugPrint('❌ CallKitService: Error in background decline: $e');
    }
  }

  /// HTTP REST call to notify server of accept/reject (works in headless isolate)
  static Future<bool> respondToCall({
    required String callId,
    required String action,
    required String deviceId,
  }) async {
    try {
      final uri = Uri.parse(
        '${NetworkConstants.apiBaseUrl}${NetworkConstants.callsRespondPath}/$callId/respond',
      );
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
  /// Static variant used when no instance context is available
  static Future<void> registerVoipToken(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceId = prefs.getString('device_id');
      if (deviceId == null || deviceId.isEmpty) return;

      final apnsEnvironment = _apnsEnvironmentFromPrefs(prefs);

      final uri = Uri.parse(
        '${NetworkConstants.apiBaseUrl}${NetworkConstants.voipTokenPath}',
      );
      await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'deviceId': deviceId,
              'voipToken': token,
              'platform': 'ios',
              'apnsEnvironment': apnsEnvironment,
            }),
          )
          .timeout(const Duration(seconds: 10));

      debugPrint('📞 CallKitService: VoIP token registered (static)');
    } catch (e) {
      debugPrint('❌ CallKitService: Failed to register VoIP token: $e');
    }
  }

  /// Dismiss CallKit UI for a specific call (e.g. when call_cancelled FCM arrives in foreground)
  static Future<void> dismissCall(String callId) async {
    final service = CallKitService();
    final callKitUuid = service._getCallKitUuid(callId);
    if (_activeCallKitCalls.contains(callKitUuid)) {
      try {
        await FlutterCallkitIncoming.endCall(callKitUuid);
        _activeCallKitCalls.remove(callKitUuid);
      } catch (e) {
        debugPrint(
          '⚠️ CallKitService: Failed to dismiss call $callId (may not exist): $e',
        );
        _activeCallKitCalls.remove(callKitUuid);
      }
    } else {
      debugPrint(
        '📞 CallKitService: Call not in active tracking, skipping dismissCall',
      );
    }
  }

  /// Register iOS VoIP token with backend.
  /// Called when PushKit provides a new VoIP push token, on every app start,
  /// and after device_id (re)generation. Retries with backoff — a single
  /// failed POST must not leave the server with no/stale token until the
  /// next launch.
  Future<void> _registerVoipToken(String token, {int maxAttempts = 4}) async {
    String? appVersion;
    String? appBuild;
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = info.version;
      appBuild = info.buildNumber;
    } catch (_) {
      appVersion = '';
      appBuild = '';
    }

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future.delayed(Duration(seconds: attempt == 1 ? 2 : 5));
      }
      try {
        // device_id is stored in SharedPreferences (same as the rest of this
        // service); it may not be written yet on a cold first launch.
        final prefs = await SharedPreferences.getInstance();
        final deviceId = prefs.getString('device_id');
        if (deviceId == null || deviceId.isEmpty) {
          debugPrint(
            '⚠️ CallKitService: device_id not ready yet '
            '(attempt ${attempt + 1}/$maxAttempts)',
          );
          continue;
        }

        // NetworkConstants.voipTokenPath is already '/api/devices/voip-token'
        // so just prepend the base URL — do NOT add apiPath here (avoids double /api)
        final uri = Uri.parse(
          '${NetworkConstants.apiBaseUrl}${NetworkConstants.voipTokenPath}',
        );

        final apnsEnvironment = _apnsEnvironmentFromPrefs(prefs);

        final response = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'deviceId': deviceId,
            'voipToken': token,
            'platform': 'ios',
            'apnsEnvironment': apnsEnvironment,
            'appVersion': appVersion,
            'appBuild': appBuild,
          }),
        );

        if (response.statusCode == 200) {
          debugPrint(
            '📞 CallKitService: VoIP token registered successfully for device $deviceId',
          );
          return;
        }
        debugPrint(
          '⚠️ CallKitService: VoIP token registration failed '
          '(attempt ${attempt + 1}/$maxAttempts): '
          '${response.statusCode} body=${response.body}',
        );
      } catch (e) {
        debugPrint(
          '❌ CallKitService: Error registering VoIP token '
          '(attempt ${attempt + 1}/$maxAttempts): $e',
        );
      }
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
  callback, // User tapped call back from missed call notification
}

/// CallKit event data
class CallKitEvent {
  final CallKitEventType type;
  final String? callId;
  final Map<String, dynamic>? extra;

  CallKitEvent({required this.type, this.callId, this.extra});
}
