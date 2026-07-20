import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/services/socket_service.dart';
import '../../core/services/webrtc_call_service.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/services/ringtone_service.dart';
import '../../core/services/username_service.dart';
import '../../core/services/call_history_service.dart';
import '../../core/services/proximity_service.dart';
import '../../core/services/notification_service.dart';
import '../../core/services/call_foreground_service.dart';
import '../../core/services/callkit_service.dart';
import '../../core/services/fcm_service.dart';
import '../../core/utils/string_utils.dart';
import '../../storage/models/call_history_entry.dart';

/// Call State Enum
enum CallState {
  idle,
  dialing, // Server searching for peer
  ringing, // Peer device alerting
  connected,
  ended,
}

/// Call Controller - Manages WebRTC audio call state and UI
class CallController extends GetxController {
  // Services
  final WebRTCCallService _webrtcService = WebRTCCallService();
  final SocketService _socketService = Get.find<SocketService>();
  final LocalStorageService _storageService = Get.find<LocalStorageService>();
  final RingtoneService _ringtoneService = RingtoneService();
  final CallHistoryService _callHistoryService = Get.find<CallHistoryService>();

  // Method channel for Android lock screen dismissal
  static const MethodChannel _callChannel = MethodChannel(
    'com.pear.messaging/call',
  );

  // Method channel for Android incoming call settings (visibility, pending actions)
  static const MethodChannel _incomingCallChannel = MethodChannel(
    'com.vant.chat/incoming_call',
  );

  // Event channel for native -> Flutter incoming call broadcasts
  static const EventChannel _callEventsChannel = EventChannel(
    'com.vant.chat/call_events',
  );

  // Reactive state
  final Rx<CallState> callState = CallState.idle.obs;
  final RxBool isMuted = false.obs;
  final RxBool isSpeakerOn = false.obs;
  final RxString callDuration = '00:00'.obs;
  final RxString remoteDeviceId = ''.obs;
  final RxString remoteDisplayName = ''.obs;
  final RxString currentCallId = ''.obs;
  final RxBool isCaller = false.obs;
  final RxString callerDisplayName = ''.obs;

  // Proximity sensor state - managed by ProximityService
  final RxBool isNearEar = false.obs;

  // Call data
  Timer? _durationUpdateTimer;

  // Buffer for ICE candidates generated before server callId is known (caller only)
  final List<Map<String, dynamic>> _pendingIceCandidates = [];

  // Call history tracking
  DateTime? _callStartTime;
  bool _wasConnected = false;
  int _durationSeconds = 0;

  // Cold-start auto-accept tracking (set when user accepts from CallKit while app killed)
  String? _pendingAutoAcceptCallId;
  bool _isCheckingPendingAutoAccept = false;

  // Latest incoming call data received via socket; used to accept/decline from CallKit/native notification
  // when the custom incoming call screen is already showing.
  Map<String, dynamic>? _latestIncomingCallData;

  // Tracks if user tapped end-call before server assigned a callId; we'll terminate once callId arrives
  bool _pendingEndCall = false;

  // Tracks if the call was accepted from the lock screen (so we relock on call end)
  bool _acceptedFromLockScreen = false;

  // Tracks if the app was launched from killed state for this call (so we close the app on call end)
  bool _launchedForCall = false;

  // Prevents duplicate handling of the same native answer/decline action
  String? _lastHandledNativeCallId;

  // Native call event stream subscription
  StreamSubscription? _callEventSubscription;

  @override
  void onInit() {
    super.onInit();
    debugPrint('📞 CallController onInit called');
    _initializeWebrtcService();
    _setupSocketListeners();

    // If the socket reconnects while we have a pending auto-accept (e.g. cold-start
    // accept where the first resync request failed), send the resync again.
    ever(_socketService.isRegistered, (registered) {
      if (registered && _pendingAutoAcceptCallId != null) {
        final callId = _pendingAutoAcceptCallId!;
        debugPrint(
          '📞 Socket reconnected with pending auto-accept, requesting resync for $callId',
        );
        _socketService.requestCallResync(callId: callId);
      }
    });

    _setupCallKitListener();
    _setupNotificationActionListener();
    _setupNativeCallEventListener();
    _checkPendingCallAction();
    debugPrint(
      '📞 CallController setup complete, checking pending auto-accept',
    );
    _checkPendingAutoAccept();
  }

  /// Check for any pending call action stored by MainActivity when the app was killed
  Future<void> _checkPendingCallAction() async {
    try {
      final result = await _incomingCallChannel.invokeMethod(
        'getPendingCallAction',
      );
      if (result is Map) {
        final action = result['action'] as String?;
        final data = result['data'] as Map?;
        debugPrint('📞 Pending call action found: $action, data: $data');

        if (action == 'com.vant.chat.ANSWER_CALL' && data != null) {
          _handleNativeAnswer(data.cast<String, dynamic>());
        } else if (action == 'com.vant.chat.DECLINE_CALL' && data != null) {
          _handleNativeDecline(data.cast<String, dynamic>());
        }
      }
    } catch (e) {
      debugPrint('⚠️ Failed to check pending call action: $e');
    }
  }

  /// Listen for native broadcasts when the app is in foreground
  void _setupNativeCallEventListener() {
    try {
      _callEventSubscription = _callEventsChannel
          .receiveBroadcastStream()
          .listen(
            (dynamic event) {
              if (event is Map) {
                debugPrint('📞 Native call event received: $event');
                _handleNativeShowFlutterCall(event.cast<String, dynamic>());
              }
            },
            onError: (dynamic error) {
              debugPrint('⚠️ Native call event stream error: $error');
            },
          );
    } catch (e) {
      debugPrint('⚠️ Failed to set up native call event listener: $e');
    }
  }

  void _handleNativeShowFlutterCall(Map<String, dynamic> data) {
    final callId = data['call_id'] as String?;
    if (callId == null || callId.isEmpty) return;

    // Prevent duplicate UI if the call screen is already open
    if (Get.currentRoute == '/call/incoming' ||
        Get.currentRoute == '/call/active') {
      debugPrint('📞 Native call event: call screen already open, skipping');
      return;
    }

    final callData = {
      'callId': callId,
      'callerId': data['caller_id'] ?? '',
      'callerName': data['caller_name'] ?? 'Incoming Call',
      'sdpOffer': null,
      'roomId': data['room_id'] ?? '',
      'avatarUrl': data['avatar_url'] ?? '',
      'isVideo': data['is_video'] == 'true',
    };
    _latestIncomingCallData = callData;
    _setCallScreenVisible(true);
    _showWhenLocked();
    Get.toNamed('/call/incoming', arguments: callData);
  }

  Future<void> _setCallScreenVisible(bool visible) async {
    try {
      await _incomingCallChannel.invokeMethod('setCallScreenVisible', {
        'visible': visible,
      });
    } catch (e) {
      debugPrint('⚠️ Failed to set call screen visibility: $e');
    }
  }

