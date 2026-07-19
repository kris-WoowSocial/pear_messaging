import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'call_foreground_service.dart';

/// WebRTC Call Service - Manages peer-to-peer audio calls with E2EE
class WebRTCCallService {
  static final WebRTCCallService _instance = WebRTCCallService._internal();
  factory WebRTCCallService() => _instance;
  WebRTCCallService._internal();

  static const MethodChannel _audioChannel = MethodChannel(
    'com.pear.messaging/audio',
  );

  // Peer connection
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  // Track whether remote description has been set so we can buffer ICE candidates
  // that arrive before the peer connection is ready
  bool _remoteDescriptionSet = false;

  // Call state
  String? _currentCallId;
  String? _remoteDeviceId;
  bool _isCaller = false;
  bool _isMuted = false;
  bool _isSpeakerOn = false;

  // Call duration
  Timer? _durationTimer;
  int _callDurationSeconds = 0;

  // Buffer for remote ICE candidates received before the peer connection is ready
  final List<RTCIceCandidate> _pendingRemoteIceCandidates = [];

  // Stats timer for diagnostics (logs bytes sent/received)
  Timer? _statsTimer;

  // Callbacks
  Function(MediaStream)? onLocalStream;
  Function(MediaStream)? onRemoteStream;
  Function(String)? onCallEnded;
  Function(String candidate, String? sdpMid, int? sdpMLineIndex)?
  onIceCandidate;
  Function(String)? onCallStateChange;
  Function(String)? onLocalDescription; // Callback for SDP offer/answer

