import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

/// WebRTC Call Service - Manages peer-to-peer audio calls
/// Note: E2EE with FrameCryptor requires flutter_webrtc 1.0.0+
/// Current implementation uses standard WebRTC with DTLS-SRTP encryption
class WebRTCCallService {
  static final WebRTCCallService _instance = WebRTCCallService._internal();
  factory WebRTCCallService() => _instance;
  WebRTCCallService._internal();

  // Peer connection
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  // Call state
  String? _currentCallId;
  String? _localDeviceId;
  String? _remoteDeviceId;
  bool _isCaller = false;
  bool _isMuted = false;
  bool _isSpeakerOn = false;

  // Call duration
  Timer? _durationTimer;
  int _callDurationSeconds = 0;

  // Stats timer for diagnostics (logs bytes sent/received)
  Timer? _statsTimer;

  // Callbacks
  Function(MediaStream)? onLocalStream;
  Function(MediaStream)? onRemoteStream;
  Function(String)? onCallEnded;
  Function(String candidate, String? sdpMid, int? sdpMLineIndex)?
  onIceCandidate;
  Function(String)? onCallStateChange;
  Function(String)? onOfferCreated;
  Function(String)? onAnswerCreated;

  // ICE servers configuration
  final List<Map<String, dynamic>> _iceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
  ];

  // TURN server configuration (will be loaded from environment)
  Map<String, dynamic>? _turnServer;

  /// Initialize the call service
  Future<void> initialize() async {
    debugPrint('📞 WebRTCCallService initialized');

    // Load TURN server configuration from backend
    await _loadTurnServerConfig();

    // Configure audio session for calls
    await _configureAudioSession();
  }

  /// Configure audio session for proper call audio routing
  Future<void> _configureAudioSession() async {
    try {
      // Configure audio for voice communication
      await Helper.setSpeakerphoneOn(false); // Default to earpiece
      debugPrint('📞 Audio session configured for voice calls');
    } catch (e) {
      debugPrint('⚠️ Failed to configure audio session: $e');
    }
  }

  /// Load TURN server configuration from backend
  Future<void> _loadTurnServerConfig() async {
    try {
      // For now, use hardcoded values from .env
      // In production, fetch from backend API
      _turnServer = {
        'urls': 'turn:54.175.143.63:3478',
        'username': 'vantchat',
        'credential': 'Y9FA4x5PA2WDAMwBWfVClL5R7VyH8/BfRql9jTBNg54=',
      };

      if (_turnServer != null) {
        _iceServers.add(_turnServer!);
        debugPrint('📞 TURN server configured');
      }
    } catch (e) {
      debugPrint('⚠️ Failed to load TURN server config: $e');
    }
  }

  /// Start an outgoing call
  Future<bool> startCall({
    required String calleeDeviceId,
    required String callerDeviceId,
    required String sharedSecret,
  }) async {
    try {
      _localDeviceId = callerDeviceId;
      _remoteDeviceId = calleeDeviceId;
      _isCaller = true;
      _currentCallId = 'call_${DateTime.now().millisecondsSinceEpoch}';

      debugPrint('📞 Starting call to $calleeDeviceId');

      // Request microphone permission
      final hasPermission = await _requestMicrophonePermission();
      if (!hasPermission) {
        debugPrint('❌ Microphone permission denied');
        return false;
      }

      // Create peer connection
      await _createPeerConnection();

      // Get local audio stream with hardware optimization
      _localStream = await _getUserMedia();
      if (_localStream == null) {
        debugPrint('❌ Failed to get local stream');
        return false;
      }

      onLocalStream?.call(_localStream!);

      // Add local stream to peer connection
      // CRITICAL FIX: Use for loop instead of forEach - forEach doesn't await async callbacks
      // Without this fix, createOffer runs before tracks are attached, causing silence
      for (final track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      // Verify tracks were added before creating offer
      final sendersBeforeOffer = await _peerConnection!.getSenders();
      debugPrint(
        '📞 Active senders before createOffer: ${sendersBeforeOffer.length}',
      );

      // Create audio-only offer
      final offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      await _peerConnection!.setLocalDescription(offer);

      onCallStateChange?.call('dialing');

      // Send the SDP offer via callback
      onOfferCreated?.call(offer.sdp ?? '');

      debugPrint('📞 Offer created, sending via signaling');
      return true;
    } catch (e) {
      debugPrint('❌ Failed to start call: $e');
      return false;
    }
  }

  /// Accept an incoming call
  Future<bool> acceptCall({
    required String callId,
    required String callerDeviceId,
    required String calleeDeviceId,
    required String sdpOffer,
    required String sharedSecret,
  }) async {
    try {
      _currentCallId = callId;
      _localDeviceId = calleeDeviceId;
      _remoteDeviceId = callerDeviceId;
      _isCaller = false;

      debugPrint('📞 Accepting call from $callerDeviceId');

      // Request microphone permission
      final hasPermission = await _requestMicrophonePermission();
      if (!hasPermission) {
        debugPrint('❌ Microphone permission denied');
        return false;
      }

      // Create peer connection
      await _createPeerConnection();

      // Get local audio stream with hardware optimization
      _localStream = await _getUserMedia();
      if (_localStream == null) {
        debugPrint('❌ Failed to get local stream');
        return false;
      }

      onLocalStream?.call(_localStream!);

      // Add local stream to peer connection
      // CRITICAL FIX: Use for loop instead of forEach - forEach doesn't await async callbacks
      for (final track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      // Verify tracks were added before creating answer
      final sendersBeforeAnswer = await _peerConnection!.getSenders();
      debugPrint(
        '📞 Active senders before createAnswer: ${sendersBeforeAnswer.length}',
      );

      // Set remote description (offer)
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdpOffer, 'offer'),
      );

      // Create audio-only answer
      final answer = await _peerConnection!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      await _peerConnection!.setLocalDescription(answer);

      // Send the SDP answer via callback
      onAnswerCreated?.call(answer.sdp ?? '');

      debugPrint('📞 Answer created, sending via signaling');
      return true;
    } catch (e) {
      debugPrint('❌ Failed to accept call: $e');
      return false;
    }
  }

  /// Create peer connection with ICE servers
  Future<void> _createPeerConnection() async {
    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': 'turn:54.175.143.63:3478',
          'username': 'vantchat',
          'credential': 'Y9FA4x5PA2WDAMwBWfVClL5R7VyH8/BfRql9jTBNg54=',
        },
      ],
      'sdpSemantics': 'unified-plan',
    };

    _peerConnection = await createPeerConnection(configuration);

    // Handle ICE candidates
    _peerConnection!.onIceCandidate = (candidate) {
      debugPrint(
        '📞 ICE candidate generated: ${candidate.candidate}, sdpMid: ${candidate.sdpMid}, sdpMLineIndex: ${candidate.sdpMLineIndex}',
      );
      if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
        onIceCandidate?.call(
          candidate.candidate!,
          candidate.sdpMid,
          candidate.sdpMLineIndex,
        );
      }
    };

    // Handle ICE gathering state changes
    _peerConnection!.onIceGatheringState = (state) {
      debugPrint('📞 ICE gathering state: $state');
    };

    // Handle signaling state changes
    _peerConnection!.onSignalingState = (state) {
      debugPrint('📞 Signaling state: $state');
    };

    // Handle remote stream
    _peerConnection!.onTrack = (event) {
      debugPrint('📞 Remote track received: ${event.track.kind}');
      _remoteStream = event.streams[0];
      onRemoteStream?.call(_remoteStream!);

      // Ensure audio track is enabled
      if (event.track.kind == 'audio') {
        event.track.enabled = true;
        debugPrint('📞 Remote audio track enabled');
      }
    };

    // Handle connection state changes
    _peerConnection!.onConnectionState = (state) {
      debugPrint('📞 Connection state changed: $state');

      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          debugPrint('📞 WebRTC CONNECTED - starting timer and audio');
          onCallStateChange?.call('connected');
          _startDurationTimer();
          _startStatsLogger();
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          debugPrint('📞 WebRTC DISCONNECTED');
          onCallStateChange?.call('disconnected');
          _stopStatsLogger();
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          debugPrint('📞 WebRTC FAILED');
          onCallStateChange?.call('ended');
          _endCall();
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          debugPrint('📞 WebRTC CLOSED');
          onCallStateChange?.call('ended');
          _endCall();
          break;
        default:
          break;
      }
    };
  }

  /// Get local audio stream with hardware optimization
  Future<MediaStream?> _getUserMedia() async {
    try {
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });

      debugPrint('📞 Local audio stream captured with hardware optimization');
      return stream;
    } catch (e) {
      debugPrint('❌ Failed to get user media: $e');
      return null;
    }
  }

  /// Set remote description (answer for caller, offer for callee)
  Future<void> setRemoteDescription(String sdp, String type) async {
    try {
      await _peerConnection?.setRemoteDescription(
        RTCSessionDescription(sdp, type),
      );
      debugPrint('📞 Remote description set: $type');
    } catch (e) {
      debugPrint('❌ Failed to set remote description: $e');
    }
  }

  /// Add ICE candidate
  Future<void> addIceCandidate(
    String candidate,
    String sdpMid,
    int sdpMLineIndex,
  ) async {
    try {
      await _peerConnection?.addCandidate(
        RTCIceCandidate(candidate, sdpMid, sdpMLineIndex),
      );
      debugPrint('📞 ICE candidate added');
    } catch (e) {
      debugPrint('❌ Failed to add ICE candidate: $e');
    }
  }

  /// Toggle mute
  void toggleMute() {
    if (_localStream != null) {
      _isMuted = !_isMuted;
      _localStream!.getAudioTracks().forEach((track) {
        track.enabled = !_isMuted;
      });
      debugPrint('📞 Mute toggled: $_isMuted');
    }
  }

  /// Toggle speaker
  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    try {
      await Helper.setSpeakerphoneOn(_isSpeakerOn);
      debugPrint('📞 Speaker toggled: $_isSpeakerOn');
    } catch (e) {
      debugPrint('❌ Failed to toggle speaker: $e');
    }
  }

  /// Start call duration timer
  void _startDurationTimer() {
    _durationTimer?.cancel();
    _callDurationSeconds = 0;

    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _callDurationSeconds++;
    });

    debugPrint('📞 Call duration timer started');
  }

  /// Get call duration formatted as MM:SS
  String getCallDuration() {
    final minutes = _callDurationSeconds ~/ 60;
    final seconds = _callDurationSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// End the call
  void endCall() {
    debugPrint('📞 Ending call');
    _endCall();
  }

  /// Internal cleanup
  void _endCall() {
    _durationTimer?.cancel();
    _durationTimer = null;

    _statsTimer?.cancel();
    _statsTimer = null;

    _localStream?.getTracks().forEach((track) {
      track.stop();
    });
    _localStream?.dispose();
    _localStream = null;

    _remoteStream?.dispose();
    _remoteStream = null;

    _peerConnection?.close();
    _peerConnection?.dispose();
    _peerConnection = null;

    onCallEnded?.call(_currentCallId ?? '');

    _currentCallId = null;
    _localDeviceId = null;
    _remoteDeviceId = null;
    _isCaller = false;
    _isMuted = false;
    _isSpeakerOn = false;
    _callDurationSeconds = 0;

    debugPrint('📞 Call ended and cleaned up');
  }

  /// Request microphone permission
  Future<bool> _requestMicrophonePermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  /// Getters
  bool get isMuted => _isMuted;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isInCall => _peerConnection != null;
  String? get currentCallId => _currentCallId;
  String? get remoteDeviceId => _remoteDeviceId;
  bool get isCaller => _isCaller;

  /// Start periodic stats logging for diagnostic purposes
  void _startStatsLogger() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (_peerConnection == null) {
        timer.cancel();
        return;
      }
      try {
        final stats = await _peerConnection!.getStats();
        for (final report in stats) {
          if (report.type == 'outbound-rtp' || report.type == 'inbound-rtp') {
            final bytesSent = report.values['bytesSent'];
            final bytesReceived = report.values['bytesReceived'];
            final kind = report.values['kind'] ?? 'unknown';
            if (bytesSent != null) {
              debugPrint('📊 outbound-rtp ($kind): bytesSent=$bytesSent');
            }
            if (bytesReceived != null) {
              debugPrint(
                '📊 inbound-rtp ($kind): bytesReceived=$bytesReceived',
              );
            }
          }
        }
      } catch (e) {
        debugPrint('❌ Error getting stats: $e');
      }
    });
    debugPrint('📊 Stats logger started');
  }

  /// Stop the stats logger
  void _stopStatsLogger() {
    _statsTimer?.cancel();
    _statsTimer = null;
    debugPrint('📊 Stats logger stopped');
  }

  /// Dispose
  void dispose() {
    _endCall();
  }
}