  Future<void> _handleNativeAnswer(Map<String, dynamic> data) async {
    final callId = data['call_id'] as String?;
    if (callId == null || callId.isEmpty) return;

    // Prevent duplicate handling from both the pending-intent path and the
    // CALL_CHANNEL onCallAction path firing on cold start.
    if (_lastHandledNativeCallId == callId) {
      debugPrint(
        '📞 Native answer for $callId already handled, skipping duplicate',
      );
      return;
    }
    _lastHandledNativeCallId = callId;

    _setCallScreenVisible(true);
    await _stopNativeIncomingCall();
    _dismissKeyguard();

    final locked = await _isScreenLocked();
    if (locked) {
      _acceptedFromLockScreen = true;
      _showWhenLocked();
    }

    // Cold-start accept happens before the socket is connected. Wait for it so
    // we can actually send the resync request and accept the call.
    final socketReady = await _waitForSocketConnection();
    if (!socketReady) {
      debugPrint('❌ Cannot accept from native UI: socket not connected');
      _resetCallState();
      Get.snackbar(
        'Call Failed',
        'Could not connect to the server. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 4),
      );
      return;
    }

    final cachedData = _latestIncomingCallData;
    if (cachedData != null &&
        cachedData['callId'] == callId &&
        cachedData['sdpOffer'] != null) {
      debugPrint('📞 Native answer: accepting from cached SDP data');
      _latestIncomingCallData = null;
      _pendingAutoAcceptCallId = null;
      _acceptIncomingCallResync(cachedData);
    } else {
      debugPrint(
        '📞 Native answer: no cached SDP, setting pending auto-accept and requesting resync',
      );
      _latestIncomingCallData = null;
      await setPendingAutoAccept(callId);
      _socketService.requestCallResync(callId: callId);

      // Pre-populate active call info so the user sees the caller immediately.
      currentCallId.value = callId;
      remoteDeviceId.value = data['caller_id'] ?? '';
      isCaller.value = false;
      remoteDisplayName.value = data['caller_name'] ?? 'Incoming Call';

      final callData = {
        'callId': callId,
        'callerId': data['caller_id'] ?? '',
        'callerName': data['caller_name'] ?? 'Incoming Call',
        'sdpOffer': null,
        'roomId': data['room_id'] ?? '',
        'avatarUrl': data['avatar_url'] ?? '',
        'isVideo': data['is_video'] == 'true',
      };
      // Skip the incoming call screen and go straight to the active call UI.
      // The resync will arrive shortly and complete the connection there.
      Get.offNamed('/call/active', arguments: callData);
    }
  }

  Future<void> _handleNativeDecline(Map<String, dynamic> data) async {
    final callId = data['call_id'] as String?;
    if (callId == null || callId.isEmpty) return;

    if (_lastHandledNativeCallId == callId) {
      debugPrint(
        '📞 Native decline for $callId already handled, skipping duplicate',
      );
      return;
    }
    _lastHandledNativeCallId = callId;

    _setCallScreenVisible(false);
    await _stopNativeIncomingCall();
    _latestIncomingCallData = null;
    rejectCall({
      'callId': callId,
      'callerId': data['caller_id'] ?? '',
      'callerName': data['caller_name'] ?? 'Incoming Call',
    });
  }

  Future<void> _stopNativeIncomingCall() async {
    try {
      await _incomingCallChannel.invokeMethod('stopIncomingCall');
    } catch (e) {
      debugPrint('⚠️ Failed to stop native incoming call service: $e');
    }
  }

  /// Wait for the socket to connect, up to [timeout]. Returns true if connected.
  Future<bool> _waitForSocketConnection({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_socketService.isRegistered.value) return true;

    debugPrint('⏳ Waiting for socket registration before resync...');
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      if (_socketService.isRegistered.value) {
        debugPrint('✅ Socket registered, proceeding with resync');
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }

    debugPrint(
      '⚠️ Socket not registered after ${timeout.inSeconds}s, proceeding anyway',
    );
    return false;
  }

  @override
  void onClose() {
    _callEventSubscription?.cancel();
    _callEventSubscription = null;
    // Only cleanup if not in an active call
    // This prevents call from ending when navigating between screens
    if (!isInCall) {
      _cleanup();
    }
    super.onClose();
  }

  /// Initialize WebRTC service
  Future<void> _initializeWebrtcService() async {
    await _webrtcService.initialize();

    // Setup WebRTC callbacks
    _webrtcService.onCallStateChange = (state) {
      _handleCallStateChange(state);
    };

    _webrtcService.onCallEnded = (callId) {
      _handleCallEnded(callId);
    };

    _webrtcService.onIceCandidate = (candidate, sdpMid, sdpMLineIndex) {
      _handleIceCandidate(candidate, sdpMid, sdpMLineIndex);
    };

    _webrtcService.onLocalDescription = (sdp) {
      _handleLocalDescription(sdp);
    };
  }

  /// Setup socket event listeners
  void _setupSocketListeners() {
    _socketService.onIncomingCall = (data) {
      _handleIncomingCall(data);
    };

    _socketService.onCallInitiated = (data) {
      _handleCallInitiated(data);
    };

    _socketService.onCallAccepted = (data) {
      _handleCallAccepted(data);
    };

    _socketService.onCalleeConnecting = (data) {
      _handleCalleeConnecting(data);
    };

    _socketService.onCallRejected = (data) {
      _handleCallRejected(data);
    };

    _socketService.onCallTerminated = (data) {
      _handleCallTerminated(data);
    };

    _socketService.onIceCandidate = (data) {
      _handleRemoteIceCandidate(data);
    };

    _socketService.onPeerRinging = (data) {
      _handlePeerRinging(data);
    };

    _socketService.onCallResync = (data) {
      _handleCallResync(data);
    };
  }

  /// Setup proximity sensor using actual hardware proximity sensor
  /// Turns screen OFF when phone near ear, ON when away
  Future<void> _setupProximitySensor() async {
    try {
      // Start the proper proximity service that uses hardware sensor
      await ProximityService().startListening();
      debugPrint('📱 ProximityService: Started for call');
    } catch (e) {
      debugPrint('❌ Failed to setup proximity sensor: $e');
    }
  }

  /// Stop proximity sensor
  void _stopProximitySensor() {
    try {
      ProximityService().stopListening();
      debugPrint('📱 ProximityService: Stopped');
    } catch (e) {
      debugPrint('❌ Failed to stop proximity sensor: $e');
    }
  }

  /// Setup CallKit event listener for accept/decline from native UI
  void _setupCallKitListener() {
    // Import CallKitService at top of file
    // This listener handles accept/decline when app is in foreground/background
    // Background accept is handled separately in callkit_service.dart
    try {
      final callKitService = CallKitService();
      callKitService.eventStream.listen((event) {
        debugPrint(
          '📞 CallKit event received: ${event.type} for call ${event.callId}',
        );

        switch (event.type) {
          case CallKitEventType.accept:
            _handleCallKitAccept(event.callId, event.extra);
            break;
          case CallKitEventType.decline:
            _handleCallKitDecline(event.callId);
            break;
          case CallKitEventType.end:
            _handleCallKitEnd(event.callId);
            break;
          case CallKitEventType.callback:
            // The plugin emits the same callback event for both the active-call
            // "Hang Up" button and the missed-call "Call back" button. Decide
            // based on whether the call is currently active.
            final callId = event.callId;
            if (callId != null &&
                callId.isNotEmpty &&
                currentCallId.value == callId &&
                callState.value != CallState.idle) {
              debugPrint('📞 CallKit callback: ending active call $callId');
              endCall();
              break;
            }
            final callerId = event.extra?['callerId'] as String?;
            if (callerId != null && callerId.isNotEmpty) {
              debugPrint('📞 CallKit callback: calling back $callerId');
              _callBack(callerId);
            }
            break;
          default:
            break;
        }
      });
      debugPrint('📞 CallKit listener setup complete');
    } catch (e) {
      debugPrint('❌ Failed to setup CallKit listener: $e');
    }
  }

