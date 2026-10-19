import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../core/services/call_media_helper.dart';
import '../../core/services/call_signaling_crypto.dart';
import '../../core/services/feature_flag_service.dart';
import '../../core/services/identity_announcement_service.dart';
import '../../core/services/identity_service.dart';
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
import 'call_encryption_indicator.dart';
import 'fsi_prompt_decision.dart';

/// Call State Enum
enum CallState {
  idle,
  dialing, // Server searching for peer
  ringing, // Peer device alerting
  connected,
  ended,
}

enum _EncryptedCallSetup { legacyAllowed, ready, requiredUnavailable }

/// User-facing call outcome message with an optional action.
class FriendlyCallMessage {
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? action;

  const FriendlyCallMessage({
    required this.title,
    required this.body,
    this.actionLabel,
    this.action,
  });
}

/// Maps server-side call rejection / termination reason codes to plain,
/// non-technical text. The optional [onCallAsVoice] action is only offered
/// when [offerVoiceFallback] is true (the rejected call was a video call).
FriendlyCallMessage friendlyCallMessage(
  String? reason, {
  required String peerName,
  bool offerVoiceFallback = false,
  VoidCallback? onCallAsVoice,
}) {
  switch (reason) {
    case 'peer_update_required':
      if (offerVoiceFallback) {
        return FriendlyCallMessage(
          title: 'Video call not available',
          body: "$peerName's app isn't ready for video calls yet.",
          actionLabel: 'Call as voice',
          action: onCallAsVoice,
        );
      }
      return FriendlyCallMessage(
        title: 'Call not available',
        body: "$peerName's app needs an update to support this call.",
      );
    case 'encryption_required':
      return const FriendlyCallMessage(
        title: 'Secure call unavailable',
        body: 'This call requires end-to-end encryption support on both devices.',
      );
    case 'unavailable':
    case 'offline':
      return FriendlyCallMessage(
        title: 'Unavailable',
        body: '$peerName is unavailable right now.',
      );
    case 'busy':
      return FriendlyCallMessage(
        title: 'Busy',
        body: '$peerName is on another call.',
      );
    case 'declined':
    case 'rejected':
      return FriendlyCallMessage(
        title: 'Call declined',
        body: '$peerName declined the call.',
      );
    case 'timeout':
    case 'no_answer':
      return FriendlyCallMessage(
        title: 'No answer',
        body: "$peerName didn't answer.",
      );
    case 'duplicate_session':
      return const FriendlyCallMessage(
        title: 'Call failed',
        body: 'A call is already starting. Please try again.',
      );
    case 'identity_announce_required':
    case 'identity_binding_required':
    case 'identity_conflict':
    case 'identity_invalid':
      return const FriendlyCallMessage(
        title: 'Secure call unavailable',
        body: 'Verify this contact before calling.',
      );
    case 'crypto_failed':
      return const FriendlyCallMessage(
        title: 'Secure call unavailable',
        body: 'Could not establish encrypted call signaling.',
      );
    case 'resync_timeout':
      return const FriendlyCallMessage(
        title: 'Call failed',
        body: 'Connection took too long to restore.',
      );
    case 'rate_limited':
      return const FriendlyCallMessage(
        title: 'Try again later',
        body: 'Too many call attempts. Please wait a moment.',
      );
    case 'ended':
      return const FriendlyCallMessage(
        title: 'Call ended',
        body: 'The call has ended.',
      );
    case 'disconnected':
    case 'connection_lost':
      return const FriendlyCallMessage(
        title: 'Connection lost',
        body: 'The call was disconnected.',
      );
    case 'expired':
      return const FriendlyCallMessage(
        title: 'Call ended',
        body: 'This call is no longer active.',
      );
    default:
      return const FriendlyCallMessage(
        title: 'Call failed',
        body: "Couldn't start the call. Please try again.",
      );
  }
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
  final RxString remoteAvatarUrl = ''.obs;
  final RxString currentCallId = ''.obs;
  final RxBool isCaller = false.obs;
  final RxString callerDisplayName = ''.obs;
  final RxBool isCallMinimized = false.obs;
  final RxBool isVideoCall = false.obs;
  final RxBool isCameraOn = false.obs;
  final RxBool isFrontCamera = true.obs;
  final RxBool peerCameraOff = false.obs;
  final RxBool isReconnecting = false.obs;
  final RxBool hasPoorConnection = false.obs;
  final Rxn<MediaStream> localVideoStream = Rxn<MediaStream>();
  final Rxn<MediaStream> remoteVideoStream = Rxn<MediaStream>();
  final Rx<CallEncryptionState> callEncryptionState =
      CallEncryptionState.legacyUnencrypted.obs;

  // Proximity sensor state - managed by ProximityService
  final RxBool isNearEar = false.obs;

  // Call data
  Timer? _durationUpdateTimer;
  Timer? _pendingAcceptedCallWatchTimer;

  // Buffer for ICE candidates generated before server callId is known (caller only)
  // or before the encrypted signaling handshake completes.
  final List<Map<String, dynamic>> _pendingIceCandidates = [];

  // Per-call encrypted signaling state. The caller supplies the 128-bit
  // session ID; the server adopts it as the call ID for encrypted calls.
  CallSignalingCrypto? _signalingCrypto;
  String? _cryptoSessionId;
  String? _peerCryptoBundle;
  Uint8List? _incomingCallerFp;
  List<Uint8List> _incomingOfferFps = const [];
  bool _cryptoActive = false;
  bool _cryptoHandshakeReady = false;
  bool _cryptoAnswerInFlight = false;
  bool _videoRequested = false;

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

  // Tracks if the call was answered from background (for speaker state restoration)
  bool _answeredFromBackground = false;

  // Tracks if the app was launched from killed state for this call (so we close the app on call end)
  bool _launchedForCall = false;

  // Tracks camera state while Android Telecom / iOS CallKit holds the call
  bool _nativeCallHeld = false;
  bool _cameraWasOnBeforeNativeHold = false;

  // Full-screen-intent state: true while USE_FULL_SCREEN_INTENT is denied
  // (incoming calls fall back to a heads-up notification). When a call rings
  // while denied, _fsiPromptPending defers the settings dialog until the call
  // ends so it never covers the incoming-call UI.
  bool _fsiDenied = false;
  bool _fsiPromptPending = false;

  // Prevents duplicate handling of the same native answer/decline action
  String? _lastHandledNativeCallId;

  // Native call event stream subscription
  StreamSubscription? _callEventSubscription;
  StreamSubscription<List<ConnectivityResult>>? _callConnectivitySubscription;
  Worker? _videoWakelockWorker;
  List<ConnectivityResult>? _lastConnectivity;
  bool _iceRestartInFlight = false;

  @override
  void onInit() {
    super.onInit();
    debugPrint('📞 CallController onInit called');
    _initializeWebrtcService();
    _setupSocketListeners();
    _setupCallConnectivityMonitor();
    _videoWakelockWorker = ever(isVideoCall, (video) {
      if (video) {
        unawaited(WakelockPlus.enable());
      } else {
        unawaited(WakelockPlus.disable());
      }
    });

    // If the socket reconnects while we have a pending auto-accept (e.g. cold-start
    // accept where the first resync request failed), send the resync again.
    // Same for a caller whose socket dropped mid-dial: the server preserves the
    // unanswered session for ~45s, so a resync re-links the fresh socket to the
    // call and re-delivers CALL_ACCEPTED if the callee already answered.
    // For an established call, probe the server so we can end locally if the
    // call was cleaned up while we were offline.
    ever(_socketService.isRegistered, (registered) {
      if (!registered) return;
      if (_pendingAutoAcceptCallId != null) {
        final callId = _pendingAutoAcceptCallId!;
        debugPrint(
          '📞 Socket reconnected with pending auto-accept, requesting resync for $callId',
        );
        _socketService.requestCallResync(callId: callId);
      } else if (currentCallId.value.isNotEmpty && isInCall) {
        if (isCaller.value && !isConnected) {
          debugPrint(
            '📞 Socket reconnected while dialing, requesting resync for ${currentCallId.value}',
          );
          _socketService.requestCallResync(callId: currentCallId.value);
        } else {
          debugPrint(
            '📞 Socket reconnected mid-call, requesting status for ${currentCallId.value}',
          );
          _socketService.requestCallStatus(callId: currentCallId.value);
        }
      }
    });

    _setupCallKitListener();
    _setupNotificationActionListener();
    _setupNativeCallEventListener();
    _checkFullScreenIntentPermission();
    debugPrint(
      '📞 CallController setup complete, checking pending auto-accept',
    );
    _checkPendingAutoAccept(maxRetries: 100);
    _pendingAcceptedCallWatchTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _watchForPendingAcceptedCall(),
    );
  }

  @override
  void onReady() {
    super.onReady();
    // Runs after the first frame — the GetMaterialApp navigator exists here.
    // If this ran in onInit (which fires before runApp on cold start),
    // Get.offNamed to /call/active could execute before the navigator exists
    // and the incoming-call accept would silently land on the chat list.
    _checkPendingCallAction();
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
      _callEventSubscription =
          _callEventsChannel.receiveBroadcastStream().listen(
        (dynamic event) {
          if (event is Map) {
            debugPrint('📞 Native call event received: $event');
            final data = event.cast<String, dynamic>();
            final type = data['type'] as String?;
            if (type == 'call_held') {
              _handleCallHeld();
            } else if (type == 'call_unheld') {
              _handleCallUnheld();
            } else {
              _handleNativeShowFlutterCall(data);
            }
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

  /// On Android 14+, USE_FULL_SCREEN_INTENT is auto-granted only for calling
  /// apps installed from Play Store. Sideloaded builds and some OEMs (Infinix,
  /// Xiaomi) deny it, which means incoming calls only show a heads-up
  /// notification instead of the full-screen call UI.
  ///
  /// The check runs on every app start and is re-run when an incoming call
  /// arrives while the permission is denied (set via [prompt] = false there so
  /// the dialog never covers the incoming-call UI — it is deferred to the end
  /// of the call instead). 'fsi_dont_ask_again' is only written when the user
  /// explicitly picks "Don't ask again"; "Later" leaves the prompt eligible
  /// for the next opportunity.
  Future<void> _checkFullScreenIntentPermission({bool prompt = true}) async {
    if (!Platform.isAndroid) return;
    try {
      final granted = await _incomingCallChannel.invokeMethod<bool>(
        'canUseFullScreenIntent',
      );
      final prefs = await SharedPreferences.getInstance();
      final dontAskAgain = prefs.getBool('fsi_dont_ask_again') == true;

      if (granted == true) {
        _fsiDenied = false;
        // Clear the flag so a later revocation prompts again.
        if (dontAskAgain) await prefs.remove('fsi_dont_ask_again');
        return;
      }

      _fsiDenied = true;
      debugPrint(
        '⚠️ Full-screen intent denied — incoming calls will only show a notification',
      );

      if (!prompt ||
          decideFsiPrompt(
                canUseFullScreenIntent: false,
                dontAskAgain: dontAskAgain,
              ) !=
              FsiPromptDecision.showDialog) {
        return;
      }

      debugPrint('⚠️ Prompting user to enable full-screen intent');
      Get.dialog(
        AlertDialog(
          title: const Text('Show Calls Full Screen'),
          content: const Text(
            'Vant needs permission to show incoming calls on the whole '
            'screen, like WhatsApp. Without it, calls only appear as a '
            'notification you have to pull down and tap.',
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await prefs.setBool('fsi_dont_ask_again', true);
                Get.back();
              },
              child: const Text("Don't ask again"),
            ),
            TextButton(
              onPressed: () => Get.back(),
              child: const Text('Later'),
            ),
            TextButton(
              onPressed: () {
                Get.back();
                _incomingCallChannel.invokeMethod(
                  'openFullScreenIntentSettings',
                );
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
        barrierDismissible: false,
      );
    } catch (e) {
      debugPrint('⚠️ Failed to check full-screen intent permission: $e');
    }
  }

  /// Called when Telecom puts the Vant call on hold (e.g. user answered a
  /// regular phone call or WhatsApp call while on a Vant call).
  void _handleCallHeld() {
    debugPrint('📞 Vant call held by Telecom/CallKit (external call answered)');
    if (_nativeCallHeld) return;
    _nativeCallHeld = true;
    _cameraWasOnBeforeNativeHold = isVideoCall.value && isCameraOn.value;
    _webrtcService.setMuted(true);
    if (_cameraWasOnBeforeNativeHold) {
      unawaited(setCameraEnabled(false));
    }
    // Keep the call state as connected — the native connection is on hold,
    // not ended. Audio is muted and video capture is paused until resumed.
  }

  /// Called when Telecom resumes the Vant call after the external call ends.
  void _handleCallUnheld() {
    debugPrint('📞 Vant call unheld by Telecom/CallKit (external call ended)');
    _webrtcService.setMuted(false);
    if (_nativeCallHeld &&
        _cameraWasOnBeforeNativeHold &&
        isVideoCall.value &&
        isInCall) {
      unawaited(setCameraEnabled(true));
    }
    _nativeCallHeld = false;
    _cameraWasOnBeforeNativeHold = false;
  }

  void _handleNativeShowFlutterCall(Map<String, dynamic> data) {
    final callId = data['call_id'] as String?;
    if (callId == null || callId.isEmpty) return;

    // Prevent duplicate UI if the call screen is already open
    if (Get.currentRoute == '/call/incoming' ||
        Get.currentRoute == '/call/active' ||
        Get.currentRoute == '/call/video') {
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
    remoteAvatarUrl.value = callData['avatarUrl'] as String? ?? '';
    _latestIncomingCallData = callData;
    _setCallScreenVisible(true);
    _showWhenLocked();
    Get.toNamed('/call/incoming', arguments: callData);
  }

  /// Notify native layers whether a Vant call is active.
  /// Used so incoming calls from other apps don't accidentally replace or kill
  /// the current call.
  Future<void> _setNativeInCall(bool inCall) async {
    try {
      await _callChannel.invokeMethod('setInCall', {
        'inCall': inCall,
        'callId': currentCallId.value,
        'isVideo': inCall && isVideoCall.value,
      });
    } catch (e) {
      debugPrint('⚠️ Failed to sync in-call state to native: $e');
    }
  }

  Future<void> _refreshAndroidOngoingCallNotification() async {
    if (!Platform.isAndroid) return;
    try {
      await _callChannel.invokeMethod('startOngoingCall', {
        'callId': currentCallId.value,
        'callerName': remoteDisplayName.value.isNotEmpty
            ? remoteDisplayName.value
            : 'Unknown',
        'isVideo': isVideoCall.value && _webrtcService.isCameraEnabled,
      });
    } catch (e) {
      debugPrint('⚠️ Failed to refresh ongoing call service: $e');
    }
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
    final answeredFromBackground = data['answered_from_background'] == 'true';
    final fromNative = data['from_native'] == 'true';

    if (callId == null || callId.isEmpty) return;

    // Prevent duplicate handling from both the pending-intent path and the
    // CALL_CHANNEL onCallAction path firing on cold start — but only treat it
    // as handled when the call is actually being handled (screen shown or
    // connected). A first attempt can run before runApp() on cold start, where
    // Get.offNamed has no navigator and silently no-ops; we must allow the
    // retry from getPendingCallAction (fired onReady) to proceed.
    if (_lastHandledNativeCallId == callId &&
        (isInCall ||
            Get.currentRoute == '/call/active' ||
            Get.currentRoute == '/call/video')) {
      debugPrint(
        '📞 Native answer for $callId already handled, skipping duplicate',
      );
      return;
    }
    _lastHandledNativeCallId = callId;

    currentCallId.value = callId;
    remoteDeviceId.value = data['caller_id'] ?? '';
    isCaller.value = false;
    remoteDisplayName.value = data['caller_name'] ?? 'Incoming Call';
    remoteAvatarUrl.value = data['avatar_url'] as String? ?? '';

    final callData = {
      'callId': callId,
      'callerId': data['caller_id'] ?? '',
      'callerName': data['caller_name'] ?? 'Incoming Call',
      'sdpOffer': null,
      'roomId': data['room_id'] ?? '',
      'avatarUrl': data['avatar_url'] ?? '',
      'isVideo': data['is_video'] == 'true',
    };
    _videoRequested = callData['isVideo'] == true && _videoCallingEnabled;
    isVideoCall.value = false;
    if (Get.currentRoute != activeCallRoute) {
      Get.offNamed(activeCallRoute, arguments: callData);
    }
    await setPendingAutoAccept(callId);

    // CRITICAL: Initialize audio mode before connecting to call
    // This prevents the 60-second speaker delay when accepting from native screen
    debugPrint(
        '📞 Answer from native screen: $fromNative, initializing audio mode');
    await _initializeAudioMode();

    _setCallScreenVisible(true);
    await _stopNativeIncomingCall();
    _dismissKeyguard();

    final locked = await _isScreenLocked();
    if (locked) {
      _acceptedFromLockScreen = true;
      _showWhenLocked();
    }

    // Store flag that this call was answered from background
    if (answeredFromBackground) {
      debugPrint(
          '📞 Call answered from background - will restore speaker state after connection');
      _answeredFromBackground = true;
    }

    // Cold-start accept happens before the socket is connected. Wait for it so
    // we can actually send the resync request and accept the call.
    await _socketService.reconnectForCallResync();
    final socketReady = await _waitForSocketConnection();
    if (!socketReady) {
      // Cold-start registration (auth + device register) can exceed the wait.
      // Keep the pending auto-accept: the ever(isRegistered) listener will
      // request the resync automatically when the socket finishes registering.
      // The active call screen stays up showing the connecting state.
      debugPrint(
          '⚠️ Socket not registered yet — resync will retry on registration');
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
      _socketService.requestCallResync(callId: callId);
    }
  }

  Future<void> _handleNativeDecline(Map<String, dynamic> data) async {
    final callId = data['call_id'] as String?;
    if (callId == null || callId.isEmpty) return;

    // Same dedup semantics as _handleNativeAnswer: only skip when this call is
    // already over. Decline is idempotent — retrying after a failed first
    // attempt just emits the rejection again.
    if (_lastHandledNativeCallId == callId &&
        !isInCall &&
        currentCallId.value != callId) {
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
    _pendingAcceptedCallWatchTimer?.cancel();
    _pendingAcceptedCallWatchTimer = null;
    _callEventSubscription?.cancel();
    _callEventSubscription = null;
    _callConnectivitySubscription?.cancel();
    _callConnectivitySubscription = null;
    // Only cleanup if not in an active call
    // This prevents call from ending when navigating between screens
    if (!isInCall) {
      _cleanup();
    }
    super.onClose();
  }

  /// Initialize WebRTC service
  Future<void> _initializeWebrtcService() async {
    _webrtcService.iceServersProvider = _socketService.requestIceServers;
    await _webrtcService.initialize();

    // Setup WebRTC callbacks
    _webrtcService.onLocalStream = (stream) {
      localVideoStream.value = stream;
      if (stream.getVideoTracks().isNotEmpty) {
        isCameraOn.value = _webrtcService.isCameraEnabled;
        isFrontCamera.value = _webrtcService.isFrontCamera;
      }
    };

    _webrtcService.onRemoteStream = (stream) {
      remoteVideoStream.value = stream;
    };

    _webrtcService.onCallStateChange = (state, {reason}) {
      _handleCallStateChange(state, reason: reason);
    };

    _webrtcService.onCallEnded = (callId) {
      _handleCallEnded(callId);
    };

    _webrtcService.onIceCandidate = (candidate, sdpMid, sdpMLineIndex) {
      unawaited(_handleIceCandidate(candidate, sdpMid, sdpMLineIndex));
    };

    _webrtcService.onLocalDescription = (sdp) {
      unawaited(_handleLocalDescription(sdp));
    };

    _webrtcService.onIceRestartDescription = (sdp, isOffer) {
      unawaited(_sendIceRestartDescription(sdp, isOffer));
    };

    _webrtcService.onIceRestartNeeded = (_) {
      if (_videoCallingEnabled && isInCall) {
        isReconnecting.value = true;
        hasPoorConnection.value = true;
      }
      unawaited(_requestIceRestart());
    };

    _webrtcService.onConnectionFailed = (_) {
      if (!_videoCallingEnabled) {
        endCall();
        return;
      }
      unawaited(_requestIceRestart(fatalOnFailure: true));
    };

    _webrtcService.onCameraPermissionDenied = () {
      _videoRequested = false;
      isVideoCall.value = false;
      isCameraOn.value = false;
      Get.snackbar(
        'Camera unavailable',
        'Camera permission was denied. Continuing with audio only.',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 4),
      );
      if (Get.currentRoute == '/call/video') {
        Get.offNamed('/call/active');
      }
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
      unawaited(_handleCallAccepted(data));
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
      unawaited(_handleRemoteIceCandidate(data));
    };

    _socketService.onPeerRinging = (data) {
      _handlePeerRinging(data);
    };

    _socketService.onIceRestart = (data) {
      unawaited(_handleIceRestart(data));
    };

    _socketService.onCallMediaUpdate = (data) {
      _handleCallMediaUpdate(data);
    };

    _socketService.onCallResync = (data) {
      _handleCallResync(data);
    };

    _socketService.onCallStatusResponse = (data) {
      _handleCallStatusResponse(data);
    };
  }

  void _setupCallConnectivityMonitor() {
    Connectivity().checkConnectivity().then((results) {
      _lastConnectivity = results;
    });
    _callConnectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      final switched = CallMediaHelper.wifiMobileSwitch(
        before: _lastConnectivity,
        after: results,
      );
      _lastConnectivity = results;
      if (switched) unawaited(_requestIceRestart());
    });
  }

  String get remoteDisplayLabel {
    final name = remoteDisplayName.value.trim();
    if (name.isNotEmpty &&
        name != 'Unknown' &&
        name != 'Incoming Call' &&
        name != remoteDeviceId.value) {
      return name;
    }
    final deviceId = remoteDeviceId.value;
    return deviceId.isNotEmpty
        ? StringUtils.generateFriendlyName(deviceId)
        : 'Unknown';
  }

  bool get _videoCallingEnabled =>
      Get.isRegistered<FeatureFlagService>() &&
      Get.find<FeatureFlagService>().videoCalling.value;

  void prepareVideoCallScreen(String peerDeviceId, {required bool incoming}) {
    if (!_videoCallingEnabled) return;
    remoteDeviceId.value = peerDeviceId;
    remoteAvatarUrl.value = '';
    isCaller.value = !incoming;
    _videoRequested = true;
    isVideoCall.value = true;
    isCameraOn.value = false;
    peerCameraOff.value = false;
    _resolveDisplayName(peerDeviceId);
  }

  bool get _encryptedSignalingEnabled =>
      Get.isRegistered<FeatureFlagService>() &&
      Get.find<FeatureFlagService>().encryptedSignaling.value;

  void _updateCallEncryptionState(String peerDeviceId) {
    if (!_cryptoActive) {
      callEncryptionState.value = CallEncryptionState.legacyUnencrypted;
      return;
    }
    if (!_cryptoHandshakeReady) {
      callEncryptionState.value = CallEncryptionState.securing;
      return;
    }
    callEncryptionState.value =
        _storageService.getPeerVerificationStatus(peerDeviceId) == 'verified'
            ? CallEncryptionState.encryptedVerified
            : CallEncryptionState.encryptedUnverified;
  }

  CallSignalingCrypto? _createSignalingCrypto(String peerDeviceId) {
    if (!_encryptedSignalingEnabled || !Get.isRegistered<IdentityService>()) {
      return null;
    }
    final identity = Get.find<IdentityService>();
    final deviceId = _storageService.deviceId;
    if (!identity.hasIdentity.value || deviceId == null || deviceId.isEmpty) {
      return null;
    }
    return CallSignalingCrypto(
      dh: identity.x25519SharedSecret,
      sign: identity.signBytes,
      myDeviceId: deviceId,
      resolvePeerBundle: _storageService.getPeerBundle,
    );
  }

  String _newCryptoSessionId() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    return 'cs_${base64UrlEncode(bytes).replaceAll('=', '')}';
  }

  Map<String, dynamic>? _wireCrypto(Map<String, dynamic>? data) {
    final crypto = data?['crypto'];
    return crypto is Map ? Map<String, dynamic>.from(crypto) : null;
  }

  String? _wireString(Map<String, dynamic> map, String key) {
    final value = map[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  Uint8List? _wireBytes(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! String || value.isEmpty) return null;
    try {
      return Uint8List.fromList(base64Decode(value));
    } catch (_) {
      return null;
    }
  }

  List<Uint8List>? _wireByteList(Map<String, dynamic> map, String key) {
    final values = map[key];
    if (values is! List) return null;
    final decoded = <Uint8List>[];
    for (final item in values) {
      if (item is! String) return null;
      try {
        decoded.add(Uint8List.fromList(base64Decode(item)));
      } catch (_) {
        return null;
      }
    }
    return decoded;
  }

  bool _sameFingerprints(List<Uint8List> a, List<Uint8List> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
      for (var j = 0; j < a[i].length; j++) {
        if (a[i][j] != b[i][j]) return false;
      }
    }
    return true;
  }

  Future<Map<String, dynamic>?> _encryptSignal(
    String event,
    String plaintext,
  ) async {
    final crypto = _signalingCrypto;
    final sessionId = _cryptoSessionId;
    if (crypto == null || sessionId == null || !_cryptoHandshakeReady) {
      return null;
    }
    final encrypted = await crypto.encryptMessage(
      event: event,
      plaintext: plaintext,
    );
    return {'v': 1, 'sessionId': sessionId, 'enc': encrypted};
  }

  Future<String?> _decryptSignal(
    String event,
    Map<String, dynamic>? cryptoPayload,
    String encryptedKey,
  ) async {
    final crypto = _signalingCrypto;
    final sessionId = _cryptoSessionId;
    if (crypto == null || sessionId == null || cryptoPayload == null) {
      return null;
    }
    if (cryptoPayload['v'] != 1 || cryptoPayload['sessionId'] != sessionId) {
      return null;
    }
    final encrypted = cryptoPayload[encryptedKey];
    if (encrypted is! Map) return null;
    final record = <String, String>{};
    for (final key in const ['n', 'c', 'k']) {
      final value = encrypted[key];
      if (value is! String) return null;
      record[key] = value;
    }
    try {
      return await crypto.decryptMessage(event: event, encrypted: record);
    } on CallSignalingCryptoException catch (e) {
      debugPrint('⚠️ Encrypted call signal rejected: ${e.message}');
      if (e.message == 'crypto_failed') {
        endCall();
      }
      return null;
    }
  }

  Future<bool> _peerSupportsVideo(
    String deviceId, [
    Map<String, dynamic>? info,
  ]) async {
    final peerInfo =
        info ?? await _socketService.requestPeerCapabilities(deviceId);
    final capabilities = peerInfo?['capabilities'];
    return CallMediaHelper.peerSupportsVideo(
      clientVersion: peerInfo?['clientVersion'] as String?,
      capabilities: capabilities is List ? capabilities.cast<String>() : null,
    );
  }

  bool _peerRequiresEncryptedCall(String peerDeviceId) {
    return CallMediaHelper.peerRequiresEncryptedCall(
      hasPinnedIdentity: _storageService.getPeerBundle(peerDeviceId) != null,
      signedEncryptedCapability:
          _storageService.peerSignedEncryptedCalls(peerDeviceId),
      encryptedCallSeen:
          _storageService.peerHasEncryptedCallHistory(peerDeviceId),
    );
  }

  Future<void> _recordPeerKeyChanged(
    String peerDeviceId,
    String observedBundle,
  ) async {
    await _storageService.pinPeerBundle(peerDeviceId, observedBundle);
    if (Get.isRegistered<IdentityAnnouncementService>()) {
      Get.find<IdentityAnnouncementService>()
          .keyChangedConflicts
          .add(peerDeviceId);
    }
    Get.snackbar(
      'Security warning',
      'This contact\'s encryption key changed. Verify them before calling.',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 6),
    );
  }

  Future<_EncryptedCallSetup> _prepareEncryptedCaller(
    String calleeDeviceId,
    Map<String, dynamic>? peerInfo, {
    bool encryptionRequired = false,
  }) async {
    _resetCryptoState();
    final pinnedBundle = _storageService.getPeerBundle(calleeDeviceId);
    final serverBundle = peerInfo?['identityBundle'] as String?;
    if (pinnedBundle != null &&
        serverBundle != null &&
        pinnedBundle != serverBundle) {
      await _recordPeerKeyChanged(calleeDeviceId, serverBundle);
      return _EncryptedCallSetup.requiredUnavailable;
    }

    final historicallyEncrypted = CallMediaHelper.peerRequiresEncryptedCall(
      hasPinnedIdentity: pinnedBundle != null,
      signedEncryptedCapability:
          _storageService.peerSignedEncryptedCalls(calleeDeviceId),
      encryptedCallSeen:
          _storageService.peerHasEncryptedCallHistory(calleeDeviceId),
    );
    final required = encryptionRequired || historicallyEncrypted;
    if (!_encryptedSignalingEnabled) {
      return required
          ? _EncryptedCallSetup.requiredUnavailable
          : _EncryptedCallSetup.legacyAllowed;
    }

    final capabilities = peerInfo?['capabilities'];
    final supportsEncrypted =
        (capabilities is List && capabilities.contains('encrypted_call')) ||
            historicallyEncrypted;
    _peerCryptoBundle = pinnedBundle ?? serverBundle;
    if (!supportsEncrypted || _peerCryptoBundle == null) {
      return required
          ? _EncryptedCallSetup.requiredUnavailable
          : _EncryptedCallSetup.legacyAllowed;
    }
    _signalingCrypto = _createSignalingCrypto(calleeDeviceId);
    if (_signalingCrypto == null) {
      return required
          ? _EncryptedCallSetup.requiredUnavailable
          : _EncryptedCallSetup.legacyAllowed;
    }
    _cryptoSessionId = _newCryptoSessionId();
    _cryptoActive = true;
    _updateCallEncryptionState(calleeDeviceId);
    return _EncryptedCallSetup.ready;
  }

  Future<void> _requestIceRestart({bool fatalOnFailure = false}) async {
    if (!_videoCallingEnabled || !isInCall || _iceRestartInFlight) return;
    _iceRestartInFlight = true;
    isReconnecting.value = true;
    try {
      final restarted = await _webrtcService.restartIce();
      if (!restarted && !_webrtcService.isIceRestartInProgress) {
        isReconnecting.value = false;
        if (fatalOnFailure) endCall();
      }
    } finally {
      _iceRestartInFlight = false;
    }
  }

  Future<void> _sendIceRestartDescription(String sdp, bool isOffer) async {
    Map<String, dynamic>? cryptoPayload;
    if (_cryptoActive) {
      cryptoPayload = await _encryptSignal(
        'ice_restart',
        jsonEncode({'sdp': sdp, 'type': isOffer ? 'offer' : 'answer'}),
      );
      if (cryptoPayload == null) return;
    }
    _socketService.requestIceRestart(
      callId: currentCallId.value,
      targetDeviceId: remoteDeviceId.value,
      sdpOffer: !_cryptoActive && isOffer ? sdp : null,
      sdpAnswer: !_cryptoActive && !isOffer ? sdp : null,
      crypto: cryptoPayload == null
          ? null
          : {
              'v': 1,
              'sessionId': _cryptoSessionId,
              'iceRestartEnc': cryptoPayload['enc'],
            },
    );
  }

  Future<void> _handleIceRestart(Map<String, dynamic> data) async {
    if ((data['callId'] as String?) != currentCallId.value ||
        !_videoCallingEnabled) {
      return;
    }

    if (_cryptoActive) {
      final plaintext = await _decryptSignal(
        'ice_restart',
        _wireCrypto(data),
        'iceRestartEnc',
      );
      if (plaintext == null) return;
      try {
        final decoded = jsonDecode(plaintext);
        if (decoded is! Map || decoded['sdp'] is! String) return;
        if (decoded['type'] == 'offer') {
          final handled = await _webrtcService.handleIceRestartOffer(
            decoded['sdp'] as String,
            acceptDuringLocalRestart:
                CallMediaHelper.acceptRemoteIceRestartOffer(
              localRestartInProgress: _webrtcService.isIceRestartInProgress,
              isCaller: isCaller.value,
            ),
          );
          if (handled) {
            isVideoCall.value = _webrtcService.isVideoCall;
            isCameraOn.value = _webrtcService.isCameraEnabled;
            isFrontCamera.value = _webrtcService.isFrontCamera;
            if (isCameraOn.value) {
              _videoRequested = true;
              unawaited(_refreshAndroidOngoingCallNotification());
              _stopProximitySensor();
              if (Get.currentRoute == '/call/active') {
                Get.offNamed('/call/video');
              }
            } else {
              _videoRequested = false;
              _sendCallMediaUpdate(
                video: false,
                reason: 'camera not available during ICE restart',
              );
            }
          }
        } else if (decoded['type'] == 'answer') {
          await _webrtcService.handleIceRestartAnswer(decoded['sdp'] as String);
        }
      } catch (_) {}
      return;
    }

    if (_wireCrypto(data) != null) return;
    final offer = data['sdpOffer'] as String?;
    final answer = data['sdpAnswer'] as String?;
    if (offer != null && offer.isNotEmpty) {
      final handled = await _webrtcService.handleIceRestartOffer(
        offer,
        acceptDuringLocalRestart: CallMediaHelper.acceptRemoteIceRestartOffer(
          localRestartInProgress: _webrtcService.isIceRestartInProgress,
          isCaller: isCaller.value,
        ),
      );
      if (handled) {
        isVideoCall.value = _webrtcService.isVideoCall;
        isCameraOn.value = _webrtcService.isCameraEnabled;
        isFrontCamera.value = _webrtcService.isFrontCamera;
      }
      return;
    }
    if (answer != null && answer.isNotEmpty) {
      await _webrtcService.handleIceRestartAnswer(answer);
      return;
    }
    await _requestIceRestart();
  }

  void _handleCallMediaUpdate(Map<String, dynamic> data) {
    if ((data['callId'] as String?) != currentCallId.value ||
        (!isVideoCall.value && !_videoRequested)) {
      return;
    }
    peerCameraOff.value = data['video'] == 'off';
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
          final answeredFromBackground =
              call.arguments['answeredFromBackground'] as bool? ?? false;

          debugPrint(
              '📞 Native call action: $action for call $callId, answeredFromBackground: $answeredFromBackground');

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
              remoteAvatarUrl.value = callData['avatarUrl'] as String? ?? '';
              _latestIncomingCallData = callData;
              Get.toNamed('/call/incoming', arguments: callData);
            }
            return;
          }

          if (action == 'open_ongoing_call') {
            debugPrint('📞 Notification tap: open ongoing call screen');
            if (isConnected &&
                callId != null &&
                callId.isNotEmpty &&
                currentCallId.value == callId) {
              if (Get.currentRoute != activeCallRoute) {
                Get.offAllNamed(activeCallRoute);
              }
            }
            return;
          }

          if (action == 'call_held') {
            _handleCallHeld();
          } else if (action == 'call_unheld') {
            _handleCallUnheld();
          } else if (action == 'answer') {
            await _handleNativeAnswer({
              'call_id': callId ?? '',
              'caller_id': callerId ?? '',
              'caller_name': callerName ?? 'Incoming Call',
              'room_id': roomId ?? '',
              'avatar_url': avatarUrl ?? '',
              'is_video': isVideo ? 'true' : 'false',
              'answered_from_background':
                  answeredFromBackground ? 'true' : 'false',
              'from_native': 'true',
            });
          } else if (action == 'decline') {
            await _handleNativeDecline({
              'call_id': callId ?? '',
              'caller_id': callerId ?? '',
              'caller_name': callerName ?? 'Incoming Call',
            });
          } else if (action == 'end' &&
              callId != null &&
              callId.isNotEmpty &&
              currentCallId.value == callId) {
            endCall();
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
              if (Get.currentRoute != activeCallRoute) {
                Get.offAllNamed(activeCallRoute);
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
    if (_lastHandledNativeCallId == callId) {
      debugPrint(
          '📞 CallKit accept for $callId already handled, skipping duplicate');
      return;
    }
    _lastHandledNativeCallId = callId;
    await clearPendingAutoAccept();
    debugPrint('📞 CallKit accept received for $callId');

    // If device is locked, mark so we relock when the call ends
    final locked = await _isScreenLocked();
    if (locked) {
      _acceptedFromLockScreen = true;
      _showWhenLocked();
    }

    // Dismiss keyguard on Android to allow call to connect without unlock
    _dismissKeyguard();

    await setPendingAutoAccept(callId);
    await _socketService.reconnectForCallResync();
    final socketReady = await _waitForSocketConnection();
    if (!socketReady) {
      debugPrint('⚠️ CallKit accept: socket not connected, resync deferred');
      return;
    }

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
    final callerId =
        extra?['callerId'] as String? ?? extra?['caller_id'] as String? ?? '';
    final callerName = extra?['callerName'] as String? ??
        extra?['caller_name'] as String? ??
        'Incoming Call';
    final roomId =
        extra?['roomId'] as String? ?? extra?['room_id'] as String? ?? '';
    final avatarUrl =
        extra?['avatarUrl'] as String? ?? extra?['avatar_url'] as String? ?? '';
    final isVideo = (extra?['isVideo'] as bool?) ??
        (extra?['is_video'] == true || extra?['is_video'] == 'true');

    debugPrint(
      '📞 CallKit accept: no cached SDP, setting pending auto-accept and requesting resync',
    );
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
    _socketService.requestCallResync(callId: callId);

    // Pre-populate active call info so the user sees the caller immediately.
    currentCallId.value = callId;
    remoteDeviceId.value = callerId;
    isCaller.value = false;
    remoteDisplayName.value = callerName;
    remoteAvatarUrl.value = avatarUrl;

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
    _videoRequested = isVideo == true && _videoCallingEnabled;
    isVideoCall.value = false;
    Get.offNamed(activeCallRoute, arguments: callData);
  }

  Future<void> _watchForPendingAcceptedCall() async {
    if (_isCheckingPendingAutoAccept || _pendingAutoAcceptCallId != null) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final callId = prefs.getString('pendingAcceptedCallId');
    if (callId != null && callId.isNotEmpty) {
      await _checkPendingAutoAccept(maxRetries: 1);
    }
  }

  /// Check for pending auto-accept call from background (CallKit accept)
  Future<void> _checkPendingAutoAccept({int maxRetries = 5}) async {
    if (_isCheckingPendingAutoAccept) {
      debugPrint('📞 Pending auto-accept check already in progress');
      return;
    }

    _isCheckingPendingAutoAccept = true;
    debugPrint('📞 _checkPendingAutoAccept() called');
    try {
      await _checkPendingAutoAcceptWithRetry(maxRetries: maxRetries);
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

        if (pendingCallId != null && pendingCallId.isNotEmpty) {
          debugPrint('📞 Found pending accepted call: $pendingCallId');
          final pendingCallIsVideo =
              prefs.getBool('pendingAcceptedCallIsVideo') ?? false;
          if (pendingCallIsVideo && _videoCallingEnabled) {
            _videoRequested = true;
            isVideoCall.value = false;
            isCameraOn.value = false;
          }

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
          _lastHandledNativeCallId = pendingCallId;
          await setPendingAutoAccept(pendingCallId);
          debugPrint('📞 Set pending auto-accept flag for $pendingCallId');

          final socketReady = await _waitForSocketConnection();

          if (socketReady) {
            debugPrint('📞 Requesting call resync for pending accepted call');
            _socketService.requestCallResync(callId: pendingCallId);

            // Clear the pending call ID
            await prefs.remove('pendingAcceptedCallId');
            await prefs.remove('pendingAcceptedCallIsVideo');
            debugPrint('📞 Cleared pendingAcceptedCallId');
            return; // Success, exit retry loop
          } else {
            debugPrint('⚠️ Socket not registered, cannot request call resync');
            // Clear auto-accept flag since we can't proceed
            clearPendingAutoAccept();
          }
        }
        // else {
        //   debugPrint(
        //     '📞 No pending accepted call found in storage (retry $retryCount)',
        //   );
        // }
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
  Future<bool> startCall(String calleeDeviceId, {bool isVideo = false}) async {
    try {
      final callerDeviceId = _storageService.deviceId;
      if (callerDeviceId == null) {
        debugPrint('❌ Cannot start call: No device ID');
        return false;
      }

      final wantsVideo = isVideo && _videoCallingEnabled;
      final encryptionRequired =
          wantsVideo || _peerRequiresEncryptedCall(calleeDeviceId);
      debugPrint(
        '📞 Starting ${wantsVideo ? 'video' : 'audio'} call to $calleeDeviceId',
      );

      // Populate call state before async capability/crypto work so tapping the
      // video action can open the full-screen preview route immediately.
      remoteDeviceId.value = calleeDeviceId;
      remoteAvatarUrl.value = '';
      isCaller.value = true;
      _videoRequested = wantsVideo;
      isVideoCall.value = wantsVideo;
      isCameraOn.value = false;
      peerCameraOff.value = false;
      _callStartTime = DateTime.now();
      _wasConnected = false;
      _durationSeconds = 0;
      _resolveDisplayName(calleeDeviceId);

      final peerInfo =
          wantsVideo || _encryptedSignalingEnabled || encryptionRequired
              ? await _socketService.requestPeerCapabilities(calleeDeviceId)
              : null;
      if (peerInfo == null) {
        debugPrint(
            '⚠️ Peer capability lookup returned no data for $calleeDeviceId');
      } else {
        debugPrint(
          '📞 Peer capabilities for $calleeDeviceId: '
          'clientVersion=${peerInfo['clientVersion']}, '
          'capabilities=${peerInfo['capabilities']}, '
          'hasIdentityBundle=${peerInfo['identityBundle'] != null}',
        );
      }
      if (wantsVideo && !await _peerSupportsVideo(calleeDeviceId, peerInfo)) {
        debugPrint('❌ Video call blocked: peer does not advertise video_call');
        Get.snackbar(
          'Video unavailable',
          'Ask them to update Vant to use video calls.',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 4),
        );
        _resetCallState();
        return false;
      }

      final encryptedSetup = await _prepareEncryptedCaller(
        calleeDeviceId,
        peerInfo,
        encryptionRequired: encryptionRequired,
      );
      if (encryptedSetup == _EncryptedCallSetup.requiredUnavailable ||
          (wantsVideo && encryptedSetup != _EncryptedCallSetup.ready)) {
        debugPrint('❌ Video/secure call blocked: setup=$encryptedSetup');
        Get.snackbar(
          'Secure call unavailable',
          wantsVideo
              ? 'Video calls require encrypted signaling.'
              : 'This contact requires encrypted calling.',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 4),
        );
        _resetCallState();
        return false;
      }

      // Check microphone permission before starting call
      final hasPermission = await _checkMicrophonePermission();
      if (!hasPermission) {
        debugPrint('❌ Cannot start call: Microphone permission denied');
        _webrtcService.endCall();
        _resetCallState();
        return false;
      }

      // Resolve caller's own display name to pass to backend
      await _resolveCallerDisplayName();

      // Start WebRTC call - this will trigger onLocalDescription callback.
      // The video track (if requested) is captured and added before createOffer.
      final success = await _webrtcService.startCall(
        calleeDeviceId: calleeDeviceId,
        callerDeviceId: callerDeviceId,
        isVideo: wantsVideo,
      );

      if (success) {
        isCameraOn.value = _webrtcService.isCameraEnabled;
        isFrontCamera.value = _webrtcService.isFrontCamera;
        isSpeakerOn.value = _webrtcService.isSpeakerOn;
        unawaited(_setNativeInCall(true));
        if (Platform.isAndroid) {
          unawaited(
            _callChannel.invokeMethod<bool>('reportOutgoingTelecomCall', {
              'calleeId': calleeDeviceId,
              'calleeName': remoteDisplayName.value.isNotEmpty
                  ? remoteDisplayName.value
                  : StringUtils.generateFriendlyName(calleeDeviceId),
              'isVideo': _videoRequested,
            }),
          );
        }
      }

      if (!success) {
        _webrtcService.endCall();
        _resetCallState();
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
      _webrtcService.endCall();
      _resetCallState();
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

  Future<String?> _decryptIncomingOffer(
    Map<String, dynamic> data,
    String callId,
    String callerId,
  ) async {
    final cryptoPayload = _wireCrypto(data);
    if (cryptoPayload == null) {
      _resetCryptoState();
      return data['sdpOffer'] as String?;
    }
    if (!_encryptedSignalingEnabled) {
      return null;
    }

    final crypto = _createSignalingCrypto(callerId);
    final sessionId = _wireString(cryptoPayload, 'sessionId');
    final callerEph = _wireBytes(cryptoPayload, 'callerEph');
    final callerFp = _wireBytes(cryptoPayload, 'callerFp');
    final callerBundle = _wireString(cryptoPayload, 'callerBundle');
    final encrypted = cryptoPayload['sdpOfferEnc'];
    if (crypto == null ||
        sessionId == null ||
        sessionId != callId ||
        callerEph == null ||
        callerFp == null ||
        callerBundle == null ||
        encrypted is! Map) {
      return null;
    }
    final record = <String, String>{};
    for (final key in const ['n', 'c', 'k']) {
      final value = encrypted[key];
      if (value is! String) return null;
      record[key] = value;
    }

    final pinnedBundle = _storageService.getPeerBundle(callerId);
    if (pinnedBundle != null && pinnedBundle != callerBundle) {
      await _recordPeerKeyChanged(callerId, callerBundle);
      throw const CallSignalingCryptoException('peer_key_changed');
    }

    _resetCryptoState();
    _signalingCrypto = crypto;
    _cryptoSessionId = sessionId;
    _peerCryptoBundle = callerBundle;
    _cryptoActive = true;
    final sdpOffer = await crypto.decryptOfferFirstContact(
      callId: sessionId,
      callerId: callerId,
      callerBundleB64: callerBundle,
      ephA: callerEph,
      encrypted: record,
    );
    _incomingCallerFp = callerFp;
    _incomingOfferFps = CallSignalingCrypto.extractDtlsFingerprints(sdpOffer);
    _updateCallEncryptionState(callerId);
    return sdpOffer;
  }

  void _rejectCryptoCall(String reason, {String? callId, String? callerId}) {
    final rejectCallId = callId ?? currentCallId.value;
    final rejectCallerId = callerId ?? remoteDeviceId.value;
    if (rejectCallId.isNotEmpty && rejectCallerId.isNotEmpty) {
      _socketService.rejectCall(
        callId: rejectCallId,
        callerId: rejectCallerId,
        reason: reason,
      );
    }
    _webrtcService.endCall();
    _resetCallState();
  }

  void _failCryptoCall(String reason) {
    _logCallHistory(reason: reason);
    _webrtcService.endCall();
    _resetCallState();
    final peerName = remoteDeviceId.value.isNotEmpty
        ? (remoteDisplayName.value.isNotEmpty
            ? remoteDisplayName.value
            : StringUtils.generateFriendlyName(remoteDeviceId.value))
        : 'The other person';
    // Map internal crypto failure codes to the user-facing crypto_failed reason.
    final userReason = reason == 'missing_call_crypto' ||
            reason == 'offer_failed' ||
            reason == 'missing_answer_crypto' ||
            reason == 'pin_unavailable'
        ? 'crypto_failed'
        : reason;
    _showFriendlyCallMessage(
      friendlyCallMessage(userReason, peerName: peerName),
    );
  }

  void _resetCryptoState() {
    _signalingCrypto?.dispose();
    _signalingCrypto = null;
    _cryptoSessionId = null;
    _peerCryptoBundle = null;
    _incomingCallerFp = null;
    _incomingOfferFps = const [];
    _cryptoActive = false;
    _cryptoHandshakeReady = false;
    _cryptoAnswerInFlight = false;
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
      final calleeDeviceId = _storageService.deviceId;

      if (calleeDeviceId == null) {
        debugPrint('❌ Cannot accept call: No device ID');
        return false;
      }

      final incomingVideo = callData['isVideo'] == true;
      currentCallId.value = callId;
      remoteDeviceId.value = callerId;
      isCaller.value = false;
      _videoRequested = incomingVideo;
      isVideoCall.value = incomingVideo && _videoCallingEnabled;
      isCameraOn.value = false;
      peerCameraOff.value = false;
      _resolveDisplayName(callerId);

      if (incomingVideo && !_videoCallingEnabled) {
        _socketService.rejectCall(
          callId: callId,
          callerId: callerId,
          reason: 'peer_update_required',
        );
        _resetCallState();
        return false;
      }
      if (_wireCrypto(callData) == null &&
          (incomingVideo || _peerRequiresEncryptedCall(callerId))) {
        _socketService.rejectCall(
          callId: callId,
          callerId: callerId,
          reason: 'encryption_required',
        );
        _resetCallState();
        return false;
      }

      // Check microphone permission before accepting call
      final hasPermission = await _checkMicrophonePermission();
      if (!hasPermission) {
        debugPrint('❌ Cannot accept call: Microphone permission denied');
        _resetCallState();
        return false;
      }

      String? sdpOffer = callData['decryptedSdpOffer'] as String?;
      try {
        sdpOffer ??= await _decryptIncomingOffer(callData, callId, callerId);
      } catch (e) {
        debugPrint('❌ Encrypted offer rejected: $e');
        sdpOffer = null;
      }
      if (sdpOffer == null) {
        _rejectCryptoCall('crypto_failed', callId: callId, callerId: callerId);
        return false;
      }

      // CRITICAL: Initialize audio mode before accepting call
      // This ensures MODE_IN_COMMUNICATION is set before WebRTC takes over
      await _initializeAudioMode();
      unawaited(_setNativeInCall(true));

      // Accept WebRTC call - this will trigger onLocalDescription callback with answer.
      // The video track (if requested) is captured and added before createAnswer.
      _webrtcService.primeIceServers(callData['iceServers']);
      final success = await _webrtcService.acceptCall(
        callId: callId,
        callerDeviceId: callerId,
        calleeDeviceId: calleeDeviceId,
        sdpOffer: sdpOffer,
        isVideo: incomingVideo,
      );

      if (success) {
        isCameraOn.value = _webrtcService.isCameraEnabled;
        isFrontCamera.value = _webrtcService.isFrontCamera;
        isSpeakerOn.value = _webrtcService.isSpeakerOn;
        isVideoCall.value = incomingVideo && _webrtcService.isVideoCall;
      }

      if (!success) {
        _webrtcService.endCall();
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
      _webrtcService.endCall();
      _resetCallState();
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

    _webrtcService.endCall();
    _resetCallState();
  }

  /// Reset call state when we know the call has already ended remotely (e.g. FCM
  /// call_cancelled) without sending another terminate event to the server.
  void resetCallStateForRemoteEnd() {
    _ringtoneService.stopRingtone();
    _webrtcService.endCall();
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

  /// Minimize the call screen so the user can keep using the app while the
  /// call continues. The persistent call banner stays visible at the top and
  /// tapping it returns to the full-screen call UI.
  void minimizeCallScreen(BuildContext context) {
    isCallMinimized.value = true;
    if (Navigator.of(context).canPop()) {
      Get.back();
    } else {
      // Call screen is the only route (e.g. opened from a notification or a
      // cold start) — land on the chat list instead of exiting the app.
      Get.offAllNamed('/chat-list');
    }
  }

  String get activeCallRoute =>
      (_videoRequested || isVideoCall.value) && _videoCallingEnabled
          ? '/call/video'
          : '/call/active';

  void restoreCallScreen() {
    isCallMinimized.value = false;
    final route = (_videoRequested || isVideoCall.value)
        ? activeCallRoute
        : isCaller.value && isConnecting
            ? '/call/outgoing'
            : '/call/active';
    Get.toNamed(route);
  }

  /// Toggle mute
  void toggleMute() {
    _webrtcService.toggleMute();
    isMuted.value = _webrtcService.isMuted;
  }

  /// Enable or disable the local video track without renegotiation.
  Future<void> setCameraEnabled(bool enabled) async {
    await _webrtcService.setCameraEnabled(enabled);
    isCameraOn.value = _webrtcService.isCameraEnabled;
    if (_videoCallingEnabled && callState.value == CallState.connected) {
      _sendCallMediaUpdate(
        video: isCameraOn.value,
        reason: 'user toggled camera',
      );
    }
  }

  void _sendCallMediaUpdate({required bool video, required String reason}) {
    debugPrint(
      '📹 sendCallMediaUpdate(video=$video, callId=${currentCallId.value}, '
      'reason=$reason)',
    );
    _socketService.sendCallMediaUpdate(
      callId: currentCallId.value,
      video: video,
    );
  }

  Future<bool> switchCamera() async {
    final switched = await _webrtcService.switchCamera();
    if (switched) isFrontCamera.value = _webrtcService.isFrontCamera;
    return switched;
  }

  /// Toggle speaker
  Future<void> toggleSpeaker() async {
    // AudioSwitchManager (flutter_webrtc) handles MODE_IN_COMMUNICATION
    // internally, so we don't need to call ensureAudioMode here.
    // Calling our own native audio mode / focus requests would conflict
    // with AudioSwitch and cause it to revert the speaker selection.
    await _webrtcService.toggleSpeaker();
    isSpeakerOn.value = _webrtcService.isSpeakerOn;

    // Release/re-acquire proximity wake lock based on speaker state.
    // On Samsung/Xiaomi/Oppo, holding the proximity wake lock while the
    // sensor reads "near" forces audio to earpiece regardless of speaker setting.
    if (Platform.isAndroid) {
      ProximityService().setSpeakerActive(isSpeakerOn.value);
    }
  }

  /// Initialize audio mode to prevent 60-second speaker delay
  Future<void> _initializeAudioMode() async {
    try {
      await _callChannel.invokeMethod('ensureAudioMode');
      // Small delay to let Android audio subsystem settle
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (e) {
      debugPrint('⚠️ Failed to initialize audio mode: $e');
    }
  }

  void _handleCalleeConnecting(Map<String, dynamic> data) {
    if (!isCaller.value || data['callId'] != currentCallId.value) return;
    debugPrint('📞 Callee accepted and is connecting: ${data['callId']}');
    _ringtoneService.stopRingtone();
  }

  /// Handle call accepted from socket
  Future<void> _handleCallAccepted(Map<String, dynamic> data) async {
    debugPrint('📞 Call accepted');

    // Set server-assigned callId
    currentCallId.value = data['callId'] as String;

    if (_cryptoActive) {
      if (_cryptoAnswerInFlight ||
          (_cryptoHandshakeReady && data['callId'] == currentCallId.value)) {
        return;
      }
      _cryptoAnswerInFlight = true;
      final crypto = _signalingCrypto;
      final cryptoPayload = _wireCrypto(data);
      final sessionId = _cryptoSessionId;
      final peerBundle = _peerCryptoBundle;
      if (crypto == null ||
          cryptoPayload == null ||
          sessionId == null ||
          cryptoPayload['sessionId'] != sessionId ||
          peerBundle == null) {
        debugPrint('⚠️ Encrypted call accepted without valid crypto payload');
        endCall();
        return;
      }
      final ephB = _wireBytes(cryptoPayload, 'calleeEph');
      final calleeFp = _wireBytes(cryptoPayload, 'calleeFp');
      final answerFps = _wireByteList(cryptoPayload, 'answerFps');
      final encrypted = cryptoPayload['sdpAnswerEnc'];
      if (ephB == null ||
          calleeFp == null ||
          answerFps == null ||
          encrypted is! Map) {
        debugPrint('⚠️ Malformed encrypted call answer');
        endCall();
        return;
      }
      final record = <String, String>{};
      for (final key in const ['n', 'c', 'k']) {
        final value = encrypted[key];
        if (value is! String) {
          endCall();
          return;
        }
        record[key] = value;
      }
      try {
        await crypto.completeHandshakeFirstContact(
          peerId: remoteDeviceId.value,
          peerBundleB64: peerBundle,
          ephB: ephB,
          calleeSig: calleeFp,
          answerDtlsFps: answerFps,
        );
        final sdpAnswer = await crypto.decryptMessage(
          event: 'call_accept',
          encrypted: record,
        );
        if (!_sameFingerprints(
          CallSignalingCrypto.extractDtlsFingerprints(sdpAnswer),
          answerFps,
        )) {
          throw const CallSignalingCryptoException('sdp_fingerprint_mismatch');
        }
        if (_storageService.getPeerBundle(remoteDeviceId.value) == null) {
          final pinResult = await _storageService.pinPeerBundle(
            remoteDeviceId.value,
            peerBundle,
          );
          if (pinResult != LocalStorageService.pinResultPinned &&
              pinResult != LocalStorageService.pinResultUnchanged) {
            throw const CallSignalingCryptoException('pin_unavailable');
          }
        }
        await _storageService.markPeerEncryptedCall(remoteDeviceId.value);
        _cryptoHandshakeReady = true;
        await _flushPendingIceCandidates();
        await _webrtcService.setRemoteDescription(sdpAnswer, 'answer');
        if (_videoRequested) {
          isCameraOn.value = _webrtcService.isCameraEnabled;
          isFrontCamera.value = _webrtcService.isFrontCamera;
          isVideoCall.value = _videoCallingEnabled && _webrtcService.isVideoCall;
          if (isCameraOn.value) {
            unawaited(_refreshAndroidOngoingCallNotification());
            _stopProximitySensor();
          } else {
            _sendCallMediaUpdate(
              video: false,
              reason: 'camera not available on answer',
            );
          }
        }
        _updateCallEncryptionState(remoteDeviceId.value);
      } catch (e) {
        debugPrint('❌ Encrypted call answer rejected: $e');
        endCall();
      }
      return;
    }

    final sdpAnswer = data['sdpAnswer'] as String?;
    if (sdpAnswer == null || _wireCrypto(data) != null) {
      debugPrint('⚠️ Rejecting invalid call answer payload');
      endCall();
      return;
    }
    await _flushPendingIceCandidates();
    await _webrtcService.setRemoteDescription(sdpAnswer, 'answer');
  }

  /// Handle call initiated from server (server-assigned callId for caller)
  void _handleCallInitiated(Map<String, dynamic> data) {
    final callId = data['callId'] as String?;
    final calleeId = data['calleeId'] as String?;

    debugPrint(
      '📞 Call initiated by server: callId=$callId, calleeId=$calleeId',
    );

    if (callId == null || callId.isEmpty) return;
    if (_cryptoActive && callId != _cryptoSessionId) {
      debugPrint('❌ Encrypted call ID mismatch');
      endCall();
      return;
    }

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

    unawaited(_flushPendingIceCandidates());
  }

  /// Show a non-blocking banner for a call outcome. Dismisses any previous
  /// call-outcome banner so the user never ends up with a stack of them, and
  /// uses a unique snackbar key so the banner cannot block navigation.
  void _showFriendlyCallMessage(FriendlyCallMessage message) {
    if (Get.isSnackbarOpen) {
      Get.closeCurrentSnackbar();
    }
    Get.snackbar(
      message.title,
      message.body,
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 4),
      mainButton: message.action != null && message.actionLabel != null
          ? TextButton(
              onPressed: message.action,
              child: Text(message.actionLabel!),
            )
          : null,
    );
  }

  /// Handle call rejected from socket
  void _handleCallRejected(Map<String, dynamic> data) {
    debugPrint('📞 Call rejected: $data');

    // Stop ringtone
    _ringtoneService.stopRingtone();

    final reason = data['reason'] as String?;

    // Log rejected call
    _logCallHistory(
      reason: reason ?? 'rejected',
      terminatedBy: data['terminatedBy'] as String?,
    );

    _webrtcService.endCall();

    // Capture the peer and video intent before resetting state; the fallback
    // path needs them to redial as a legacy voice call.
    final rejectedPeer = remoteDeviceId.value;
    final wasOutgoingVideo = isCaller.value && _videoRequested;

    _resetCallState();

    // Surface the raw server reason in logs only, never to the user.
    debugPrint('📞 Rejection reason (logs only): $reason');

    final peerName = rejectedPeer.isNotEmpty
        ? (remoteDisplayName.value.isNotEmpty
            ? remoteDisplayName.value
            : StringUtils.generateFriendlyName(rejectedPeer))
        : 'The other person';

    final message = friendlyCallMessage(
      reason,
      peerName: peerName,
      offerVoiceFallback: reason == 'peer_update_required' && wasOutgoingVideo,
      onCallAsVoice: rejectedPeer.isEmpty
          ? null
          : () => startCall(rejectedPeer, isVideo: false),
    );

    _showFriendlyCallMessage(message);
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

    final reason = data['reason'] as String? ?? 'ended';

    // Log call history from server-provided reason
    _logCallHistory(
      reason: reason,
      terminatedBy: data['terminatedBy'] as String?,
    );

    _webrtcService.endCall();

    // Surface the raw server reason in logs only, never to the user.
    debugPrint('📞 Termination reason (logs only): $reason');

    final peerName = remoteDeviceId.value.isNotEmpty
        ? (remoteDisplayName.value.isNotEmpty
            ? remoteDisplayName.value
            : StringUtils.generateFriendlyName(remoteDeviceId.value))
        : 'The other person';

    _showFriendlyCallMessage(friendlyCallMessage(reason, peerName: peerName));

    // The call screen(s) will close themselves reactively once _resetCallState
    // sets callState to ended/idle. Do not navigate here so a banner or dialog
    // on top cannot be bypassed or duplicated.
    _resetCallState();
  }

  /// Handle local ICE candidate from WebRTC
  Future<void> _handleIceCandidate(
    String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  ) async {
    if (remoteDeviceId.value.isEmpty) return;

    if (currentCallId.value.isEmpty ||
        (_cryptoActive && !_cryptoHandshakeReady)) {
      // Buffer candidates until server callId arrives (caller only) or until
      // encrypted session keys exist.
      debugPrint('📤 Buffering ICE candidate: sdpMid=$sdpMid');
      _pendingIceCandidates.add({
        'candidate': candidate,
        'sdpMid': sdpMid,
        'sdpMLineIndex': sdpMLineIndex,
      });
      return;
    }

    if (_cryptoActive) {
      final cryptoPayload = await _encryptSignal(
        'ice_candidate',
        jsonEncode({
          'candidate': candidate,
          'sdpMid': sdpMid,
          'sdpMLineIndex': sdpMLineIndex,
        }),
      );
      if (cryptoPayload == null) return;
      _socketService.sendIceCandidate(
        callId: currentCallId.value,
        targetDeviceId: remoteDeviceId.value,
        crypto: {
          'v': 1,
          'sessionId': _cryptoSessionId,
          'iceEnc': cryptoPayload['enc'],
        },
      );
      debugPrint('📤 Encrypted ICE candidate sent');
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

  Future<void> _flushPendingIceCandidates() async {
    if (_pendingIceCandidates.isEmpty || currentCallId.value.isEmpty) return;
    if (_cryptoActive && !_cryptoHandshakeReady) return;

    final pending = List<Map<String, dynamic>>.from(_pendingIceCandidates);
    _pendingIceCandidates.clear();
    debugPrint('📤 Flushing ${pending.length} buffered ICE candidates');
    for (final c in pending) {
      await _handleIceCandidate(
        c['candidate'] as String,
        c['sdpMid'] as String?,
        c['sdpMLineIndex'] as int?,
      );
    }
  }

  /// Handle remote ICE candidate from socket
  Future<void> _handleRemoteIceCandidate(Map<String, dynamic> data) async {
    String? candidate = data['candidate'] as String?;
    String? sdpMid = data['sdpMid'] as String?;
    int? sdpMLineIndex = data['sdpMLineIndex'] as int?;

    if (_cryptoActive) {
      final plaintext = await _decryptSignal(
        'ice_candidate',
        _wireCrypto(data),
        'iceEnc',
      );
      if (plaintext == null) return;
      try {
        final decoded = jsonDecode(plaintext);
        if (decoded is! Map) return;
        candidate = decoded['candidate'] as String?;
        sdpMid = decoded['sdpMid'] as String?;
        final index = decoded['sdpMLineIndex'];
        sdpMLineIndex = index is num ? index.toInt() : null;
      } catch (_) {
        return;
      }
    } else if (_wireCrypto(data) != null) {
      return;
    }

    debugPrint(
      '📞 Remote ICE candidate received - sdpMid: $sdpMid, sdpMLineIndex: $sdpMLineIndex',
    );

    if (candidate == null || sdpMid == null || sdpMLineIndex == null) {
      debugPrint('⚠️ Skipping ICE candidate with missing fields');
      return;
    }

    _webrtcService.addIceCandidate(candidate, sdpMid, sdpMLineIndex);
  }

  /// Handle local SDP description (offer or answer) from WebRTC
  Future<void> _handleLocalDescription(String sdp) async {
    debugPrint('📞 Local SDP description received, length: ${sdp.length}');

    if (isCaller.value) {
      // Caller: Send SDP offer to callee via socket
      final callerDeviceId = _storageService.deviceId;
      if (callerDeviceId == null) return;

      if (_cryptoActive) {
        final crypto = _signalingCrypto;
        final sessionId = _cryptoSessionId;
        final peerBundle = _peerCryptoBundle;
        if (crypto == null || sessionId == null || peerBundle == null) {
          _failCryptoCall('missing_call_crypto');
          return;
        }
        try {
          final begin = await crypto.beginOfferFirstContact(
            callId: sessionId,
            myId: callerDeviceId,
            peerId: remoteDeviceId.value,
            peerBundleB64: peerBundle,
            offerDtlsFps: CallSignalingCrypto.extractDtlsFingerprints(sdp),
          );
          final cryptoPayload = <String, dynamic>{
            'v': 1,
            'sessionId': sessionId,
            'callerEph': base64Encode(begin.eph),
            'callerFp': base64Encode(begin.fp),
            'sdpOfferEnc': await crypto.encryptOffer(sdp),
          };
          _socketService.initiateCall(
            callerId: callerDeviceId,
            calleeId: remoteDeviceId.value,
            callerName: callerDisplayName.value.isNotEmpty
                ? callerDisplayName.value
                : null,
            isVideo: _videoRequested && _videoCallingEnabled,
            crypto: cryptoPayload,
          );
          debugPrint('📞 Encrypted SDP offer sent');
        } catch (e) {
          debugPrint('❌ Encrypted call offer failed: $e');
          _failCryptoCall('offer_failed');
        }
        return;
      }

      _socketService.initiateCall(
        callerId: callerDeviceId,
        calleeId: remoteDeviceId.value,
        sdpOffer: sdp,
        callerName:
            callerDisplayName.value.isNotEmpty ? callerDisplayName.value : null,
        isVideo: _videoRequested && _videoCallingEnabled,
      );
      debugPrint(
        '📞 SDP offer sent to socket with callerName: ${callerDisplayName.value}',
      );
      return;
    }

    // Callee: Send SDP answer to caller via socket
    if (_cryptoActive) {
      final crypto = _signalingCrypto;
      final callerFp = _incomingCallerFp;
      if (crypto == null || callerFp == null) {
        _rejectCryptoCall('missing_answer_crypto');
        return;
      }
      try {
        final answerFps = CallSignalingCrypto.extractDtlsFingerprints(sdp);
        final answer = await crypto.beginAnswer(
          peerId: remoteDeviceId.value,
          callerSig: callerFp,
          offerDtlsFps: _incomingOfferFps,
          answerDtlsFps: answerFps,
        );
        final peerBundle = _peerCryptoBundle;
        if (peerBundle == null) {
          throw const CallSignalingCryptoException('missing_peer_bundle');
        }
        if (_storageService.getPeerBundle(remoteDeviceId.value) == null) {
          final pinResult = await _storageService.pinPeerBundle(
            remoteDeviceId.value,
            peerBundle,
          );
          if (pinResult != LocalStorageService.pinResultPinned &&
              pinResult != LocalStorageService.pinResultUnchanged) {
            throw const CallSignalingCryptoException('pin_unavailable');
          }
        }
        await _storageService.markPeerEncryptedCall(remoteDeviceId.value);
        final encrypted = await crypto.encryptMessage(
          event: 'call_accept',
          plaintext: sdp,
        );
        _cryptoHandshakeReady = true;
        _updateCallEncryptionState(remoteDeviceId.value);
        _socketService.acceptCall(
          callId: currentCallId.value,
          callerId: remoteDeviceId.value,
          crypto: {
            'v': 1,
            'sessionId': _cryptoSessionId,
            'calleeEph': base64Encode(answer.eph),
            'calleeFp': base64Encode(answer.fp),
            'answerFps': answerFps.map(base64Encode).toList(),
            'sdpAnswerEnc': encrypted,
          },
        );
        debugPrint('📞 Encrypted SDP answer sent');
        unawaited(_flushPendingIceCandidates());
      } catch (e) {
        debugPrint('❌ Encrypted call answer failed: $e');
        _rejectCryptoCall('crypto_failed');
      }
      return;
    }

    _socketService.acceptCall(
      callId: currentCallId.value,
      callerId: remoteDeviceId.value,
      sdpAnswer: sdp,
    );
    debugPrint('📞 SDP answer sent to socket');
  }

  /// Handle peer ringing notification
  void _handlePeerRinging(Map<String, dynamic> data) {
    debugPrint('📞 Peer is ringing: $data');
    callState.value = CallState.ringing;
  }

  /// Handle call state change from WebRTC
  void _handleCallStateChange(String state, {String? reason}) async {
    debugPrint('📞 Call state changed: $state (reason: $reason)');

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
        isReconnecting.value = false;
        hasPoorConnection.value = false;
        _wasConnected = true;
        unawaited(_setNativeInCall(true));

        // Restore speaker state if call was answered from background
        if (_answeredFromBackground) {
          debugPrint(
              '📞 Call connected after background answer - restoring speaker state');
          // Ensure speaker state is properly configured after connection
          final currentSpeakerState = _webrtcService.isSpeakerOn;
          await _webrtcService.setSpeaker(currentSpeakerState);
          _answeredFromBackground = false; // Reset flag
        }

        // Start duration update timer to sync with WebRTC service
        _startDurationUpdateTimer();
        // Proximity blanking is voice-only; video calls keep the display awake.
        if (!isVideoCall.value) _setupProximitySensor();
        // Start native ongoing-call foreground notification with live duration.
        // Deferred video refreshes this after the camera permission/type exists.
        unawaited(_refreshAndroidOngoingCallNotification());
        if (Platform.isAndroid) {
          unawaited(
            _callChannel.invokeMethod('markTelecomCallActive', {
              'callId': currentCallId.value,
            }),
          );
        } else if (currentCallId.value.isNotEmpty) {
          NotificationService().showOngoingCallNotification(
            callId: currentCallId.value,
            callerName: remoteDisplayName.value.isNotEmpty
                ? remoteDisplayName.value
                : 'Unknown',
          );
        }
        // Navigate caller to active call screen (callee navigates from incoming screen)
        if (isCaller.value && !isCallMinimized.value) {
          Get.offNamed(activeCallRoute);
        }
        break;
      case 'disconnected':
        if (isConnected) {
          isReconnecting.value = _videoCallingEnabled;
          hasPoorConnection.value = true;
        }
        break;
      case 'ended':
        _ringtoneService.stopRingtone();
        // Fallback log when no server termination event was received.
        _logCallHistory(reason: reason ?? 'ended');
        _stopDurationUpdateTimer();
        // The call screen(s) will close themselves reactively once callState
        // becomes ended. Do not navigate here so overlays on top are handled
        // safely by the screen itself.
        callState.value = CallState.ended;
        isCallMinimized.value = false;
        isReconnecting.value = false;
        hasPoorConnection.value = false;
        break;
    }
  }

  /// Handle call ended from WebRTC
  void _handleCallEnded(String callId) {
    debugPrint('📞 Call ended: $callId');
    // Fallback log when no server termination event was received.
    _logCallHistory(reason: 'ended');
    // Note: _logCallHistory may already have been called by endCall() or
    // _handleCallTerminated(). This handler is a fallback for WebRTC-level
    // disconnections. The call screen(s) close reactively via callState.
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

    // Cancel incoming call notification if it exists
    NotificationService().cancelNotification(callId.hashCode);

    // Delegate to the full accept-resync path so permission checks, audio
    // mode, native in-call state, and error handling are all applied.
    _acceptIncomingCallResync(data);
  }

  /// Handle server response to a call status probe.
  /// If the server says the call no longer exists, end locally with a friendly
  /// message. If it exists, stay on the call (the peer will drive ICE restart).
  void _handleCallStatusResponse(Map<String, dynamic> data) {
    final callId = data['callId'] as String?;
    final exists = data['exists'] == true;
    debugPrint('📞 Call status response: $data');

    if (callId == null ||
        callId.isEmpty ||
        currentCallId.value.isEmpty ||
        callId != currentCallId.value) {
      return;
    }

    if (exists) return;

    debugPrint('📞 Server reports call $callId no longer exists, ending locally');
    _logCallHistory(
      reason: data['reason'] as String? ?? 'expired',
    );
    _webrtcService.endCall();

    final peerName = remoteDeviceId.value.isNotEmpty
        ? (remoteDisplayName.value.isNotEmpty
            ? remoteDisplayName.value
            : StringUtils.generateFriendlyName(remoteDeviceId.value))
        : 'The other person';
    _showFriendlyCallMessage(
      friendlyCallMessage(
        data['reason'] as String? ?? 'expired',
        peerName: peerName,
      ),
    );

    _resetCallState();
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
    _updateCallEncryptionState(deviceId);
    // First check locally saved contact name (what the user named them in chat)
    final savedChat = _storageService.getChat(deviceId);
    final savedAvatarUrl = savedChat?.avatarUrl;
    if (savedAvatarUrl != null && savedAvatarUrl.isNotEmpty) {
      remoteAvatarUrl.value = savedAvatarUrl;
    }
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

  Future<void> _teardownAndroidCall(String callId) async {
    if (!Platform.isAndroid) return;
    try {
      await _callChannel.invokeMethod<bool>('teardownAndroidCall', {
        'callId': callId,
      });
    } catch (e) {
      debugPrint('⚠️ Failed to tear down native Android call: $e');
    }
  }

  /// Reset call state
  void _resetCallState() {
    _resetCryptoState();
    final callId = currentCallId.value;
    unawaited(_teardownAndroidCall(callId));
    unawaited(_setNativeInCall(false));
    callState.value = CallState.ended;
    isCallMinimized.value = false;
    isMuted.value = false;
    isSpeakerOn.value = false;
    isVideoCall.value = false;
    _videoRequested = false;
    isCameraOn.value = false;
    isFrontCamera.value = true;
    peerCameraOff.value = false;
    isReconnecting.value = false;
    hasPoorConnection.value = false;
    localVideoStream.value = null;
    remoteVideoStream.value = null;
    callDuration.value = '00:00';
    currentCallId.value = '';
    isCaller.value = false;
    _latestIncomingCallData = null;
    _nativeCallHeld = false;
    _cameraWasOnBeforeNativeHold = false;
    _iceRestartInFlight = false;
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

    // If a call rang while full-screen intent was denied, offer the fix now —
    // the user just experienced the symptom, so this is the right moment.
    if (_fsiPromptPending) {
      _fsiPromptPending = false;
      unawaited(_checkFullScreenIntentPermission());
    }
  }

  /// Cleanup resources
  void _cleanup() {
    _videoWakelockWorker?.dispose();
    unawaited(WakelockPlus.disable());
    _stopProximitySensor();
    _stopDurationUpdateTimer();
    _resetCryptoState();
    _webrtcService.dispose();
  }

  /// Getters
  bool get isInCall =>
      callState.value != CallState.idle && callState.value != CallState.ended;
  bool get isConnecting =>
      callState.value == CallState.dialing ||
      callState.value == CallState.ringing;
  bool get isConnected => callState.value == CallState.connected;

  String get callTimerLabel {
    if (isReconnecting.value) return 'Reconnecting…';
    return switch (callState.value) {
      CallState.connected => callDuration.value,
      CallState.dialing => 'Calling…',
      CallState.ringing => isCaller.value ? 'Ringing…' : 'Connecting…',
      CallState.ended => 'Call ended',
      CallState.idle => 'Connecting…',
    };
  }

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
      remoteAvatarUrl:
          remoteAvatarUrl.value.isNotEmpty ? remoteAvatarUrl.value : null,
      direction:
          isCaller.value ? CallDirection.outgoing : CallDirection.incoming,
      status: status,
      timestamp: _callStartTime!,
      durationSeconds: _wasConnected ? _durationSeconds : 0,
      callType: isVideoCall.value ? 'video' : 'audio',
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
    debugPrint(
      '📞 Incoming call received: callId=${data['callId']}, callerId=${data['callerId']}, video=${data['isVideo'] == true}, encrypted=${_wireCrypto(data) != null}',
    );
    final incomingCallId = data['callId'] as String?;

    if (incomingCallId == null || incomingCallId.isEmpty) {
      debugPrint('❌ Incoming call received with no callId, ignoring');
      return;
    }

    // Re-check full-screen intent while a call notification is being posted.
    // If it is denied the full-screen UI will be suppressed — flag it so the
    // settings dialog can be offered once this call ends.
    unawaited(
      _checkFullScreenIntentPermission(prompt: false).then((_) {
        if (_fsiDenied) _fsiPromptPending = true;
      }),
    );

    final incomingCallerId = data['callerId'] as String? ?? '';
    if (data['isVideo'] == true && !_videoCallingEnabled) {
      _socketService.rejectCall(
        callId: incomingCallId,
        callerId: incomingCallerId,
        reason: 'peer_update_required',
      );
      return;
    }
    if (_wireCrypto(data) == null &&
        (data['isVideo'] == true ||
            _peerRequiresEncryptedCall(incomingCallerId))) {
      _socketService.rejectCall(
        callId: incomingCallId,
        callerId: incomingCallerId,
        reason: 'encryption_required',
      );
      return;
    }

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

    if (_wireCrypto(data) != null) {
      if (!_encryptedSignalingEnabled) {
        _socketService.rejectCall(
          callId: incomingCallId,
          callerId: data['callerId'] as String? ?? '',
          reason: 'peer_update_required',
        );
        return;
      }
      try {
        final offer = await _decryptIncomingOffer(
          data,
          incomingCallId,
          data['callerId'] as String? ?? '',
        );
        if (offer == null) {
          throw const CallSignalingCryptoException('malformed_record');
        }
        data['decryptedSdpOffer'] = offer;
      } catch (_) {
        _rejectCryptoCall(
          'crypto_failed',
          callId: incomingCallId,
          callerId: data['callerId'] as String? ?? '',
        );
        return;
      }
    }

    // Avoid duplicate UI if the incoming call screen is already open
    final currentRoute = Get.currentRoute;
    if (currentRoute == '/call/incoming' ||
        currentRoute == '/call/active' ||
        currentRoute == '/call/video') {
      debugPrint(
        '📞 Incoming call screen already open ($currentRoute), skipping',
      );
      return;
    }

    remoteDeviceId.value = incomingCallerId;
    remoteDisplayName.value = data['callerName'] as String? ?? 'Incoming Call';
    remoteAvatarUrl.value =
        data['avatarUrl'] as String? ?? data['avatar_url'] as String? ?? '';

    // Store the call data so accept paths (notification action, resync)
    // always have the SDP offer available.
    _latestIncomingCallData = data;

    // Mark this callId as handled so FCMService dedup guard skips it if FCM
    // arrives shortly after (server sends both socket + FCM in parallel)
    FCMService.setLastShownCallId(incomingCallId);

    final screenLocked = await _isScreenLocked();
    final appInBackground = await _isAppInBackground();

    if (appInBackground || screenLocked) {
      // The native FCM service will show the full-screen IncomingCallActivity
      // when the app is in the background, killed, or when the device is locked.
      // Do not ring or show the Flutter UI here — the native
      // CallForegroundService owns the ringtone and call UI to avoid
      // double ringtone and duplicate screens.
      debugPrint(
        '📞 App in background/locked — native FCM service will show call UI',
      );
      return;
    }

    // Foreground and unlocked: ring and show the Flutter incoming call screen.
    _ringtoneService.playIncomingRingtone();
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
      final calleeDeviceId = _storageService.deviceId;

      if (calleeDeviceId == null) {
        debugPrint('❌ Cannot resync accept: missing deviceId');
        return;
      }

      final incomingVideo = data['isVideo'] == true;
      if (incomingVideo && !_videoCallingEnabled) {
        _socketService.rejectCall(
          callId: callId,
          callerId: callerId,
          reason: 'peer_update_required',
        );
        _resetCallState();
        return;
      }
      if (_wireCrypto(data) == null &&
          (incomingVideo || _peerRequiresEncryptedCall(callerId))) {
        _socketService.rejectCall(
          callId: callId,
          callerId: callerId,
          reason: 'encryption_required',
        );
        _resetCallState();
        return;
      }

      // Check microphone permission before accepting call
      final hasPermission = await _checkMicrophonePermission();
      if (!hasPermission) {
        debugPrint('❌ Cannot resync accept: Microphone permission denied');
        _webrtcService.endCall();
        _resetCallState();
        return;
      }

      String? sdpOffer;
      try {
        sdpOffer = await _decryptIncomingOffer(data, callId, callerId);
      } catch (e) {
        debugPrint('❌ Encrypted resync offer rejected: $e');
        sdpOffer = null;
      }
      if (sdpOffer == null) {
        _rejectCryptoCall('crypto_failed', callId: callId, callerId: callerId);
        return;
      }

      // Store call info
      currentCallId.value = callId;
      remoteDeviceId.value = callerId;
      remoteAvatarUrl.value =
          data['avatarUrl'] as String? ?? data['avatar_url'] as String? ?? '';
      isCaller.value = false;
      _videoRequested = incomingVideo;
      isVideoCall.value = incomingVideo && _videoCallingEnabled;
      isCameraOn.value = false;
      peerCameraOff.value = false;
      _callStartTime = DateTime.now(); // Set call start time for history
      _wasConnected = false;
      _durationSeconds = 0;
      unawaited(_resolveDisplayName(callerId));

      // Stop the native ringing service before WebRTC starts
      await _stopNativeIncomingCall();

      // CRITICAL: Initialize audio mode before accepting call
      await _initializeAudioMode();
      unawaited(_setNativeInCall(true));

      // Accept WebRTC call directly (no ringing state)
      _webrtcService.primeIceServers(data['iceServers']);
      final success = await _webrtcService.acceptCall(
        callId: callId,
        callerDeviceId: callerId,
        calleeDeviceId: calleeDeviceId,
        sdpOffer: sdpOffer,
        isVideo: incomingVideo,
      );

      if (success) {
        isCameraOn.value = _webrtcService.isCameraEnabled;
        isFrontCamera.value = _webrtcService.isFrontCamera;
        isSpeakerOn.value = _webrtcService.isSpeakerOn;
        isVideoCall.value = incomingVideo && _webrtcService.isVideoCall;
        debugPrint('📞 Resync accept successful, navigating to active call');
        callState.value = CallState.ringing;
        // Clear pending auto-accept since we successfully accepted
        await clearPendingAutoAccept();
        // Update native CallKit UI so it shows the connected call screen
        if (!Platform.isIOS) {
          CallKitService().setCallConnected(callId);
        }
        // Only navigate if not already on the active call screen
        if (Get.currentRoute != activeCallRoute) {
          Get.offNamed(activeCallRoute);
        }
      } else {
        debugPrint('❌ Resync accept failed');
        _webrtcService.endCall();
        _resetCallState();
      }
    } catch (e) {
      debugPrint('❌ Error in _acceptIncomingCallResync: $e');
      _webrtcService.endCall();
      _resetCallState();
    }
  }
}
