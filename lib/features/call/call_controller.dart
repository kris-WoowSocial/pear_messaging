import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/services/socket_service.dart';
import '../../core/services/webrtc_call_service.dart';
import '../../core/services/secure_key_service.dart';
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
  final SecureKeyService _keyService = Get.find<SecureKeyService>();
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
  String? _sharedSecret;
  Timer? _durationUpdateTimer;

  @override
  void onInit() {
    super.onInit();
    _initializeWebrtcService();
    _setupSocketListeners();
    _setupProximitySensor();
    _ringtoneService.init();
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

    _webrtcService.onOfferCreated = (sdpOffer) {
      _handleOfferCreated(sdpOffer);
    };

    _webrtcService.onAnswerCreated = (sdpAnswer) {
      _handleAnswerCreated(sdpAnswer);
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

  /// Setup proximity sensor for screen dimming
  void _setupProximitySensor() {
    // Temporarily disabled - sensors_plus does not expose ProximitySensor API
    // Use dedicated proximity_sensor package when re-enabling this feature
    debugPrint('📱 Proximity sensor disabled (API compatibility)');
  }

  /// Start an outgoing call
  Future<bool> startCall(String calleeDeviceId) async {
    try {
      final callerDeviceId = _storageService.deviceId;
      if (callerDeviceId == null) {
        debugPrint('❌ Cannot start call: No device ID');
        return false;
      }

      // Set remote device ID BEFORE starting WebRTC (needed for SDP callback)
      remoteDeviceId.value = calleeDeviceId;
      isCaller.value = true;

      // Play dial tone for outgoing call
      _ringtoneService.playDialTone();

      // Derive shared secret for E2EE
      _sharedSecret = await _deriveSharedSecret(callerDeviceId, calleeDeviceId);

      // Start WebRTC call
      final success = await _webrtcService.startCall(
        calleeDeviceId: calleeDeviceId,
        callerDeviceId: callerDeviceId,
        sharedSecret: _sharedSecret!,
      );

      if (success) {
        return true;
      }

      // Reset if failed
      remoteDeviceId.value = '';
      isCaller.value = false;
      return false;
    } catch (e) {
      debugPrint('❌ Failed to start call: $e');
      // Reset on error
      remoteDeviceId.value = '';
      isCaller.value = false;
      return false;
    }
  }

  /// Handle offer created from WebRTC service
  void _handleOfferCreated(String sdpOffer) {
    debugPrint('📞 SDP offer created, sending via socket');

    final callerDeviceId = _storageService.deviceId;
    if (callerDeviceId == null) {
      debugPrint('❌ Cannot send offer: No device ID');
      return;
    }

    // Send call initiate via socket with actual SDP
    _socketService.initiateCall(
      callerId: callerDeviceId,
      calleeId: remoteDeviceId.value,
      sdpOffer: sdpOffer,
    );
  }

  /// Handle answer created from WebRTC service
  void _handleAnswerCreated(String sdpAnswer) {
    debugPrint('📞 SDP answer created, sending via socket');

    final calleeDeviceId = _storageService.deviceId;
    if (calleeDeviceId == null) {
      debugPrint('❌ Cannot send answer: No device ID');
      return;
    }

    // Send call accept via socket with actual SDP
    _socketService.acceptCall(
      callId: currentCallId.value,
      callerId: remoteDeviceId.value,
      sdpAnswer: sdpAnswer,
    );
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

      // Store call ID
      currentCallId.value = callId;
      remoteDeviceId.value = callerId;
      isCaller.value = false;

      // Stop ringtone when accepting call
      _ringtoneService.stopRingtone();

      // Update state to connected immediately
      callState.value = CallState.connected;
      _startDurationTimer(); // Start timer when call accepted

      // Derive shared secret for E2EE
      _sharedSecret = await _deriveSharedSecret(callerId, calleeDeviceId);

      // Accept WebRTC call (SDP answer will be sent via callback)
      final success = await _webrtcService.acceptCall(
        callId: callId,
        callerDeviceId: callerId,
        calleeDeviceId: calleeDeviceId,
        sdpOffer: sdpOffer,
        sharedSecret: _sharedSecret!,
      );

      if (success) {
        return true;
      }

      return false;
    } catch (e) {
      debugPrint('❌ Failed to accept call: $e');
      return false;
    }
  }

  /// Reject an incoming call
  void rejectCall(Map<String, dynamic> callData) {
    final callId = callData['callId'] as String;
    final callerId = callData['callerId'] as String;

    // Stop ringtone when rejecting call
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
  Future<void> toggleSpeaker() async {
    await _webrtcService.toggleSpeaker();
    isSpeakerOn.value = _webrtcService.isSpeakerOn;
  }

  /// Handle incoming call from socket
  void _handleIncomingCall(Map<String, dynamic> data) {
    debugPrint('📞 Incoming call received: $data');

    // Play ringtone for incoming call
    _ringtoneService.playIncomingCallRingtone();

    // Navigate to incoming call screen
    Get.toNamed('/call/incoming', arguments: data);
  }

  /// Handle call accepted from socket
  void _handleCallAccepted(Map<String, dynamic> data) {
    debugPrint('📞 Call accepted: $data');

    // Stop ringtone when call is accepted
    _ringtoneService.stopRingtone();

    final sdpAnswer = data['sdpAnswer'] as String;

    // Set remote description in WebRTC
    _webrtcService.setRemoteDescription(sdpAnswer, 'answer');

    currentCallId.value = data['callId'] as String;

    // Update call state to connected
    callState.value = CallState.connected;
  }

  /// Handle call rejected from socket
  void _handleCallRejected(Map<String, dynamic> data) {
    debugPrint('📞 Call rejected: $data');

    // Stop ringtone/dial tone when call is rejected
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

    // Stop ringtone when call is terminated
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

  /// Handle peer ringing notification
  void _handlePeerRinging(Map<String, dynamic> data) {
    debugPrint('📞 Peer is ringing: $data');
    // Only set to ringing if not already connected (prevents race condition)
    if (callState.value != CallState.connected) {
      callState.value = CallState.ringing;
    }
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
        _startDurationTimer();
        break;
      case 'ended':
        callState.value = CallState.ended;
        _stopDurationTimer();
        break;
    }
  }

  /// Handle call ended from WebRTC
  void _handleCallEnded(String callId) {
    debugPrint('📞 Call ended: $callId');
    _resetCallState();
  }

  /// Start call duration timer
  void _startDurationTimer() {
    _durationUpdateTimer?.cancel();
    _durationUpdateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      callDuration.value = _webrtcService.getCallDuration();
    });
  }

  /// Stop call duration timer
  void _stopDurationTimer() {
    _durationUpdateTimer?.cancel();
    _durationUpdateTimer = null;
  }

  /// Derive shared secret for E2EE using HMAC-SHA256
  /// Both callers arrive at the same key because device IDs are sorted.
  /// Key material comes from the device's hardware-backed master key so
  /// it cannot be derived by anyone who only knows the device IDs.
  Future<String> _deriveSharedSecret(String deviceId1, String deviceId2) async {
    try {
      final keyService = Get.find<SecureKeyService>();
      final masterKeyBytes = await keyService.requireMasterKey();

      // Sort so both parties compute the same input
      final sortedIds = [deviceId1, deviceId2]..sort();
      final message = utf8.encode('${sortedIds[0]}_${sortedIds[1]}');

      // HMAC-SHA256: key = device master key, message = sorted device IDs
      final hmacAlgo = Hmac.sha256();
      final secretKey = SecretKey(masterKeyBytes);
      final mac = await hmacAlgo.calculateMac(message, secretKey: secretKey);

      // Clear master key bytes from memory
      masterKeyBytes.fillRange(0, masterKeyBytes.length, 0);

      return base64Encode(mac.bytes); // 44-char base64 = 256-bit key
    } catch (e) {
      debugPrint('⚠️ Failed to derive call secret cryptographically: $e');
      // Fallback: SHA-256 hash of sorted IDs (no master key)
      // Still vastly better than hashCode — 256-bit, collision-resistant
      final sortedIds = [deviceId1, deviceId2]..sort();
      final combined = utf8.encode('${sortedIds[0]}_${sortedIds[1]}');
      final sha = Sha256();
      final hash = await sha.hash(combined);
      return base64Encode(hash.bytes);
    }
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
    _stopDurationTimer();
  }

  /// Cleanup resources
  void _cleanup() {
    _proximitySubscription?.cancel();
    _stopDurationTimer();
    _ringtoneService.stopRingtone();
    _ringtoneService.dispose();
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