  /// Setup notification action listener for incoming call accept/reject and
  /// missed call "Call back" button/tap
  void _setupNotificationActionListener() {
    try {
      // Listen for call actions from native Android receiver/service
      _callChannel.setMethodCallHandler((call) async {
        if (call.method == 'onCallAction') {
          final action = call.arguments['action'] as String?;
          final callId = call.arguments['callId'] as String?;
          final callerId = call.arguments['callerId'] as String?;
          final callerName = call.arguments['callerName'] as String?;
          final roomId = call.arguments['roomId'] as String?;
          final avatarUrl = call.arguments['avatarUrl'] as String?;
          final isVideo = call.arguments['isVideo'] as bool? ?? false;

          debugPrint('📞 Native call action: $action for call $callId');

          if (action == 'show_incoming_call') {
            // App was launched/killed and service woke it up to show full-screen call UI
            // We don't have SDP yet; show the incoming call screen and wait for socket resync
            if (callId != null && callId.isNotEmpty) {
              debugPrint(
                '📞 Showing incoming call screen from native service launch',
              );
              _setCallScreenVisible(true);
              _showWhenLocked();
              final callData = {
                'callId': callId,
                'callerId': callerId ?? '',
                'callerName': callerName ?? 'Incoming Call',
                'sdpOffer': null,
                'roomId': roomId ?? '',
                'avatarUrl': avatarUrl ?? '',
                'isVideo': isVideo,
              };
              _latestIncomingCallData = callData;
              Get.toNamed('/call/incoming', arguments: callData);
            }
            return;
          }

          if (action == 'answer') {
            await _handleNativeAnswer({
              'call_id': callId ?? '',
              'caller_id': callerId ?? '',
              'caller_name': callerName ?? 'Incoming Call',
              'room_id': roomId ?? '',
              'avatar_url': avatarUrl ?? '',
              'is_video': isVideo ? 'true' : 'false',
            });
          } else if (action == 'decline') {
            await _handleNativeDecline({
              'call_id': callId ?? '',
              'caller_id': callerId ?? '',
              'caller_name': callerName ?? 'Incoming Call',
            });
          }
        }
      });

      NotificationService().onAction.listen((action) async {
        debugPrint(
          '🔔 Notification action: ${action.action} - ${action.payload}',
        );
        final details = action.getCallDetails();
        if (details == null) return;

        final callId = details['callId'];
        if (callId == null || callId.isEmpty) return;

        if (details['type'] == 'missed_call') {
          if (action.action == 'callback' || action.action == 'tap') {
            final callerId = details['callerId'];
            if (callerId != null && callerId.isNotEmpty) {
              debugPrint(
                '📞 Missed call notification action: call back $callerId',
              );
              _callBack(callerId);
            }
          }
          return;
        }

        if (details['type'] == 'ongoing_call') {
          // Ongoing call notification actions
          if (action.action == 'end_call') {
            debugPrint('📞 Notification action: end ongoing call $callId');
            if (currentCallId.value == callId) {
              final wasLaunchedForCall = _launchedForCall;
              endCall();
              // If not a cold-start call, make sure the app goes back to chat list
              // so it doesn't reopen on the stale active call screen later.
              if (!wasLaunchedForCall) {
                final route = Get.currentRoute;
                if (route != '/chat-list' && route != '/main' && route != '/') {
                  Get.offAllNamed('/chat-list');
                }
              }
            }
            return;
          }

          if (action.action == 'return_to_call' || action.action == 'tap') {
            debugPrint(
              '📞 Notification action: return to ongoing call $callId',
            );
            if (isConnected && currentCallId.value == callId) {
              if (Get.currentRoute != '/call/active') {
                Get.offAllNamed('/call/active');
              }
            }
            return;
          }
        }

        if (details['type'] == 'call') {
          // Accept or reject from the local incoming-call notification
          final cachedData = _latestIncomingCallData;
          Map<String, dynamic> callData;

          if (cachedData != null && cachedData['callId'] == callId) {
            // Use cached socket data if available
            callData = cachedData;
          } else {
            // Parse from notification payload if no cached data (socket was disconnected)
            debugPrint(
              '📞 Notification action: parsing from payload for $callId',
            );
            final payload = action.payload;
            if (payload.startsWith('call:')) {
              final parts = payload.split(':');
              if (parts.length >= 4) {
                callData = {
                  'callId': parts[1],
                  'callerId': parts[2],
                  'callerName': parts.sublist(3).join(':'),
                };
                debugPrint('📞 Parsed call data from payload: $callData');
              } else {
                debugPrint('⚠️ Notification action: invalid payload format');
                return;
              }
            } else {
              debugPrint(
                '⚠️ Notification action: no cached data and invalid payload',
              );
              return;
            }
          }

          if (action.action == 'accept') {
            debugPrint('📞 Notification action: accept call $callId');
            final locked = await _isScreenLocked();
            if (locked) {
              // Accepted from lock screen — relock when call ends
              _acceptedFromLockScreen = true;
              _showWhenLocked();
            }
            _latestIncomingCallData = null;
            _pendingAutoAcceptCallId = null;
            _acceptIncomingCallResync(callData);
          } else if (action.action == 'reject') {
            debugPrint('📞 Notification action: reject call $callId');
            _latestIncomingCallData = null;
            rejectCall(callData);
          } else if (action.action == 'tap') {
            // User tapped notification body — open IncomingCallScreen
            debugPrint('📞 Notification tap: opening incoming call screen');
            Get.toNamed('/call/incoming', arguments: callData);
          }
        }
      });
      debugPrint('🔔 Notification action listener setup complete');
    } catch (e) {
      debugPrint('❌ Failed to setup notification action listener: $e');
    }
  }

  /// Handle accept from CallKit UI (app in foreground/background)
  Future<void> _handleCallKitAccept(
    String? callId,
    Map<String, dynamic>? extra,
  ) async {
    if (callId == null || callId.isEmpty) return;
    debugPrint('📞 CallKit accept received for $callId');

    // If device is locked, mark so we relock when the call ends
    final locked = await _isScreenLocked();
    if (locked) {
      _acceptedFromLockScreen = true;
      _showWhenLocked();
    }

    // Dismiss keyguard on Android to allow call to connect without unlock
    _dismissKeyguard();

    // If the socket already delivered the incoming call, accept it immediately
    final cachedData = _latestIncomingCallData;
    if (cachedData != null && cachedData['callId'] == callId) {
      debugPrint('📞 CallKit accept: accepting from cached incoming call data');
      _pendingAutoAcceptCallId = null;
      _acceptIncomingCallResync(cachedData);
      return;
    }

    // Otherwise, we're still waiting for the socket event (e.g. app was killed
    // or in background when the accept happened). Mirror the Android native
    // answer path: persist the auto-accept, request a resync, pre-populate the
    // active call info, and navigate to the active call screen so the user sees
    // the call UI immediately while the SDP offer arrives.
    final callerId = extra?['callerId'] as String? ??
        extra?['caller_id'] as String? ??
        '';
    final callerName = extra?['callerName'] as String? ??
        extra?['caller_name'] as String? ??
        'Incoming Call';
    final roomId = extra?['roomId'] as String? ??
        extra?['room_id'] as String? ??
        '';
    final avatarUrl = extra?['avatarUrl'] as String? ??
        extra?['avatar_url'] as String? ??
        '';
    final isVideo = (extra?['isVideo'] as bool?) ??
        (extra?['is_video'] == true);

    debugPrint(
      '📞 CallKit accept: no cached SDP, setting pending auto-accept and requesting resync',
    );
    await setPendingAutoAccept(callId);
    final deviceId = _storageService.deviceId;
    if (deviceId != null && deviceId.isNotEmpty) {
      unawaited(
        CallKitService.respondToCall(
          callId: callId,
          action: 'accept',
          deviceId: deviceId,
        ),
      );
    }
    if (!_socketService.isRegistered.value) {
      await _socketService.safeReconnect();
    }

    // Wait for the socket so we can request the SDP offer from the server.
    final socketReady = await _waitForSocketConnection();
    if (!socketReady) {
      debugPrint('⚠️ CallKit accept: socket not connected, resync deferred');
    }

    // Pre-populate active call info so the user sees the caller immediately.
    currentCallId.value = callId;
    remoteDeviceId.value = callerId;
    isCaller.value = false;
    remoteDisplayName.value = callerName;

    final callData = {
      'callId': callId,
      'callerId': callerId,
      'callerName': callerName,
      'sdpOffer': null,
      'roomId': roomId,
      'avatarUrl': avatarUrl,
      'isVideo': isVideo,
    };

    // Skip the incoming call screen and go straight to the active call UI.
    // The resync will arrive shortly and complete the connection there.
    Get.offNamed('/call/active', arguments: callData);
  }

