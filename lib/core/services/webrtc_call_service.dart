import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'socket_service.dart';
import 'secure_key_service.dart';

/// WebRTC Call Service - Manages peer-to-peer audio calls with E2EE
class WebRTCCallService {
  static final WebRTCCallService _instance = WebRTCCallService._internal();
  factory WebRTCCallService() => _instance;
  WebRTCCallService._internal();

  // Peer connection
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  // E2EE FrameCryptor
  FrameCryptor? _senderFrameCryptor;
  FrameCryptor? _receiverFrameCryptor;
  FrameCryptorKeyProvider? _keyProvider;

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

  // Callbacks
  Function(String)? onLocalStream;
  Function(MediaStream)? onRemoteStream;
  Function(String)? onCallEnded;
  Function(String)? onIceCandidate;
  Function(String)? onCallStateChange;

  // ICE servers configuration
  final List<RTCIceServer> _iceServers = [
    RTCIceServer(
      urls: 'stun:stun.l.google.com:19302',
    ),
  ];

  // TURN server configuration (will be loaded from environment)
  RTCIceServer? _turnServer;

  /// Initialize the call service
  Future<void> initialize() async {
    debugPrint('📞 WebRTCCallService initialized');

    // Load TURN server configuration from backend
    await _loadTurnServerConfig();
  }

  /// Load TURN server configuration from backend
  Future<void> _loadTurnServerConfig() async {
    try {
      // For now, use hardcoded values from .env
      // In production, fetch from backend API
      _turnServer = RTCIceServer(
        urls: 'turn:54.175.143.63:3478',
        username: 'vantchat',
        credential: 'your_secure_turn_password_here',
      );

      if (_turnServer != null) {
        _iceServers.add(_turnServer!);
        debugPrint('📞 TURN server configured');
      }
    } catch (e) {
      debugPrint('⚠️ Failed to load TURN server config: $e');
    }
  }

  /// Initialize E2EE with shared secret
  Future<void> _initializeE2EE(String sharedSecret) async {
    try {
      // Create key provider with index-aware allocation
      _keyProvider = FrameCryptorFactory.createDefaultKeyProvider();

      // Derive key from shared secret (32 bytes for AES-256)
      final keyBytes = _deriveKeyFromSecret(sharedSecret);
      await _keyProvider?.setKey(keyBytes, 0);

      debugPrint('🔒 E2EE initialized with FrameCryptor');
    } catch (e) {
      debugPrint('❌ Failed to initialize E2EE: $e');
    }
  }

  /// Derive 32-byte key from shared secret
  Uint8List _deriveKeyFromSecret(String secret) {
    // Simple derivation - in production use proper KDF
    final bytes = secret.codeUnits;
    final key = Uint8List(32);

    for (int i = 0; i < 32; i++) {
      key[i] = bytes[i % bytes.length];
    }

    return key;
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

      // Initialize E2EE
      await _initializeE2EE(sharedSecret);

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
      _localStream!.getTracks().forEach((track) async {
        await _peerConnection!.addTrack(track, _localStream!);

        // Setup E2EE for sender
        if (_keyProvider != null) {
          final sender = _peerConnection!.getSenders().firstWhere(
                (s) => s.track == track,
                orElse: () => throw Exception('Sender not found'),
              );

          _senderFrameCryptor =
              await FrameCryptorFactory.createFrameCryptorForRtpSender(
            sender,
            _keyProvider!,
            'AES_GCM',
          );

          await _senderFrameCryptor?.setEnabled(true);
          debugPrint('🔒 E2EE enabled for sender');
        }
      });

      // Create offer
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      onCallStateChange?.call('dialing');

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

      // Initialize E2EE
      await _initializeE2EE(sharedSecret);

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
      _localStream!.getTracks().forEach((track) async {
        await _peerConnection!.addTrack(track, _localStream!);

        // Setup E2EE for sender
        if (_keyProvider != null) {
          final sender = _peerConnection!.getSenders().firstWhere(
                (s) => s.track == track,
                orElse: () => throw Exception('Sender not found'),
              );

          _senderFrameCryptor =
              await FrameCryptorFactory.createFrameCryptorForRtpSender(
            sender,
            _keyProvider!,
            'AES_GCM',
          );

          await _senderFrameCryptor?.setEnabled(true);
          debugPrint('🔒 E2EE enabled for sender');
        }
      });

      // Set remote description (offer)
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdpOffer, 'offer'),
      );

      // Create answer
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      onCallStateChange?.call('ringing');

      debugPrint('📞 Answer created, sending via signaling');
      return true;
    } catch (e) {
      debugPrint('❌ Failed to accept call: $e');
      return false;
    }
  }

  /// Create peer connection with ICE servers
  Future<void> _createPeerConnection() async {
    final configuration = RTCConfiguration(
      iceServers: _iceServers,
      iceTransportPolicy: 'all',
    );

    _peerConnection = await createPeerConnection(configuration);

    // Handle ICE candidates
    _peerConnection!.onIceCandidate = (candidate) {
      debugPrint('📞 ICE candidate: ${candidate.candidate}');
      onIceCandidate?.call(candidate.candidate ?? '');
    };

    // Handle remote stream
    _peerConnection!.onTrack = (event) async {
      debugPrint('📞 Remote track received');
      _remoteStream = event.streams[0];

      // Setup E2EE for receiver
      if (_keyProvider != null) {
        _receiverFrameCryptor =
            FrameCryptorFactory.createFrameCryptorForRtpReceiver(
          event.receiver,
          _keyProvider!,
          'AES_GCM',
        );

        await _receiverFrameCryptor?.setEnabled(true);
        debugPrint('🔒 E2EE enabled for receiver');
      }

      onRemoteStream?.call(_remoteStream!);
    };

    // Handle connection state changes
    _peerConnection!.onConnectionState = (state) {
      debugPrint('📞 Connection state: $state');

      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          onCallStateChange?.call('connected');
          _startDurationTimer();
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
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
      String candidate, String sdpMid, int sdpMLineIndex) async {
    try {
      await _peerConnection?.addCandidate(
        RTCIceCandidate(
          candidate,
          sdpMid,
          sdpMLineIndex,
        ),
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
  void toggleSpeaker() {
    _isSpeakerOn = !_isSpeakerOn;
    // Note: Speaker toggle requires platform-specific implementation
    // This is a placeholder - actual implementation depends on platform
    debugPrint('📞 Speaker toggled: $_isSpeakerOn');
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

    _senderFrameCryptor?.dispose();
    _senderFrameCryptor = null;

    _receiverFrameCryptor?.dispose();
    _receiverFrameCryptor = null;

    _keyProvider?.dispose();
    _keyProvider = null;

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

  /// Dispose
  void dispose() {
    _endCall();
  }
}
