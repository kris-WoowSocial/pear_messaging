import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'call_foreground_service.dart';
import 'call_media_helper.dart';

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
  bool _isVideoCall = false;
  bool _isCameraEnabled = false;
  bool _isFrontCamera = true;
  bool _iceRestartInProgress = false;
  String? _localSdp;
  String? _remoteSdp;

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
  Function(String sdp, bool isOffer)? onIceRestartDescription;
  Function(String reason)? onIceRestartNeeded;
  Function(String reason)? onConnectionFailed;
  Function()? onCameraPermissionDenied;

  // Direct P2P is tried first (STUN). TURN credentials are fetched per call
  // from the registered signaling socket and expire server-side; no shared TURN
  // secret is embedded in the app.
  Future<List<Map<String, dynamic>>?> Function()? iceServersProvider;
  List<Map<String, dynamic>>? _pendingIceServers;
  final Map<String, dynamic> _fallbackIceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun3.l.google.com:19302'},
      {'urls': 'stun:stun4.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
    'iceTransportPolicy': 'all', // Try direct P2P first, fallback to TURN
    'iceCandidatePoolSize':
        10, // Pre-generate ICE candidates for faster connection
  };

  /// Use ICE servers already delivered inside an authenticated call event.
  /// This lets a cold-started callee create the peer connection without an
  /// extra `call_ice_servers` round trip.
  void primeIceServers(dynamic rawServers) {
    if (rawServers is! List) return;
    final servers = <Map<String, dynamic>>[];
    for (final item in rawServers) {
      if (item is Map) servers.add(Map<String, dynamic>.from(item));
    }
    if (servers.isNotEmpty) _pendingIceServers = servers;
  }

  Future<Map<String, dynamic>> _resolveIceServers() async {
    try {
      final primed = _pendingIceServers;
      _pendingIceServers = null;
      if (primed != null && primed.isNotEmpty) {
        return {..._fallbackIceServers, 'iceServers': primed};
      }
      final servers = await iceServersProvider?.call();
      if (servers == null || servers.isEmpty) return _fallbackIceServers;
      return {
        ..._fallbackIceServers,
        'iceServers': servers,
      };
    } catch (e) {
      debugPrint('⚠️ Failed to fetch ICE servers, using STUN fallback: $e');
      return _fallbackIceServers;
    }
  }

  /// Initialize the call service
  Future<void> initialize() async {
    debugPrint('WebRTCCallService initialized');
  }

  /// Start an outgoing call
  Future<bool> startCall({
    required String calleeDeviceId,
    required String callerDeviceId,
    bool isVideo = false,
  }) async {
    try {
      _remoteDeviceId = calleeDeviceId;
      _isCaller = true;
      _isVideoCall = isVideo;
      _isSpeakerOn = isVideo;
      final callId = 'call_${DateTime.now().millisecondsSinceEpoch}';
      _currentCallId = callId;

      debugPrint('📞 Starting call to $calleeDeviceId');

      // Request microphone permission
      final hasPermission = await _requestMicrophonePermission();
      if (!hasPermission || _currentCallId != callId) {
        debugPrint('❌ Microphone permission denied or call cancelled');
        return false;
      }

      // Request camera permission and capture the local video track now so it
      // is included in the initial offer's SSRC/msid lines. This matches the
      // pre-regression behaviour and avoids replaceTrack on a sender created
      // from an empty transceiver.
      if (isVideo && !await _requestCameraPermission()) {
        _isVideoCall = false;
        _isSpeakerOn = false;
        onCameraPermissionDenied?.call();
      }

      // Create peer connection
      await _createPeerConnection();
      if (_currentCallId != callId) return false;

      // Force the Android audio subsystem into MODE_IN_COMMUNICATION BEFORE WebRTC
      // captures audio. Without this, cold-start answers can initialize in MODE_NORMAL
      // and speaker routing will not switch until ~60 seconds later.
      await _forceAudioDevice();
      await Future.delayed(const Duration(milliseconds: 100));

      // Get local audio/video stream. For video calls the camera is captured
      // here and added to the peer connection before createOffer.
      _localStream = await _getUserMedia(video: _isVideoCall);
      if (_localStream == null || _currentCallId != callId) {
        debugPrint('❌ Failed to get local stream or call was cancelled');
        final staleStream = _localStream;
        _localStream = null;
        staleStream?.getTracks().forEach((track) => track.stop());
        await staleStream?.dispose();
        return false;
      }

      // Force audio mode again AFTER getUserMedia
      await _forceAudioDevice();

      onLocalStream?.call(_localStream!);
      _isCameraEnabled = _localStream!.getVideoTracks().isNotEmpty;

      // Add every local track to the peer connection before creating the offer.
      // CRITICAL FIX: Use for loop instead of forEach - forEach doesn't await async callbacks
      for (final track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }
      if (_currentCallId != callId) return false;

      // Verify tracks were added before creating offer
      final sendersBeforeOffer = await _peerConnection!.getSenders();
      debugPrint(
        '📞 Active senders before createOffer: ${sendersBeforeOffer.length}',
      );
      await _applyVideoBitrateCap();

      // Create offer
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);
      _logSdpVideoDirections('local offer', offer.sdp);

      // Notify caller of the SDP offer
      if (offer.sdp != null) {
        _localSdp = offer.sdp;
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
    bool isVideo = false,
  }) async {
    try {
      _currentCallId = callId;
      _remoteDeviceId = callerDeviceId;
      _isCaller = false;
      _isVideoCall = isVideo;
      _isSpeakerOn = isVideo;

      debugPrint('📞 Accepting call from $callerDeviceId');

      // Request microphone permission
      final hasPermission = await _requestMicrophonePermission();
      if (!hasPermission || _currentCallId != callId) {
        debugPrint('❌ Microphone permission denied or call cancelled');
        return false;
      }

      // Request camera permission and capture the local video track now so it
      // is included in the initial answer.
      if (isVideo && !await _requestCameraPermission()) {
        _isVideoCall = false;
        _isSpeakerOn = false;
        onCameraPermissionDenied?.call();
      }

      // Create peer connection
      await _createPeerConnection();
      if (_currentCallId != callId) return false;

      // CRITICAL: Stop any active ringtone/vibration, tell Telecom the call is
      // ACTIVE (not ringing), and force MODE_IN_COMMUNICATION.
      // The native side also calls VantCallManager.activeConnection.setActive()
      // which tells the Android Telecom framework to stop routing audio as a
      // ringing call (MODE_RINGTONE). Without this, the system audio router keeps
      // overriding our mode to MODE_RINGTONE and WebRTC's AudioTrack gets created
      // under STREAM_RING which permanently locks audio to the earpiece.
      await _stopRingingAndSetAudioMode();
      // Allow the Android audio subsystem + Telecom framework to settle after
      // stopping the ringtone and transitioning the connection to ACTIVE state.
      // Telecom's audio routing change is asynchronous and needs time to propagate.
      await Future.delayed(const Duration(milliseconds: 500));
      // Force the mode one more time right before getUserMedia
      await _forceAudioDevice();

      // Get local audio/video stream. For video calls the camera is captured
      // here and added to the peer connection before createAnswer.
      _localStream = await _getUserMedia(video: _isVideoCall);
      if (_localStream == null || _currentCallId != callId) {
        debugPrint('❌ Failed to get local stream or call was cancelled');
        final staleStream = _localStream;
        _localStream = null;
        staleStream?.getTracks().forEach((track) => track.stop());
        await staleStream?.dispose();
        return false;
      }

      // Force audio mode again AFTER getUserMedia, because WebRTC's internal
      // JavaAudioDeviceModule may have reset it during AudioTrack creation.
      await _forceAudioDevice();

      onLocalStream?.call(_localStream!);
      _isCameraEnabled = _localStream!.getVideoTracks().isNotEmpty;

      // Add every local track to the peer connection before creating the answer.
      for (final track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }
      if (_currentCallId != callId) return false;

      // Verify tracks were added before creating answer
      final sendersBeforeAnswer = await _peerConnection!.getSenders();
      debugPrint(
        '📞 Active senders before createAnswer: ${sendersBeforeAnswer.length}',
      );
      await _applyVideoBitrateCap();

      // Force mode AGAIN right before setRemoteDescription, because this is the
      // call that triggers onAddTrack → playout AudioTrack creation on a worker
      // thread. The AudioTrack reads the current audio mode at creation time.
      await _forceAudioDevice();

      // Set remote description (offer)
      _remoteSdp = sdpOffer;
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdpOffer, 'offer'),
      );
      _remoteDescriptionSet = true;
      // Add any candidates that arrived before the remote description was ready
      await _flushPendingRemoteIceCandidates();
      if (_currentCallId != callId) return false;

      // Create answer
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);
      _logSdpVideoDirections('local answer', answer.sdp);

      // Send the answer immediately (trickle ICE). Candidates are exchanged
      // separately via signaling, so we must NOT block on ICE gathering here.
      if (answer.sdp != null) {
        _localSdp = answer.sdp;
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

  /// Create peer connection with per-call ICE servers
  Future<void> _createPeerConnection() async {
    final iceConfig = await _resolveIceServers();
    debugPrint(
      '🔧 Creating peer connection with ICE servers: ${iceConfig['iceServers'].length} servers',
    );
    for (var i = 0; i < iceConfig['iceServers'].length; i++) {
      final server = iceConfig['iceServers'][i];
      debugPrint('  ICE Server $i: ${server['urls']}');
    }
    _peerConnection = await createPeerConnection(iceConfig);

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
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        onIceRestartNeeded?.call(state.toString());
      }
    };

    // Handle connection state changes
    _peerConnection!.onConnectionState = (state) {
      debugPrint('📞 Connection state: $state');

      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          debugPrint('📞 WebRTC CONNECTED - starting timer and audio');
          onCallStateChange?.call('connected');
          // Apply audio configuration once. For video calls the speaker default
          // prefers an already-connected Bluetooth/wired headset instead of
          // forcing the speaker route.
          _configureAudioSession(
            speakerOn: _isSpeakerOn,
            preferBluetooth: _isVideoCall,
          );
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
          debugPrint('📞 WebRTC FAILED - attempting ICE restart');
          onIceRestartNeeded?.call('connection_failed');
          if (onConnectionFailed != null) {
            onConnectionFailed!('failed');
            Future.delayed(const Duration(seconds: 10), () {
              if (_peerConnection != null &&
                  _peerConnection!.connectionState ==
                      RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
                debugPrint('📞 Still failed after 10 seconds, ending call');
                onCallStateChange?.call('ended');
                _endCall();
              }
            });
          } else {
            onCallStateChange?.call('ended');
            _endCall();
          }
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

  /// Get local media stream with hardware optimization
  Future<MediaStream?> _getUserMedia({bool video = false}) async {
    try {
      if (video) _isFrontCamera = true;
      final stream = await navigator.mediaDevices.getUserMedia(
        CallMediaHelper.mediaConstraints(video: video),
      );

      debugPrint(
        video
            ? '📞 Local audio/video stream captured with hardware optimization'
            : '📞 Local audio stream captured with hardware optimization',
      );
      return stream;
    } catch (e) {
      debugPrint('❌ Failed to get user media: $e');
      return null;
    }
  }

  /// Set remote description (answer for caller, offer for callee)
  Future<void> setRemoteDescription(String sdp, String type) async {
    _logSdpVideoDirections('remote $type', sdp);
    try {
      await _peerConnection?.setRemoteDescription(
        RTCSessionDescription(sdp, type),
      );
      _remoteSdp = sdp;
      _remoteDescriptionSet = true;
      debugPrint('📞 Remote description set: $type');
      await _logVideoSenderState('after setRemoteDescription($type)');
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

  /// Set mute state explicitly (e.g. when Telecom holds/unholds the call)
  void setMuted(bool muted) {
    if (_localStream != null && _isMuted != muted) {
      _isMuted = muted;
      _localStream!.getAudioTracks().forEach((track) {
        track.enabled = !muted;
      });
      debugPrint('📞 Mute set to: $muted');
    }
  }

  /// Toggle the local camera without renegotiating the call.
  Future<void> setCameraEnabled(bool enabled) async {
    final tracks = _localStream?.getVideoTracks() ?? const [];
    for (final track in tracks) {
      track.enabled = enabled;
    }
    _isCameraEnabled = enabled && tracks.isNotEmpty;
    debugPrint('📞 Camera set to: $_isCameraEnabled');
    await _logVideoSenderState('after setCameraEnabled($enabled)');
  }

  /// Switch between front and rear cameras when a video track is active.
  Future<bool> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? const [];
    if (tracks.isEmpty) return false;
    try {
      final switched = await Helper.switchCamera(tracks.first);
      if (switched) _isFrontCamera = !_isFrontCamera;
      return switched;
    } catch (e) {
      debugPrint('⚠️ Failed to switch camera: $e');
      return false;
    }
  }

  /// Cap outbound video bitrate through RTP sender parameters.
  Future<void> _applyVideoBitrateCap() async {
    if (!_isVideoCall || _peerConnection == null) return;
    try {
      final senders = await _peerConnection!.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind != 'video') continue;
        final parameters = sender.parameters;
        final encodings = parameters.encodings;
        if (encodings == null || encodings.isEmpty) {
          parameters.encodings = [
            RTCRtpEncoding(maxBitrate: CallMediaHelper.videoBitrateCapBps),
          ];
        } else {
          for (final encoding in encodings) {
            encoding.maxBitrate = CallMediaHelper.videoBitrateCapBps;
          }
        }
        await sender.setParameters(parameters);
      }
      debugPrint(
        '📞 Video bitrate capped at ${CallMediaHelper.videoBitrateCapBps}bps',
      );
    } catch (e) {
      debugPrint('⚠️ Failed to apply video bitrate cap: $e');
    }
  }

  /// Toggle speaker
  Future<void> toggleSpeaker() async {
    final newState = !_isSpeakerOn;
    _isSpeakerOn = newState;
    await _configureAudioSession(speakerOn: newState);
    debugPrint('📞 Speaker toggled: $_isSpeakerOn');
  }

  /// Set speaker to specific state (useful for restoring state after app resume)
  Future<void> setSpeaker(bool speakerOn) async {
    _isSpeakerOn = speakerOn;
    await _configureAudioSession(speakerOn: speakerOn);
    debugPrint('📞 Speaker set to: $speakerOn');
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
    _isVideoCall = false;
    _isCameraEnabled = false;
    _isFrontCamera = true;
    _iceRestartInProgress = false;
    _localSdp = null;
    _remoteSdp = null;
    _callDurationSeconds = 0;

    debugPrint('📞 Call ended and cleaned up');
  }

  /// Configure audio session after call connects.
  /// On iOS, audio session is already configured by flutter_webrtc during getUserMedia.
  /// This method controls speaker routing (earpiece vs speaker) after connection.
  ///
  /// For video calls the speaker default must not override an active Bluetooth
  /// or wired headset route. flutter_webrtc provides
  /// Helper.setSpeakerphoneOnButPreferBluetooth(), which sets
  /// AVAudioSessionCategoryOptionDefaultToSpeaker without forcing the output
  /// port override, so an already-connected headset keeps the route.
  ///
  /// IMPORTANT (Android): When a self-managed Telecom Connection is active,
  /// the framework owns the audio route and AudioManager/AudioSwitch requests
  /// may be ignored. We therefore notify Telecom via
  /// Connection.setAudioRoute(ROUTE_SPEAKER/ROUTE_EARPIECE) first, then keep
  /// flutter_webrtc's AudioSwitch state in sync with Helper.setSpeakerphoneOn.
  Future _configureAudioSession({
    bool speakerOn = false,
    bool preferBluetooth = false,
  }) async {
    try {
      if (Platform.isAndroid) {
        await _audioChannel.invokeMethod('setTelecomAudioRoute', {
          'speakerOn': speakerOn,
        });
      }
      if (speakerOn && preferBluetooth) {
        await Helper.setSpeakerphoneOnButPreferBluetooth();
      } else {
        await Helper.setSpeakerphoneOn(speakerOn);
      }
      debugPrint(
        '📞 Audio session configured: speaker=$speakerOn preferBluetooth=$preferBluetooth',
      );
    } catch (e) {
      debugPrint('⚠️ Audio session config failed: $e');
    }
  }

  /// Force audio device selection to prevent flutter_webrtc from interfering
  Future<void> _forceAudioDevice() async {
    if (Platform.isAndroid) {
      try {
        // Force audio mode to communication mode before WebRTC takes over
        await _audioChannel.invokeMethod('setAudioMode', {
          'mode': 'MODE_IN_COMMUNICATION',
        });
        debugPrint('📞 Audio mode forced to MODE_IN_COMMUNICATION');
      } catch (e) {
        debugPrint('⚠️ Failed to force audio mode: $e');
      }
    }
  }

  /// Stop any active ringing and force MODE_IN_COMMUNICATION atomically.
  /// Must be called BEFORE getUserMedia so WebRTC's AudioTrack is created under
  /// the correct audio mode instead of MODE_RINGTONE.
  Future<void> _stopRingingAndSetAudioMode() async {
    if (!Platform.isAndroid) return;
    try {
      await _audioChannel.invokeMethod('stopRingingAndSetAudioMode');
      debugPrint('📞 Ringing stopped and audio mode set atomically');
    } catch (e) {
      // Fallback: the method may not exist on older builds, just force audio mode
      debugPrint('⚠️ stopRingingAndSetAudioMode not available, using fallback');
      await _forceAudioDevice();
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

  /// Request camera permission only when a video call is starting.
  Future<bool> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (status.isGranted) return true;
    debugPrint(
      status.isPermanentlyDenied
          ? '❌ Camera permission permanently denied'
          : '❌ Camera permission denied — falling back to audio',
    );
    return false;
  }

  /// Getters
  bool get isMuted => _isMuted;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isVideoCall => _isVideoCall;
  bool get isCameraEnabled => _isCameraEnabled;
  bool get isFrontCamera => _isFrontCamera;
  bool get isIceRestartInProgress => _iceRestartInProgress;
  bool get isInCall => _peerConnection != null;
  String? get currentCallId => _currentCallId;
  String? get remoteDeviceId => _remoteDeviceId;
  bool get isCaller => _isCaller;

  /// Debug helper: print only the m=video section and its direction lines.
  void _logSdpVideoDirections(String label, String? sdp) {
    if (sdp == null) return;
    final lines = sdp.split('\n');
    var inVideo = false;
    final buffer = StringBuffer()..writeln('🧪 $label SDP video m-line:');
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('m=video')) {
        inVideo = true;
        buffer.writeln('  $line');
      } else if (line.startsWith('m=')) {
        inVideo = false;
      } else if (inVideo &&
          RegExp(r'^a=(sendrecv|recvonly|sendonly|inactive)\s*$')
              .hasMatch(line)) {
        buffer.writeln('  $line');
      }
    }
    debugPrint(buffer.toString().trimRight());
  }

  /// Debug helper: print current video sender track IDs and directions.
  Future<void> _logVideoSenderState(String label) async {
    if (_peerConnection == null) return;
    try {
      final senders = await _peerConnection!.getSenders();
      final transceivers = await _peerConnection!.getTransceivers();
      for (final sender in senders) {
        if (sender.track?.kind != 'video') continue;
        final tx = transceivers.cast<RTCRtpTransceiver?>().firstWhere(
              (t) => t?.sender == sender,
              orElse: () => null,
            );
        debugPrint(
          '🧪 $label video sender trackId=${sender.track?.id} '
          'hasTransceiver=${tx != null}',
        );
      }
    } catch (e) {
      debugPrint('⚠️ $label sender state log failed: $e');
    }
  }

  /// Start periodic stats logging for diagnostic purposes
  void _startStatsLogger() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_peerConnection == null) {
        timer.cancel();
        return;
      }
      try {
        final stats = await _peerConnection!.getStats();
        for (final report in stats) {
          if ((report.type == 'outbound-rtp' ||
                  report.type == 'inbound-rtp') &&
              (report.values['kind'] == 'video')) {
            final id = report.values['id'];
            final bytesSent = report.values['bytesSent'];
            final bytesReceived = report.values['bytesReceived'];
            final framesSent = report.values['framesSent'];
            final framesReceived = report.values['framesReceived'];
            final frameWidth = report.values['frameWidth'];
            final frameHeight = report.values['frameHeight'];
            if (report.type == 'outbound-rtp' && bytesSent != null) {
              debugPrint(
                '📊 VIDEO OUT id=$id bytes=$bytesSent '
                'frames=$framesSent ${frameWidth}x$frameHeight',
              );
            }
            if (report.type == 'inbound-rtp' && bytesReceived != null) {
              debugPrint(
                '📊 VIDEO IN id=$id bytes=$bytesReceived '
                'frames=$framesReceived ${frameWidth}x$frameHeight',
              );
            }
          }
        }
      } catch (e) {
        debugPrint('❌ Error getting stats: $e');
      }
    });
    debugPrint('📊 Stats logger started (2s video-only)');
  }

  /// Stop the stats logger
  void _stopStatsLogger() {
    _statsTimer?.cancel();
    _statsTimer = null;
    debugPrint('📊 Stats logger stopped');
  }

  /// Create and apply an ICE-restart offer. The SDP is returned through
  /// [onIceRestartDescription] instead of the normal call signaling callback.
  Future<bool> restartIce() async {
    if (_peerConnection == null || _iceRestartInProgress) return false;
    try {
      _iceRestartInProgress = true;
      final offer = await _peerConnection!.createOffer({'iceRestart': true});
      if (offer.sdp == null ||
          _localSdp == null ||
          !CallMediaHelper.sameDtlsFingerprints(_localSdp!, offer.sdp!)) {
        _iceRestartInProgress = false;
        debugPrint('❌ ICE restart aborted: DTLS fingerprint changed');
        return false;
      }
      await _peerConnection!.setLocalDescription(offer);
      _localSdp = offer.sdp;
      onIceRestartDescription?.call(offer.sdp!, true);
      return true;
    } catch (e) {
      _iceRestartInProgress = false;
      debugPrint('❌ ICE restart failed: $e');
      return false;
    }
  }

  /// Handle a remote ICE-restart offer and return its SDP answer through
  /// [onIceRestartDescription]. [acceptDuringLocalRestart] implements the
  /// deterministic glare tie-break: the polite side rolls back its pending
  /// local restart and answers the impolite side's offer.
  Future<bool> handleIceRestartOffer(
    String sdp, {
    bool acceptDuringLocalRestart = false,
  }) async {
    if (_peerConnection == null) return false;
    if (_iceRestartInProgress) {
      if (!acceptDuringLocalRestart) {
        debugPrint('📞 Ignoring remote ICE restart offer during local restart');
        return false;
      }
      try {
        await _peerConnection!.setLocalDescription(
          RTCSessionDescription('', 'rollback'),
        );
        _iceRestartInProgress = false;
      } catch (e) {
        debugPrint('❌ ICE restart glare rollback failed: $e');
        return false;
      }
    }
    if (_remoteSdp != null &&
        !CallMediaHelper.sameDtlsFingerprints(_remoteSdp!, sdp)) {
      debugPrint('❌ Remote ICE restart rejected: DTLS fingerprint changed');
      return false;
    }
    try {
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdp, 'offer'),
      );
      _remoteSdp = sdp;
      final answer = await _peerConnection!.createAnswer();
      if (answer.sdp == null ||
          _localSdp == null ||
          !CallMediaHelper.sameDtlsFingerprints(_localSdp!, answer.sdp!)) {
        debugPrint('❌ ICE restart answer aborted: DTLS fingerprint changed');
        return false;
      }
      await _peerConnection!.setLocalDescription(answer);
      _localSdp = answer.sdp;
      _iceRestartInProgress = false;
      onIceRestartDescription?.call(answer.sdp!, false);
      return true;
    } catch (e) {
      debugPrint('❌ Remote ICE restart handling failed: $e');
      return false;
    }
  }

  Future<bool> handleIceRestartAnswer(String sdp) async {
    if (_peerConnection == null || !_iceRestartInProgress) return false;
    if (_remoteSdp != null &&
        !CallMediaHelper.sameDtlsFingerprints(_remoteSdp!, sdp)) {
      debugPrint('❌ Remote ICE answer rejected: DTLS fingerprint changed');
      return false;
    }
    try {
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdp, 'answer'),
      );
      _remoteSdp = sdp;
      _iceRestartInProgress = false;
      return true;
    } catch (e) {
      debugPrint('❌ Remote ICE answer handling failed: $e');
      return false;
    }
  }

  /// Dispose
  void dispose() {
    _endCall();
  }
}