  /// Check for pending auto-accept call from background (CallKit accept)
  Future<void> _checkPendingAutoAccept() async {
    if (_isCheckingPendingAutoAccept) {
      debugPrint('📞 Pending auto-accept check already in progress');
      return;
    }

    _isCheckingPendingAutoAccept = true;
    debugPrint('📞 _checkPendingAutoAccept() called');
    try {
      await _checkPendingAutoAcceptWithRetry(maxRetries: 5);
    } finally {
      _isCheckingPendingAutoAccept = false;
    }
  }

  /// Check for pending auto-accept with retry mechanism
  Future<void> _checkPendingAutoAcceptWithRetry({
    required int maxRetries,
  }) async {
    int retryCount = 0;

    while (retryCount < maxRetries) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs
            .reload(); // Force fresh read from disk - bypasses stale cache
        final pendingCallId = prefs.getString('pendingAcceptedCallId');
        debugPrint(
          '📞 _checkPendingAutoAccept (retry $retryCount): pendingCallId = $pendingCallId',
        );

        if (pendingCallId != null && pendingCallId.isNotEmpty) {
          debugPrint('📞 Found pending accepted call: $pendingCallId');

          // If this app instance was launched from killed state for this call,
          // remember it so we can close the app instead of returning to chat list.
          final launchedForCall = prefs.getBool('launchedForCall') ?? false;
          if (launchedForCall) {
            _launchedForCall = true;
            await prefs.remove('launchedForCall');
            debugPrint(
              '📞 Marked call as launched-from-killed; will close app on end',
            );
          }

          // Set auto-accept flag BEFORE requesting resync
          // This ensures when SDP offer arrives, it's auto-accepted
          await setPendingAutoAccept(pendingCallId);
          debugPrint('📞 Set pending auto-accept flag for $pendingCallId');

          final socketReady = await _waitForSocketConnection();

          if (socketReady) {
            debugPrint('📞 Requesting call resync for pending accepted call');
            _socketService.requestCallResync(callId: pendingCallId);

            // Clear the pending call ID
            await prefs.remove('pendingAcceptedCallId');
            debugPrint('📞 Cleared pendingAcceptedCallId');
            return; // Success, exit retry loop
          } else {
            debugPrint('⚠️ Socket not registered, cannot request call resync');
            // Clear auto-accept flag since we can't proceed
            clearPendingAutoAccept();
          }
        } else {
          debugPrint(
            '📞 No pending accepted call found in storage (retry $retryCount)',
          );
        }
      } catch (e) {
        debugPrint(
          '❌ Error checking pending auto-accept (retry $retryCount): $e',
        );
      }

      retryCount++;
      if (retryCount < maxRetries) {
        // Wait before retrying (CallKit accept might still be in progress)
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    debugPrint('📞 _checkPendingAutoAccept: Max retries reached, giving up');
  }

  /// Set pending auto-accept call ID for cold-start resync

  /// Handle decline from CallKit UI (app in foreground/background)
  void _handleCallKitDecline(String? callId) {
    if (callId == null || callId.isEmpty) return;
    debugPrint('📞 CallKit decline received for $callId');

    // Cancel incoming call notification
    NotificationService().cancelNotification(callId.hashCode);

    // Stop ringtone
    _ringtoneService.stopRingtone();

    // If we have the cached incoming call data, use it for a proper rejection.
    final cachedData = _latestIncomingCallData;
    if (cachedData != null && cachedData['callId'] == callId) {
      debugPrint(
        '📞 CallKit decline: rejecting from cached incoming call data',
      );
      _latestIncomingCallData = null;
      rejectCall(cachedData);
      // Dismiss the custom incoming call screen if it's open
      if (Get.currentRoute == '/call/incoming') {
        Get.back();
      }
      return;
    }

    // Fallback: reject via socket if connected
    if (_socketService.isConnected.value) {
      _socketService.rejectCall(
        callId: callId,
        callerId: remoteDeviceId.value,
        reason: 'declined',
      );
    }

    _resetCallState();
  }

  /// Handle end from CallKit UI
  void _handleCallKitEnd(String? callId) {
    if (callId == null ||
        callId.isEmpty ||
        currentCallId.value != callId ||
        callState.value == CallState.idle) {
      debugPrint('📞 Ignoring stale CallKit end event for $callId');
      return;
    }
    debugPrint('📞 CallKit end received for $callId');

    // End the call
    endCall();
  }

  /// Dismiss keyguard on Android to allow call to connect without unlock
  Future<void> _dismissKeyguard() async {
    try {
      await _callChannel.invokeMethod('dismissKeyguard');
      debugPrint('📞 Keyguard dismissed');
    } catch (e) {
      debugPrint('⚠️ Failed to dismiss keyguard: $e');
    }
  }

  /// Start an outgoing call
  Future<bool> startCall(String calleeDeviceId) async {
    try {
      final callerDeviceId = _storageService.deviceId;
      if (callerDeviceId == null) {
        debugPrint('❌ Cannot start call: No device ID');
        return false;
      }

      // Check microphone permission before starting call
      final hasPermission = await _checkMicrophonePermission();
      if (!hasPermission) {
        debugPrint('❌ Cannot start call: Microphone permission denied');
        return false;
      }

      // Store callee ID for when SDP is ready
      remoteDeviceId.value = calleeDeviceId;
      isCaller.value = true;
      _callStartTime = DateTime.now();
      _wasConnected = false;
      _durationSeconds = 0;
      _resolveDisplayName(calleeDeviceId);

      // Resolve caller's own display name to pass to backend
      await _resolveCallerDisplayName();

      // Start WebRTC call - this will trigger onLocalDescription callback
      final success = await _webrtcService.startCall(
        calleeDeviceId: calleeDeviceId,
        callerDeviceId: callerDeviceId,
      );

      if (!success) {
        // Show error if call failed (likely permission issue)
        Get.snackbar(
          'Call Failed',
          'Microphone permission is required for calls. Please enable it in Settings.',
          snackPosition: SnackPosition.BOTTOM,
          colorText: Colors.white,
          duration: const Duration(seconds: 4),
        );
      }

      return success;
    } catch (e) {
      debugPrint('❌ Failed to start call: $e');
      Get.snackbar(
        'Call Failed',
        'Failed to start call. Please check your permissions.',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
      );
      return false;
    }
  }