  // ICE servers configuration
  // Direct P2P is tried first (STUN), TURN is used only as a fallback when
  // direct connectivity fails. Forcing relay-only previously caused calls to
  // auto-disconnect whenever the TURN relay had any hiccup.
  final Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun3.l.google.com:19302'},
      {'urls': 'stun:stun4.l.google.com:19302'},
      {
        'urls': 'turn:turn.vant.chat:3478?transport=udp',
        'username': 'vantchat',
        'credential': 'Y9FA4x5PA2WDAMwBWfVClL5R7VyH8/BfRql9jTBNg54=',
      },
      {
        'urls': 'turn:turn.vant.chat:3478?transport=tcp',
        'username': 'vantchat',
        'credential': 'Y9FA4x5PA2WDAMwBWfVClL5R7VyH8/BfRql9jTBNg54=',
      },
      {
        'urls': 'turn:turn.vant.chat:443?transport=tcp',
        'username': 'vantchat',
        'credential': 'Y9FA4x5PA2WDAMwBWfVClL5R7VyH8/BfRql9jTBNg54=',
      },
    ],
    'sdpSemantics': 'unified-plan',
    'iceTransportPolicy': 'all', // Try direct P2P first, fallback to TURN
    'iceCandidatePoolSize':
        10, // Pre-generate ICE candidates for faster connection
  };

  /// Initialize the call service
  Future<void> initialize() async {
    debugPrint('WebRTCCallService initialized');
  }

  /// Start an outgoing call
  Future<bool> startCall({
    required String calleeDeviceId,
    required String callerDeviceId,
  }) async {
    try {
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
      // On iOS, audio session is configured by flutter_webrtc during getUserMedia.
      // We'll configure speaker routing AFTER the stream is captured (on connection).
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

      // Create offer
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      // Notify caller of the SDP offer
      if (offer.sdp != null) {
        onLocalDescription?.call(offer.sdp!);
      }

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
  }) async {
    try {
      _currentCallId = callId;
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
      // On iOS, audio session is configured by flutter_webrtc during getUserMedia.
      // We'll configure speaker routing AFTER the stream is captured (on connection).
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
      _remoteDescriptionSet = true;
      // Add any candidates that arrived before the remote description was ready
      await _flushPendingRemoteIceCandidates();

      // Create answer
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      // Send the answer immediately (trickle ICE). Candidates are exchanged
      // separately via signaling, so we must NOT block on ICE gathering here.
      if (answer.sdp != null) {
        onLocalDescription?.call(answer.sdp!);
      }

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
    debugPrint(
      '🔧 Creating peer connection with ICE servers: ${_iceServers['iceServers'].length} servers',
    );
    for (var i = 0; i < _iceServers['iceServers'].length; i++) {
      final server = _iceServers['iceServers'][i];
      debugPrint('  ICE Server $i: ${server['urls']}');
    }
    _peerConnection = await createPeerConnection(_iceServers);

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

    // Handle remote stream
    _peerConnection!.onTrack = (event) async {
      debugPrint('📞 Remote track received');
      _remoteStream = event.streams[0];
      onRemoteStream?.call(_remoteStream!);
    };

    // Handle ICE gathering state changes
    _peerConnection!.onIceGatheringState = (state) {
      debugPrint('📞 ICE gathering state: $state');
    };

    // Handle ICE connection state changes
    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('📞 ICE connection state: $state');
    };

    // Handle connection state changes
    _peerConnection!.onConnectionState = (state) {
      debugPrint('📞 Connection state: $state');

      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          debugPrint('📞 WebRTC CONNECTED - starting timer and audio');
          onCallStateChange?.call('connected');
          // Re-apply audio configuration to ensure earpiece/speaker routing persists
          // after WebRTC claims audio focus during connection establishment
          _configureAudioSession(speakerOn: _isSpeakerOn);
          _startDurationTimer();
          _startStatsLogger();
          if (Platform.isAndroid) CallForegroundService().start();
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          debugPrint(
            '📞 WebRTC DISCONNECTED - attempting ICE restart if needed',
          );
          onCallStateChange?.call('disconnected');
          _stopStatsLogger();
          // Don't immediately end call on disconnect, give it more time to recover
          // Increased from 3s to 10s to handle network hiccups and TURN relay instability
          Future.delayed(const Duration(seconds: 10), () {
            if (_peerConnection != null &&
                _peerConnection!.connectionState ==
                    RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
              debugPrint('📞 Still disconnected after 10 seconds, ending call');
              onCallStateChange?.call('ended');
              _endCall();
            }
          });
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          debugPrint('📞 WebRTC FAILED - ending call');
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
      _remoteDescriptionSet = true;
      debugPrint('📞 Remote description set: $type');
      // Add any candidates that arrived before the remote description was ready
      await _flushPendingRemoteIceCandidates();
    } catch (e) {
      debugPrint('❌ Failed to set remote description: $e');
    }
  }

  /// Add ICE candidate. Buffers it if the peer connection or remote description
  /// isn't ready yet.
  Future<void> addIceCandidate(
    String candidate,
    String sdpMid,
    int sdpMLineIndex,
  ) async {
    final iceCandidate = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);

    if (_peerConnection == null || !_remoteDescriptionSet) {
      debugPrint(
        '📦 Buffering remote ICE candidate (not ready): $sdpMid:$sdpMLineIndex',
      );
      _pendingRemoteIceCandidates.add(iceCandidate);
      return;
    }

    try {
      await _peerConnection!.addCandidate(iceCandidate);
      debugPrint('📞 ICE candidate added');
    } catch (e) {
      debugPrint(
        '📦 Buffering remote ICE candidate after add failure: $sdpMid:$sdpMLineIndex - $e',
      );
      _pendingRemoteIceCandidates.add(iceCandidate);
    }
  }

  /// Flush any buffered remote ICE candidates after the remote description is set
  Future<void> _flushPendingRemoteIceCandidates() async {
    if (_pendingRemoteIceCandidates.isEmpty || _peerConnection == null) return;

    debugPrint(
      '📤 Flushing ${_pendingRemoteIceCandidates.length} buffered remote ICE candidates',
    );
    final candidates = List<RTCIceCandidate>.from(_pendingRemoteIceCandidates);
    _pendingRemoteIceCandidates.clear();

    // Add all candidates in parallel for faster connection
    await Future.wait(
      candidates.map((candidate) async {
        try {
          await _peerConnection!.addCandidate(candidate);
          debugPrint(
            '📞 Buffered ICE candidate added: ${candidate.sdpMid}:${candidate.sdpMLineIndex}',
          );
        } catch (e) {
          debugPrint(
            '❌ Failed to add buffered ICE candidate: ${candidate.sdpMid}:${candidate.sdpMLineIndex} - $e',
          );
        }
      }),
    );
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
    final newState = !_isSpeakerOn;
    await _configureAudioSession(speakerOn: newState);
    _isSpeakerOn = newState;
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
  Future<void> _endCall() async {
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
    _remoteDescriptionSet = false;
    _pendingRemoteIceCandidates.clear();

    // Reset speakerphone to earpiece when the call ends
    await _configureAudioSession(speakerOn: false);
    _isSpeakerOn = false;

    onCallEnded?.call(_currentCallId ?? '');

    if (Platform.isAndroid) CallForegroundService().stop();

    _currentCallId = null;
    _remoteDeviceId = null;
    _isCaller = false;
    _isMuted = false;
    _callDurationSeconds = 0;

    debugPrint('📞 Call ended and cleaned up');
  }

  /// Configure audio session after call connects
  /// On iOS, audio session is already configured by flutter_webrtc during getUserMedia.
  /// This method only controls speaker routing (earpiece vs speaker) after connection.
  Future _configureAudioSession({bool speakerOn = false}) async {
    try {
      if (Platform.isAndroid) {
        await _audioChannel.invokeMethod('setSpeakerphoneOn', {
          'on': speakerOn,
        });
        debugPrint('📞 Audio session configured: speaker=$speakerOn (Android)');
      } else {
        await Helper.setSpeakerphoneOn(speakerOn);
        debugPrint('📞 Audio session configured: speaker=$speakerOn (iOS)');
      }
    } catch (e) {
      debugPrint('⚠️ Audio session config failed: $e');
    }
  }

  /// Request microphone permission
  Future<bool> _requestMicrophonePermission() async {
    final status = await Permission.microphone.request();

    if (status.isGranted) {
      return true;
    }

    if (status.isPermanentlyDenied) {
      debugPrint(
        '❌ Microphone permission permanently denied - need to open settings',
      );
    } else if (status.isDenied) {
      debugPrint('❌ Microphone permission denied by user');
    }

    return false;
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
