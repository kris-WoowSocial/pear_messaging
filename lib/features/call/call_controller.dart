import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/services/socket_service.dart';
import '../../core/services/webrtc_call_service.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/services/ringtone_service.dart';
import '../../core/services/username_service.dart';
import '../../core/services/call_history_service.dart';
import '../../core/services/proximity_service.dart';
import '../../core/services/notification_service.dart';
import '../../core/services/callkit_service.dart';
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

  @override
  void onInit() {
    super.onInit();
    _initializeWebrtcService();
    _setupSocketListeners();
    _setupProximitySensor();
    _setupCallKitListener();
  }

  @override
  void onClose() {
    _cleanup();
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

    _socketService.onCallAccepted = (data) {
      _handleCallAccepted(data);
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
  void _setupProximitySensor() {
    try {
      // Start the proper proximity service that uses hardware sensor
      ProximityService().startListening();
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
            _handleCallKitAccept(event.callId);
            break;
          case CallKitEventType.decline:
            _handleCallKitDecline(event.callId);
            break;
          case CallKitEventType.end:
            _handleCallKitEnd(event.callId);
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

  /// Handle accept from CallKit UI (app in foreground/background)
  void _handleCallKitAccept(String? callId) {
    if (callId == null || callId.isEmpty) return;
    debugPrint('📞 CallKit accept received for $callId');

    // Check if we have incoming call data
    // If app is in foreground, we should have received INCOMING_CALL via socket
    // If app was backgrounded, we need to trigger socket accept
    // For now, store the callId and let the socket handler process it
    _pendingAutoAcceptCallId = callId;
  }

  /// Set pending auto-accept call ID for cold-start resync

  /// Handle decline from CallKit UI (app in foreground/background)
  void _handleCallKitDecline(String? callId) {
    if (callId == null || callId.isEmpty) return;
    debugPrint('📞 CallKit decline received for $callId');

    // Cancel incoming call notification
    NotificationService().cancelNotification(callId.hashCode);

    // Reject via socket if connected
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
    if (callId == null || callId.isEmpty) return;
    debugPrint('📞 CallKit end received for $callId');

    // End the call
    endCall();
  }

  /// Start an outgoing call
  Future<bool> startCall(String calleeDeviceId) async {
    try {
      final callerDeviceId = _storageService.deviceId;
      if (callerDeviceId == null) {
        debugPrint('❌ Cannot start call: No device ID');
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

      return success;
    } catch (e) {
      debugPrint('❌ Failed to start call: $e');
      return false;
    }
  }

  /// Accept an incoming call
  Future<bool> acceptCall(Map<String, dynamic> callData) async {
    try {
      final callId = callData['callId'] as String;
      // Cancel incoming call notification (stops vibration/sound from notification)
      await NotificationService().cancelNotification(callId.hashCode);

      // Stop ringtone to prevent double ringtone (CallKit + custom)
      _ringtoneService.stopRingtone();

      final callerId = callData['callerId'] as String;
      final sdpOffer = callData['sdpOffer'] as String;
      final calleeDeviceId = _storageService.deviceId;

      if (calleeDeviceId == null) {
        debugPrint('❌ Cannot accept call: No device ID');
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

    // Log call history before resetting state
    _logCallHistory(reason: 'ended');

    if (currentCallId.value.isNotEmpty) {
      _socketService.terminateCall(
        callId: currentCallId.value,
        reason: 'ended',
      );
    }

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
  void toggleSpeaker() {
    _webrtcService.toggleSpeaker();
    isSpeakerOn.value = _webrtcService.isSpeakerOn;
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

    // Only process if this is the current call
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

    // Log call history from server-provided reason
    _logCallHistory(
      reason: data['reason'] as String? ?? 'ended',
      terminatedBy: data['terminatedBy'] as String?,
    );

    _webrtcService.endCall();
    _resetCallState();

    // Navigate back to chat
    Get.back();
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
        // Navigate caller to active call screen (callee navigates from incoming screen)
        if (isCaller.value) {
          Get.offNamed('/call/active');
        }
        break;
      case 'ended':
        _ringtoneService.stopRingtone();
        callState.value = CallState.ended;
        _stopDurationUpdateTimer();
        break;
    }
  }

  /// Handle call ended from WebRTC
  void _handleCallEnded(String callId) {
    debugPrint('📞 Call ended: $callId');
    // Note: _logCallHistory should already be called by endCall() or _handleCallTerminated()
    // This handler is a fallback for WebRTC-level disconnections
    _resetCallState();
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
        savedChat.userName != 'Unknown') {
      remoteDisplayName.value = savedChat.userName;
      return;
    }
    // Fall back to server username lookup
    remoteDisplayName.value = StringUtils.generateFriendlyName(deviceId);
    try {
      final usernameData = await UsernameService.getUsername(deviceId);
      if (usernameData?.username != null) {
        remoteDisplayName.value = usernameData!.username;
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
    callerDisplayName.value = StringUtils.generateFriendlyName(myDeviceId);
    try {
      final usernameData = await UsernameService.getUsername(myDeviceId);
      if (usernameData?.username != null) {
        callerDisplayName.value = usernameData!.username;
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
    _stopDurationUpdateTimer();
    _stopProximitySensor();
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
    // Skip if no call was started or already logged
    if (_callStartTime == null || currentCallId.value.isEmpty) {
      debugPrint('📞 Skipping call history log - no call data');
      return;
    }

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
      id: currentCallId.value,
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
  void setPendingAutoAccept(String callId) {
    _pendingAutoAcceptCallId = callId;
    debugPrint('📞 CallController: auto-accept set for $callId');
    debugPrint('📞 Set pending auto-accept call ID: $callId');
  }

  /// Handle incoming call from socket (including resync'd calls after cold-start)
  void _handleIncomingCall(Map<String, dynamic> data) {
    debugPrint('📞 Incoming call received: $data');
    final incomingCallId = data['callId'] as String?;

    // Check if this is a resync'd call that user already accepted from CallKit
    if (_pendingAutoAcceptCallId != null &&
        _pendingAutoAcceptCallId == incomingCallId) {
      _pendingAutoAcceptCallId = null;
      debugPrint('📞 Auto-accepting resync call: $incomingCallId');
      _acceptIncomingCallResync(data);
      return;
    }

    // Normal flow - show incoming call screen with ringtone
    _ringtoneService.playIncomingRingtone();
    Get.toNamed('/call/incoming', arguments: data);
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

      // Store call info
      currentCallId.value = callId;
      remoteDeviceId.value = callerId;
      isCaller.value = false;
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
        Get.offNamed('/call/active');
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