  /// Call back a missed call (used from missed call notification action)
  void _callBack(String callerId) {
    if (callerId.isEmpty) return;
    debugPrint('📞 Calling back missed call to $callerId');

    // Start the call and navigate to outgoing call screen
    startCall(callerId).then((success) {
      if (success) {
        Get.toNamed('/call/outgoing');
      } else {
        debugPrint('❌ Failed to start call back to $callerId');
        // Error snackbar is already shown in startCall
      }
    });
  }

  /// Accept an incoming call
  Future<bool> acceptCall(Map<String, dynamic> callData) async {
    try {
      final callId = callData['callId'] as String;
      // Cancel incoming call notification (stops vibration/sound from notification)
      // Run without await to avoid blocking call acceptance if notification fails
      NotificationService().cancelNotification(callId.hashCode).catchError((e) {
        debugPrint('⚠️ Failed to cancel notification: $e');
      });

      // Stop ringtone to prevent double ringtone (CallKit + custom)
      _ringtoneService.stopRingtone();

      // Stop the native Android foreground ringing service and cancel the
      // system notification when the user accepts from the Flutter UI.
      _stopNativeIncomingCall();

      final callerId = callData['callerId'] as String;
      final sdpOffer = callData['sdpOffer'] as String;
      final calleeDeviceId = _storageService.deviceId;

      if (calleeDeviceId == null) {
        debugPrint('❌ Cannot accept call: No device ID');
        return false;
      }

      // Check microphone permission before accepting call
      final hasPermission = await _checkMicrophonePermission();
      if (!hasPermission) {
        debugPrint('❌ Cannot accept call: Microphone permission denied');
        _resetCallState();
        return false;
      }

      // Store call info
      currentCallId.value = callId;
      remoteDeviceId.value = callerId;
      isCaller.value = false;
      _resolveDisplayName(callerId);

      // Accept WebRTC call - this will trigger onLocalDescription callback with answer
      final success = await _webrtcService.acceptCall(
        callId: callId,
        callerDeviceId: callerId,
        calleeDeviceId: calleeDeviceId,
        sdpOffer: sdpOffer,
      );

      if (!success) {
        // Show user-friendly error message
        Get.snackbar(
          'Call Failed',
          'Failed to accept call. Please check your permissions.',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 4),
        );
        _resetCallState();
        return false;
      }

      // Update native CallKit UI so it shows the connected call screen
      // Only on Android - iOS CallKit handles state transition automatically
      if (success && !Platform.isIOS) {
        CallKitService().setCallConnected(callId);
      }

      return success;
    } catch (e) {
      debugPrint('❌ Failed to accept call: $e');
      return false;
    }
  }

  /// Reject an incoming call
  void rejectCall(Map<String, dynamic> callData) {
    final callId = callData['callId'] as String;
    final callerId = callData['callerId'] as String;

    // Cancel incoming call notification
    NotificationService().cancelNotification(callId.hashCode);

    // Dismiss native CallKit UI if active
    CallKitService().endCall(callId);

    // Stop the native Android foreground ringing service and cancel the
    // system notification when the user declines from the Flutter UI.
    _stopNativeIncomingCall();

    // Stop ringtone
    _ringtoneService.stopRingtone();

    _socketService.rejectCall(
      callId: callId,
      callerId: callerId,
      reason: 'rejected',
    );

    _resetCallState();
  }

  /// End the current call
  void endCall() {
    // Stop ringtone immediately (covers outgoing beep and incoming ring)
    _ringtoneService.stopRingtone();

    // If server hasn't assigned a callId yet, mark pending end and clean up locally.
    // The terminate request will be sent once call_initiated arrives.
    if (currentCallId.value.isEmpty) {
      if (isCaller.value) {
        debugPrint('📞 No callId yet, marking pending end-call');
        _pendingEndCall = true;
      }
      _logCallHistory(reason: 'ended');
      _webrtcService.endCall();
      _resetCallState();
      return;
    }

    // Clear pending end flag if callId is now available
    _pendingEndCall = false;

    // Log call history before resetting state
    _logCallHistory(reason: 'ended');

    _socketService.terminateCall(callId: currentCallId.value, reason: 'ended');

    // Dismiss CallKit notification if active
    final callKitService = CallKitService();
    callKitService.endCall(currentCallId.value);

    _webrtcService.endCall();
    _resetCallState();
  }

  /// Toggle mute
  void toggleMute() {
    _webrtcService.toggleMute();
    isMuted.value = _webrtcService.isMuted;
  }

  /// Toggle speaker
  Future<void> toggleSpeaker() async {
    await _webrtcService.toggleSpeaker();
    isSpeakerOn.value = _webrtcService.isSpeakerOn;
  }

  void _handleCalleeConnecting(Map<String, dynamic> data) {
    if (!isCaller.value || data['callId'] != currentCallId.value) return;
    debugPrint('📞 Callee accepted and is connecting: ${data['callId']}');
    _ringtoneService.stopRingtone();
  }

  /// Handle call accepted from socket
  void _handleCallAccepted(Map<String, dynamic> data) {
    debugPrint('📞 Call accepted: $data');

    final sdpAnswer = data['sdpAnswer'] as String;
    // Set server-assigned callId
    currentCallId.value = data['callId'] as String;

    // Flush any buffered ICE candidates now that we have the real callId
    if (_pendingIceCandidates.isNotEmpty) {
      debugPrint(
        '📤 Flushing ${_pendingIceCandidates.length} buffered ICE candidates',
      );
      for (final c in _pendingIceCandidates) {
        _socketService.sendIceCandidate(
          callId: currentCallId.value,
          targetDeviceId: remoteDeviceId.value,
          candidate: c['candidate'] as String,
          sdpMid: c['sdpMid'] as String?,
          sdpMLineIndex: c['sdpMLineIndex'] as int?,
        );
      }
      _pendingIceCandidates.clear();
    }

    // Set remote description in WebRTC
    _webrtcService.setRemoteDescription(sdpAnswer, 'answer');
  }

  /// Handle call initiated from server (server-assigned callId for caller)
  void _handleCallInitiated(Map<String, dynamic> data) {
    final callId = data['callId'] as String?;
    final calleeId = data['calleeId'] as String?;

    debugPrint(
      '📞 Call initiated by server: callId=$callId, calleeId=$calleeId',
    );

    if (callId == null || callId.isEmpty) return;

    // Only apply if we are the caller and the callee matches
    if (!isCaller.value || calleeId != remoteDeviceId.value) {
      debugPrint(
        '📞 Ignoring call_initiated - not our call (isCaller=${isCaller.value}, remoteDeviceId=${remoteDeviceId.value})',
      );
      return;
    }

    currentCallId.value = callId;

    // If user tapped end-call before callId arrived, terminate now
    if (_pendingEndCall) {
      _pendingEndCall = false;
      debugPrint('📞 Pending end-call detected, terminating call $callId');
      endCall();
      return;
    }

    // Flush any buffered ICE candidates now that we have the real callId
    if (_pendingIceCandidates.isNotEmpty) {
      debugPrint(
        '📤 Flushing ${_pendingIceCandidates.length} buffered ICE candidates',
      );
      for (final c in _pendingIceCandidates) {
        _socketService.sendIceCandidate(
          callId: currentCallId.value,
          targetDeviceId: remoteDeviceId.value,
          candidate: c['candidate'] as String,
          sdpMid: c['sdpMid'] as String?,
          sdpMLineIndex: c['sdpMLineIndex'] as int?,
        );
      }
      _pendingIceCandidates.clear();
    }
  }

  /// Handle call rejected from socket
  void _handleCallRejected(Map<String, dynamic> data) {
    debugPrint('📞 Call rejected: $data');

    // Stop ringtone
    _ringtoneService.stopRingtone();

    final reason = data['reason'] as String?;

    // Log rejected call
    _logCallHistory(
      reason: 'rejected',
      terminatedBy: data['terminatedBy'] as String?,
    );

    _resetCallState();

    // Navigate back to dismiss the dialing screen
    if (Get.currentRoute != '/chat' && Get.currentRoute != '/') {
      Get.back();
    }

    // Show rejection reason to user
    Get.snackbar(
      'Call Rejected',
      reason ?? 'The call was rejected',
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  /// Handle call terminated from socket
  void _handleCallTerminated(Map<String, dynamic> data) {
    final callId = data['callId'] as String?;
    debugPrint('📞 Call terminated: $data');

    // Only process if this is the current call (ignore if we have a different active call)
    if (callId != null &&
        currentCallId.value.isNotEmpty &&
        callId != currentCallId.value) {
      debugPrint(
        '📞 Ignoring terminated event for different call: $callId vs ${currentCallId.value}',
      );
      return;
    }

    // Stop ringtone
    _ringtoneService.stopRingtone();

    // Cancel incoming call notification if active (prevents stuck notification when caller hangs up)
    if (callId != null && callId.isNotEmpty) {
      NotificationService().cancelNotification(callId.hashCode);
    }

    // Dismiss CallKit notification if active
    final callKitService = CallKitService();
    callKitService.endCall(callId ?? currentCallId.value);

    // Stop the active-call foreground service/notification so it doesn't linger
    try {
      CallForegroundService().stop();
      debugPrint('📞 Call terminated: stopped foreground service');
    } catch (e) {
      debugPrint('⚠️ Call terminated: failed to stop foreground service: $e');
    }

    // Log call history from server-provided reason
    _logCallHistory(
      reason: data['reason'] as String? ?? 'ended',
      terminatedBy: data['terminatedBy'] as String?,
    );

    _webrtcService.endCall();
    _resetCallState();

    // Navigate to chat list to dismiss the incoming/dialing/active call screen
    // Using offAllNamed ensures proper cleanup when app was launched from notification
    final currentRoute = Get.currentRoute;
    if (currentRoute != '/chat-list' &&
        currentRoute != '/main' &&
        currentRoute != '/') {
      Get.offAllNamed('/chat-list');
    }
  }

  /// Handle local ICE candidate from WebRTC
  void _handleIceCandidate(
    String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  ) {
    if (remoteDeviceId.value.isEmpty) return;

    if (currentCallId.value.isEmpty) {
      // Buffer candidates until server callId arrives (caller only)
      debugPrint('📤 Buffering ICE candidate (no callId yet): sdpMid=$sdpMid');
      _pendingIceCandidates.add({
        'candidate': candidate,
        'sdpMid': sdpMid,
        'sdpMLineIndex': sdpMLineIndex,
      });
      return;
    }

    _socketService.sendIceCandidate(
      callId: currentCallId.value,
      targetDeviceId: remoteDeviceId.value,
      candidate: candidate,
      sdpMid: sdpMid,
      sdpMLineIndex: sdpMLineIndex,
    );
    debugPrint('📤 ICE candidate sent to ${remoteDeviceId.value}');
  }

  /// Handle remote ICE candidate from socket
  void _handleRemoteIceCandidate(Map<String, dynamic> data) {
    final candidate = data['candidate'] as String;
    final sdpMid = data['sdpMid'] as String?;
    final sdpMLineIndex = data['sdpMLineIndex'] as int?;

    debugPrint(
      '📞 Remote ICE candidate received - sdpMid: $sdpMid, sdpMLineIndex: $sdpMLineIndex',
    );

    if (sdpMid == null || sdpMLineIndex == null) {
      debugPrint('⚠️ Skipping ICE candidate with null sdpMid or sdpMLineIndex');
      return;
    }

    _webrtcService.addIceCandidate(candidate, sdpMid, sdpMLineIndex);
  }

  /// Handle local SDP description (offer or answer) from WebRTC
  void _handleLocalDescription(String sdp) {
    debugPrint('📞 Local SDP description received, length: ${sdp.length}');

    if (isCaller.value) {
      // Caller: Send SDP offer to callee via socket
      final callerDeviceId = _storageService.deviceId;
      if (callerDeviceId != null) {
        _socketService.initiateCall(
          callerId: callerDeviceId,
          calleeId: remoteDeviceId.value,
          sdpOffer: sdp,
          callerName: callerDisplayName.value.isNotEmpty
              ? callerDisplayName.value
              : null,
        );
        debugPrint(
          '📞 SDP offer sent to socket with callerName: ${callerDisplayName.value}',
        );
      }
    } else {
      // Callee: Send SDP answer to caller via socket
      _socketService.acceptCall(
        callId: currentCallId.value,
        callerId: remoteDeviceId.value,
        sdpAnswer: sdp,
      );
      debugPrint('📞 SDP answer sent to socket');
    }
  }

  /// Handle peer ringing notification
  void _handlePeerRinging(Map<String, dynamic> data) {
    debugPrint('📞 Peer is ringing: $data');
    callState.value = CallState.ringing;
  }

  /// Handle call state change from WebRTC
  void _handleCallStateChange(String state) {
    debugPrint('📞 Call state changed: $state');

    switch (state) {
      case 'dialing':
        callState.value = CallState.dialing;
        if (isCaller.value) {
          _ringtoneService.playOutgoingRingtone();
        }
        break;
      case 'ringing':
        callState.value = CallState.ringing;
        break;
      case 'connected':
        _ringtoneService.stopRingtone();
        callState.value = CallState.connected;
        _wasConnected = true;
        // Start duration update timer to sync with WebRTC service
        _startDurationUpdateTimer();
        // Start proximity sensor for screen off during call
        _setupProximitySensor();
        // Start foreground service to keep call alive when backgrounded
        try {
          CallForegroundService().start();
          debugPrint('📞 Call connected: started foreground service');
        } catch (e) {
          debugPrint(
            '⚠️ Call connected: failed to start foreground service: $e',
          );
        }
        // Show sticky ongoing call notification so user can return or end from notification
        if (currentCallId.value.isNotEmpty) {
          NotificationService().showOngoingCallNotification(
            callId: currentCallId.value,
            callerName: remoteDisplayName.value.isNotEmpty
                ? remoteDisplayName.value
                : 'Unknown',
          );
        }
        // Navigate caller to active call screen (callee navigates from incoming screen)
        if (isCaller.value) {
          Get.offNamed('/call/active');
        }
        break;
      case 'ended':
        _ringtoneService.stopRingtone();
        callState.value = CallState.ended;
        _stopDurationUpdateTimer();
        // Make sure we leave the call screen so the app doesn't get stuck
        // (e.g. after a cold-start accept from a notification)
        if (Get.currentRoute != '/chat-list' &&
            Get.currentRoute != '/main' &&
            Get.currentRoute != '/') {
          Get.offAllNamed('/chat-list');
        }
        break;
    }
  }

  /// Handle call ended from WebRTC
  void _handleCallEnded(String callId) {
    debugPrint('📞 Call ended: $callId');
    // Note: _logCallHistory should already be called by endCall() or _handleCallTerminated()
    // This handler is a fallback for WebRTC-level disconnections
    _resetCallState();

    // Ensure we leave the active call screen so the UI doesn't get stuck
    if (Get.currentRoute != '/chat-list' &&
        Get.currentRoute != '/main' &&
        Get.currentRoute != '/') {
      Get.offAllNamed('/chat-list');
    }
  }

  /// Handle call resync from server - server resends SDP offer after cold-start accept
  void _handleCallResync(Map<String, dynamic> data) {
    final callId = data['callId'] as String?;
    final callerId = data['callerId'] as String?;
    final sdpOffer = data['sdpOffer'] as String?;

    if (callId == null || callerId == null || sdpOffer == null) {
      debugPrint('❌ Invalid call resync data: $data');
      return;
    }

    debugPrint('📞 Call resync received for $callId from $callerId');

    // Store call info
    currentCallId.value = callId;
    remoteDeviceId.value = callerId;
    isCaller.value = false;
    _resolveDisplayName(callerId);

    // Cancel incoming call notification if it exists
    NotificationService().cancelNotification(callId.hashCode);

    // Accept the call with the resent SDP offer
    _webrtcService
        .acceptCall(
          callId: callId,
          callerDeviceId: callerId,
          calleeDeviceId: _storageService.deviceId!,
          sdpOffer: sdpOffer,
        )
        .then((_) {
          debugPrint('📞 WebRTC accept completed after resync');
        });
  }

  /// Start call duration update timer
  void _startDurationUpdateTimer() {
    _durationUpdateTimer?.cancel();
    _durationUpdateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      callDuration.value = _webrtcService.getCallDuration();
      _durationSeconds = timer.tick; // Track duration for history
    });
  }

  /// Stop call duration update timer
  void _stopDurationUpdateTimer() {
    _durationUpdateTimer?.cancel();
    _durationUpdateTimer = null;
  }

  /// Public wrapper — called from IncomingCallScreen before acceptCall
  Future<void> resolveDisplayNamePublic(String deviceId) =>
      _resolveDisplayName(deviceId);

  /// Resolve display name for a device ID (username or @user_ fallback)
  Future<void> _resolveDisplayName(String deviceId) async {
    // First check locally saved contact name (what the user named them in chat)
    final savedChat = _storageService.getChat(deviceId);
    if (savedChat != null &&
        savedChat.userName.isNotEmpty &&
        !savedChat.userName.startsWith('@user_') &&
        savedChat.userName != 'Unknown' &&
        savedChat.userName != deviceId) {
      remoteDisplayName.value = savedChat.userName;
      return;
    }
    // Fall back to friendly name, then server username lookup
    // Skip server username if it equals the raw device ID (default placeholder)
    remoteDisplayName.value = StringUtils.generateFriendlyName(deviceId);
    try {
      final usernameData = await UsernameService.getUsername(deviceId);
      final username = usernameData?.username;
      if (username != null &&
          username.isNotEmpty &&
          username != deviceId &&
          !username.startsWith('@user_')) {
        remoteDisplayName.value = username;
      }
    } catch (_) {}
  }

  /// Resolve caller's own display name to pass to backend for FCM notifications
  Future<void> _resolveCallerDisplayName() async {
    final myDeviceId = _storageService.deviceId;
    if (myDeviceId == null) {
      callerDisplayName.value = 'Unknown';
      return;
    }

    // Get user's own username from storage or server
    // Skip server username if it equals the raw device ID (default placeholder)
    callerDisplayName.value = StringUtils.generateFriendlyName(myDeviceId);
    try {
      final usernameData = await UsernameService.getUsername(myDeviceId);
      final username = usernameData?.username;
      if (username != null &&
          username.isNotEmpty &&
          username != myDeviceId &&
          !username.startsWith('@user_')) {
        callerDisplayName.value = username;
      }
    } catch (_) {}
  }

  /// Reset call state
  void _resetCallState() {
    callState.value = CallState.idle;
    isMuted.value = false;
    isSpeakerOn.value = false;
    callDuration.value = '00:00';
    remoteDeviceId.value = '';
    remoteDisplayName.value = '';
    currentCallId.value = '';
    isCaller.value = false;
    _latestIncomingCallData = null;
    _stopDurationUpdateTimer();
    _stopProximitySensor();
    _setCallScreenVisible(false);
    // Dismiss the sticky ongoing call notification
    try {
      NotificationService().cancelOngoingCallNotification();
      CallForegroundService().stop();
      debugPrint(
        '📞 Reset call state: cancelled ongoing notification and stopped foreground service',
      );
    } catch (e) {
      debugPrint('⚠️ Reset call state: cleanup failed: $e');
    }
    // If the app was launched from killed state for this call, close the app
    // completely when the call ends, like WhatsApp does.
    if (_launchedForCall) {
      _launchedForCall = false;
      _callChannel.invokeMethod('finishAndRemoveTask').catchError((_) {});
      return;
    }

    // If call was accepted from lock screen, background the app and relock
    if (_acceptedFromLockScreen) {
      _acceptedFromLockScreen = false;
      _callChannel.invokeMethod('relockDevice').catchError((_) {});
    } else {
      // Just restore normal power-button lock behaviour
      _callChannel.invokeMethod('clearShowWhenLocked').catchError((_) {});
    }
  }

  /// Cleanup resources
  void _cleanup() {
    _stopProximitySensor();
    _stopDurationUpdateTimer();
    _webrtcService.dispose();
  }

  /// Getters
  bool get isInCall =>
      callState.value != CallState.idle && callState.value != CallState.ended;
  bool get isConnecting =>
      callState.value == CallState.dialing ||
      callState.value == CallState.ringing;
  bool get isConnected => callState.value == CallState.connected;

  /// Log call history entry
  /// Called when call ends - classifies and stores the outcome
  void _logCallHistory({required String reason, String? terminatedBy}) {
    // Skip if no call was started
    if (_callStartTime == null) {
      debugPrint('📞 Skipping call history log - no call start time');
      return;
    }

    // Generate a temporary call ID if server hasn't assigned one yet
    // This happens when caller ends before server responds with call ID
    final callId = currentCallId.value.isNotEmpty
        ? currentCallId.value
        : 'temp_${_callStartTime!.millisecondsSinceEpoch}';

    // Determine call status based on direction and outcome
    CallStatus status;
    if (_wasConnected && _durationSeconds > 0) {
      status = CallStatus.completed;
    } else if (isCaller.value) {
      // Outgoing call that never connected
      if (reason == 'rejected' || reason == 'declined') {
        status = CallStatus.declined;
      } else if (reason == 'no_answer') {
        status = CallStatus.cancelled;
      } else {
        status = CallStatus.cancelled;
      }
    } else {
      // Incoming call that never connected
      if (reason == 'rejected' || terminatedBy == 'callee') {
        status = CallStatus.declined;
      } else {
        status = CallStatus.missed;
      }
    }

    // Create history entry
    final entry = CallHistoryEntry(
      id: callId,
      remoteDeviceId: remoteDeviceId.value,
      remoteName: remoteDisplayName.value.isNotEmpty
          ? remoteDisplayName.value
          : StringUtils.generateFriendlyName(remoteDeviceId.value),
      remoteAvatarUrl: null, // TODO: Get from storage if available
      direction: isCaller.value
          ? CallDirection.outgoing
          : CallDirection.incoming,
      status: status,
      timestamp: _callStartTime!,
      durationSeconds: _wasConnected ? _durationSeconds : 0,
      callType: 'audio',
    );

    // Save to history
    _callHistoryService.addEntry(entry);
    debugPrint(
      '📞 Call logged: ${entry.id} - ${entry.direction} - ${entry.status} - ${entry.durationSeconds}s',
    );

    // Reset tracking
    _callStartTime = null;
    _wasConnected = false;
    _durationSeconds = 0;
  }

  /// Set pending auto-accept flag (used for cold-start after background CallKit accept)
  Future<void> setPendingAutoAccept(String callId) async {
    _pendingAutoAcceptCallId = callId;
    debugPrint('📞 CallController: auto-accept set for $callId');
    // Persist so it survives app restart when user accepts from native notification
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pendingAcceptedCallId', callId);
      await prefs.setBool('launchedForCall', true);
    } catch (e) {
      debugPrint('⚠️ Failed to persist pending auto-accept: $e');
    }
  }

  /// Clear pending auto-accept flag
  Future<void> clearPendingAutoAccept() async {
    _pendingAutoAcceptCallId = null;
    debugPrint('📞 CallController: auto-accept flag cleared');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('pendingAcceptedCallId');
    } catch (e) {
      debugPrint('⚠️ Failed to clear pending auto-accept: $e');
    }
  }

  /// Check for pending auto-accept from SharedPreferences (called on app resume)
  Future<void> setPendingAutoAcceptFromStorage() async {
    await _checkPendingAutoAcceptWithRetry(maxRetries: 5);
  }

  /// Handle incoming call from socket (including resync'd calls after cold-start)
  Future<void> _handleIncomingCall(Map<String, dynamic> data) async {
    debugPrint('📞 Incoming call received: $data');
    final incomingCallId = data['callId'] as String?;

    // Ignore if we're already in an active call with the same call ID
    // This prevents duplicate incoming call screens after successful resync accept
    if (currentCallId.value == incomingCallId && isInCall) {
      debugPrint(
        '📞 Ignoring duplicate incoming call - already in active call: $incomingCallId',
      );
      return;
    }

    // Check if this is a resync'd call that user already accepted from CallKit/native notification
    if (_pendingAutoAcceptCallId != null &&
        _pendingAutoAcceptCallId == incomingCallId) {
      _pendingAutoAcceptCallId = null;
      await clearPendingAutoAccept();
      debugPrint('📞 Auto-accepting resync call: $incomingCallId');
      _acceptIncomingCallResync(data);
      return;
    }

    // Avoid duplicate UI if the incoming call screen is already open
    final currentRoute = Get.currentRoute;
    if (currentRoute == '/call/incoming' || currentRoute == '/call/active') {
      debugPrint(
        '📞 Incoming call screen already open ($currentRoute), skipping',
      );
      return;
    }

    // Normal flow - show incoming call screen with ringtone
    _latestIncomingCallData = data;
    _ringtoneService.playIncomingRingtone();

    // Mark this callId as handled so FCMService dedup guard skips it if FCM
    // arrives shortly after (server sends both socket + FCM in parallel)
    if (incomingCallId != null && incomingCallId.isNotEmpty) {
      FCMService.setLastShownCallId(incomingCallId);
    }

    final screenLocked = await _isScreenLocked();
    final appInBackground = await _isAppInBackground();

    if (appInBackground || screenLocked) {
      // The native FCM service will show the full-screen IncomingCallActivity
      // when the app is in the background, killed, or when the device is locked.
      // Do not show the Flutter UI here to avoid duplicate screens.
      debugPrint(
        '📞 App in background/locked — native FCM service will show call UI',
      );
      return;
    }

    // Foreground and unlocked: show the Flutter incoming call screen.
    _setCallScreenVisible(true);
    Get.toNamed('/call/incoming', arguments: data);
  }

  /// Returns true if the app is in the background (not in the resumed state)
  Future<bool> _isAppInBackground() async {
    try {
      final result = await _callChannel.invokeMethod<bool>('isAppInBackground');
      return result ?? false;
    } catch (e) {
      debugPrint('⚠️ isAppInBackground check failed: $e');
      return false;
    }
  }

  /// Returns true if the device screen is currently locked
  Future<bool> _isScreenLocked() async {
    try {
      final result = await _callChannel.invokeMethod<bool>('isScreenLocked');
      return result ?? false;
    } catch (e) {
      debugPrint('⚠️ isScreenLocked check failed: $e');
      return false;
    }
  }

  /// Ask Android to bring the activity over the lock screen (no unlock required)
  Future<void> _showWhenLocked() async {
    try {
      await _callChannel.invokeMethod('showWhenLocked');
      debugPrint('📞 showWhenLocked triggered for incoming call');
    } catch (e) {
      debugPrint('⚠️ showWhenLocked failed: $e');
    }
  }

  /// Check microphone permission before starting/accepting call
  /// Returns true if granted, false otherwise
  /// Opens Settings on iOS if permanently denied
  Future<bool> _checkMicrophonePermission() async {
    try {
      final status = await Permission.microphone.status;
      debugPrint('🎤 Microphone permission check: $status');

      if (status.isGranted) {
        return true;
      }

      if (status.isPermanentlyDenied) {
        debugPrint(
          '⚠️ Microphone permission permanently denied - opening Settings',
        );
        Get.snackbar(
          'Permission Required',
          'Microphone permission is required for calls. Please enable it in Settings.',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 4),
          mainButton: TextButton(
            onPressed: () async {
              await openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        );
        return false;
      }

      // Request permission if not granted
      debugPrint('🎤 Requesting microphone permission...');
      final result = await Permission.microphone.request();
      debugPrint('🎤 Microphone permission result: $result');

      if (result.isGranted) {
        return true;
      }

      if (result.isPermanentlyDenied) {
        debugPrint('⚠️ Permission permanently denied after request');
        Get.snackbar(
          'Permission Required',
          'Microphone permission is required for calls. Please enable it in Settings.',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 4),
          mainButton: TextButton(
            onPressed: () async {
              await openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        );
      }

      return false;
    } catch (e) {
      debugPrint('❌ Error checking microphone permission: $e');
      return false;
    }
  }

  /// Accept incoming call during resync (app was killed, user accepted from CallKit)
  Future<void> _acceptIncomingCallResync(Map<String, dynamic> data) async {
    try {
      final callId = data['callId'] as String;
      final callerId = data['callerId'] as String;
      final sdpOffer = data['sdpOffer'] as String?;
      final calleeDeviceId = _storageService.deviceId;

      if (calleeDeviceId == null || sdpOffer == null) {
        debugPrint('❌ Cannot resync accept: missing deviceId or sdpOffer');
        return;
      }

      // Check microphone permission before accepting call
      final hasPermission = await _checkMicrophonePermission();
      if (!hasPermission) {
        debugPrint('❌ Cannot resync accept: Microphone permission denied');
        _resetCallState();
        return;
      }

      // Store call info
      currentCallId.value = callId;
      remoteDeviceId.value = callerId;
      isCaller.value = false;
      _callStartTime = DateTime.now(); // Set call start time for history
      _wasConnected = false;
      _durationSeconds = 0;
      await _resolveDisplayName(callerId);

      // Accept WebRTC call directly (no ringing state)
      final success = await _webrtcService.acceptCall(
        callId: callId,
        callerDeviceId: callerId,
        calleeDeviceId: calleeDeviceId,
        sdpOffer: sdpOffer,
      );

      if (success) {
        debugPrint('📞 Resync accept successful, navigating to active call');
        callState.value = CallState.ringing;
        // Clear pending auto-accept since we successfully accepted
        await clearPendingAutoAccept();
        // Update native CallKit UI so it shows the connected call screen
        if (!Platform.isIOS) {
          CallKitService().setCallConnected(callId);
        }
        // Only navigate if not already on the active call screen
        if (Get.currentRoute != '/call/active') {
          Get.offNamed('/call/active');
        }
      } else {
        debugPrint('❌ Resync accept failed');
        _resetCallState();
      }
    } catch (e) {
      debugPrint('❌ Error in _acceptIncomingCallResync: $e');
      _resetCallState();
    }
  }
}
