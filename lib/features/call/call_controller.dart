import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/services/socket_service.dart';
import '../../core/services/webrtc_call_service.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/services/ringtone_service.dart';

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

  // Reactive state
  final Rx<CallState> callState = CallState.idle.obs;
  final RxBool isMuted = false.obs;
  final RxBool isSpeakerOn = false.obs;
  final RxString callDuration = '00:00'.obs;
  final RxString remoteDeviceId = ''.obs;
  final RxString currentCallId = ''.obs;
  final RxBool isCaller = false.obs;

  // Proximity sensor state
  final RxBool isNearEar = false.obs;
  StreamSubscription? _proximitySubscription;

  // Call data
  Timer? _durationUpdateTimer;

  @override
  void onInit() {
    super.onInit();
    _initializeWebrtcService();
    _setupSocketListeners();
    // _setupProximitySensor(); // Disabled for now - API changed
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

      // Accept WebRTC call - this will trigger onLocalDescription callback with answer
      final success = await _webrtcService.acceptCall(
        callId: callId,
        callerDeviceId: callerId,
        calleeDeviceId: calleeDeviceId,
        sdpOffer: sdpOffer,
      );

      if (success) {
        // Notify peer that we're ringing
        _socketService.notifyPeerRinging(callId: callId, callerId: callerId);
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

    _socketService.rejectCall(
      callId: callId,
      callerId: callerId,
      reason: 'rejected',
    );

    _resetCallState();
  }

  /// End the current call
  void endCall() {
    if (currentCallId.value.isNotEmpty) {
      _socketService.terminateCall(
        callId: currentCallId.value,
        reason: 'ended',
      );
    }

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

  /// Handle incoming call from socket
  void _handleIncomingCall(Map<String, dynamic> data) {
    debugPrint('📞 Incoming call received: $data');

    // Play incoming ringtone
    _ringtoneService.playIncomingRingtone();

    // Navigate to incoming call screen
    Get.toNamed('/call/incoming', arguments: data);
  }

  /// Handle call accepted from socket
  void _handleCallAccepted(Map<String, dynamic> data) {
    debugPrint('📞 Call accepted: $data');

    final sdpAnswer = data['sdpAnswer'] as String;

    // Set remote description in WebRTC
    _webrtcService.setRemoteDescription(sdpAnswer, 'answer');

    currentCallId.value = data['callId'] as String;
  }

  /// Handle call rejected from socket
  void _handleCallRejected(Map<String, dynamic> data) {
    debugPrint('📞 Call rejected: $data');

    // Stop ringtone
    _ringtoneService.stopRingtone();

    final reason = data['reason'] as String?;

    // Show rejection reason to user
    Get.snackbar(
      'Call Rejected',
      reason ?? 'The call was rejected',
      snackPosition: SnackPosition.BOTTOM,
    );

    _resetCallState();
  }

  /// Handle call terminated from socket
  void _handleCallTerminated(Map<String, dynamic> data) {
    debugPrint('📞 Call terminated: $data');

    // Stop ringtone
    _ringtoneService.stopRingtone();

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
    if (currentCallId.value.isEmpty) return;

    // CRITICAL FIX: Always send to remoteDeviceId (the other peer)
    // The old buggy code sent callee's candidates to _storageService.deviceId (itself!)
    if (remoteDeviceId.value.isNotEmpty) {
      _socketService.sendIceCandidate(
        callId: currentCallId.value,
        targetDeviceId: remoteDeviceId.value,
        candidate: candidate,
        sdpMid: sdpMid,
        sdpMLineIndex: sdpMLineIndex,
      );
      debugPrint('📤 ICE candidate sent to ${remoteDeviceId.value}');
    }
  }

  /// Handle remote ICE candidate from socket
  void _handleRemoteIceCandidate(Map<String, dynamic> data) {
    final candidate = data['candidate'] as String;
    final sdpMid = data['sdpMid'] as String?;
    final sdpMLineIndex = data['sdpMLineIndex'] as int?;

    debugPrint(
      '📞 Remote ICE candidate received - sdpMid: $sdpMid, sdpMLineIndex: $sdpMLineIndex',
    );

    _webrtcService.addIceCandidate(
      candidate,
      sdpMid ?? '0',
      sdpMLineIndex ?? 0,
    );
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
        );
        debugPrint('📞 SDP offer sent to socket');
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
        break;
      case 'ringing':
        callState.value = CallState.ringing;
        break;
      case 'connected':
        callState.value = CallState.connected;
        // Start duration update timer to sync with WebRTC service
        _startDurationUpdateTimer();
        break;
      case 'ended':
        callState.value = CallState.ended;
        _stopDurationUpdateTimer();
        break;
    }
  }

  /// Handle call ended from WebRTC
  void _handleCallEnded(String callId) {
    debugPrint('📞 Call ended: $callId');
    _resetCallState();
  }

  /// Start call duration update timer
  void _startDurationUpdateTimer() {
    _durationUpdateTimer?.cancel();
    _durationUpdateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      callDuration.value = _webrtcService.getCallDuration();
    });
  }

  /// Stop call duration update timer
  void _stopDurationUpdateTimer() {
    _durationUpdateTimer?.cancel();
    _durationUpdateTimer = null;
  }

  /// Reset call state
  void _resetCallState() {
    callState.value = CallState.idle;
    isMuted.value = false;
    isSpeakerOn.value = false;
    callDuration.value = '00:00';
    remoteDeviceId.value = '';
    currentCallId.value = '';
    isCaller.value = false;
    _stopDurationUpdateTimer();
  }

  /// Cleanup resources
  void _cleanup() {
    _proximitySubscription?.cancel();
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
}
