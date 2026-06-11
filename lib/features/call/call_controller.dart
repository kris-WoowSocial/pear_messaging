import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../../core/services/socket_service.dart';
import '../../core/services/webrtc_call_service.dart';
import '../../core/services/secure_key_service.dart';
import '../../core/services/local_storage_service.dart';

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
  StreamSubscription<ProximityEvent>? _proximitySubscription;

  // Call data
  String? _sharedSecret;
  Timer? _durationUpdateTimer;

  @override
  void onInit() {
    super.onInit();
    _initializeWebrtcService();
    _setupSocketListeners();
    _setupProximitySensor();
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
    
    _webrtcService.onIceCandidate = (candidate) {
      _handleIceCandidate(candidate);
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
    _proximitySubscription = proximityEvents.listen((ProximityEvent event) {
      isNearEar.value = event.proximity < 5.0; // Threshold for "near ear"
      debugPrint('📱 Proximity: ${event.proximity}, Near ear: ${isNearEar.value}');
    });
  }

  /// Start an outgoing call
  Future<bool> startCall(String calleeDeviceId) async {
    try {
      final callerDeviceId = _storageService.deviceId;
      if (callerDeviceId == null) {
        debugPrint('❌ Cannot start call: No device ID');
        return false;
      }

      // Derive shared secret for E2EE
      _sharedSecret = await _deriveSharedSecret(callerDeviceId, calleeDeviceId);

      // Start WebRTC call
      final success = await _webrtcService.startCall(
        calleeDeviceId: calleeDeviceId,
        callerDeviceId: callerDeviceId,
        sharedSecret: _sharedSecret!,
      );

      if (success) {
        // Wait for offer to be created
        await Future.delayed(const Duration(milliseconds: 500));
        
        // Get the SDP offer from WebRTC service
        // Note: In actual implementation, you'd get this from the peer connection
        // For now, we'll emit a placeholder - this needs to be integrated with
        // the actual WebRTC offer creation flow
        final sdpOffer = 'sdp_offer_placeholder'; // Replace with actual SDP
        
        // Send call initiate via socket
        _socketService.initiateCall(
          callerId: callerDeviceId,
          calleeId: calleeDeviceId,
          sdpOffer: sdpOffer,
        );
        
        remoteDeviceId.value = calleeDeviceId;
        isCaller.value = true;
        
        return true;
      }
      
      return false;
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

      // Derive shared secret for E2EE
      _sharedSecret = await _deriveSharedSecret(callerId, calleeDeviceId);

      // Accept WebRTC call
      final success = await _webrtcService.acceptCall(
        callId: callId,
        callerDeviceId: callerId,
        calleeDeviceId: calleeDeviceId,
        sdpOffer: sdpOffer,
        sharedSecret: _sharedSecret!,
      );

      if (success) {
        // Wait for answer to be created
        await Future.delayed(const Duration(milliseconds: 500));
        
        // Get the SDP answer from WebRTC service
        final sdpAnswer = 'sdp_answer_placeholder'; // Replace with actual SDP
        
        // Send call accept via socket
        _socketService.acceptCall(
          callId: callId,
          callerId: callerId,
          sdpAnswer: sdpAnswer,
        );
        
        currentCallId.value = callId;
        remoteDeviceId.value = callerId;
        isCaller.value = false;
        
        // Notify peer that we're ringing
        _socketService.notifyPeerRinging(
          callId: callId,
          callerId: callerId,
        );
        
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
    
    _webrtcService.endCall();
    _resetCallState();
    
    // Navigate back to chat
    Get.back();
  }

  /// Handle local ICE candidate from WebRTC
  void _handleIceCandidate(String candidate) {
    if (currentCallId.value.isEmpty) return;
    
    final targetDeviceId = isCaller.value ? remoteDeviceId.value : _storageService.deviceId;
    
    if (targetDeviceId != null) {
      _socketService.sendIceCandidate(
        callId: currentCallId.value,
        targetDeviceId: targetDeviceId,
        candidate: candidate,
      );
    }
  }

  /// Handle remote ICE candidate from socket
  void _handleRemoteIceCandidate(Map<String, dynamic> data) {
    final candidate = data['candidate'] as String;
    final sdpMid = data['sdpMid'] as String?;
    final sdpMLineIndex = data['sdpMLineIndex'] as int?;
    
    _webrtcService.addIceCandidate(
      candidate,
      sdpMid ?? '0',
      sdpMLineIndex ?? 0,
    );
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

  /// Derive shared secret for E2EE
  Future<String> _deriveSharedSecret(String deviceId1, String deviceId2) async {
    // Sort device IDs to ensure both parties derive the same key
    final sortedIds = [deviceId1, deviceId2]..sort();
    final combined = '${sortedIds[0]}_${sortedIds[1]}';
    
    // Use SecureKeyService to derive a shared secret
    // This is a simplified version - in production, use proper key derivation
    final existingKey = await _keyService.getExistingKey();
    return existingKey ?? combined; // Fallback if no existing key
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
    _webrtcService.dispose();
  }

  /// Getters
  bool get isInCall => callState.value != CallState.idle && callState.value != CallState.ended;
  bool get isConnecting => callState.value == CallState.dialing || callState.value == CallState.ringing;
  bool get isConnected => callState.value == CallState.connected;
}
