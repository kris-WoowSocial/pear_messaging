import 'dart:async';
import 'dart:io' show Platform;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'call_breadcrumbs.dart';
import 'callkit_service.dart';
import 'call_media_helper.dart';
import 'call_diag.dart';
import 'encryption_service.dart';
import 'feature_flag_service.dart';
import 'fcm_service.dart';
import 'block_service.dart';
import 'connection_request_service.dart';
import 'ice_servers_cache.dart';
import 'identity_service.dart';
import '../constants/network_constants.dart';
import 'package:package_info_plus/package_info_plus.dart';

class SocketService extends GetxService {
  // Live server URL
  static const String _serverUrl = NetworkConstants.socketUrl;
  IO.Socket? _socket;
  String? _deviceId;
  Timer? _reconnectTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isConnecting = false; // Prevent duplicate connection attempts
  bool _isInForeground = true;
  int _reconnectAttempts = 0;

  final List<Map<String, dynamic>> _pendingMessagesAwaitingHandler = [];

  final RxBool isConnected = false.obs;
  final RxBool isRegistered = false.obs;
  final RxString connectionStatus = 'disconnected'.obs;

  // Callbacks for message events
  Function(Map<String, dynamic>)? onMessageReceived;
  Function(List<Map<String, dynamic>>)? onPendingMessages;
  Function(String, String)? onMessageStatus;
  Function(String)? onUserOffline;

  // Callbacks for block events
  Function(Map<String, dynamic>)? onBlockStatus;
  Function(Map<String, dynamic>)? onUserBlocked;
  Function(Map<String, dynamic>)? onUserUnblocked;

  // Callbacks for connection requests
  Function(Map<String, dynamic>)? onConnectionRequest;
  Function(Map<String, dynamic>)? onConnectionRequestResponse;

  // Callbacks for WebRTC call events
  Function(Map<String, dynamic>)? onIncomingCall;
  Function(Map<String, dynamic>)? onCallInitiated;
  Function(Map<String, dynamic>)? onCallAccepted;
  Function(Map<String, dynamic>)? onCallRejected;
  Function(Map<String, dynamic>)? onCallTerminated;
  Function(Map<String, dynamic>)? onIceCandidate;
  Function(Map<String, dynamic>)? onPeerRinging;
  Function(Map<String, dynamic>)? onIceRestart;
  Function(Map<String, dynamic>)? onCallMediaUpdate;
  Function(Map<String, dynamic>)? onCallResync;
  Function(Map<String, dynamic>)? onCalleeConnecting;
  Function(Map<String, dynamic>)? onCallStatusResponse;

  // Callbacks for group chat events
  Function(Map<String, dynamic>)? onGroupMessageReceived;
  Function(Map<String, dynamic>)? onGroupMessageStatus;
  Function(Map<String, dynamic>)? onGroupTyping;
  Function(Map<String, dynamic>)? onGroupCreated;
  Function(Map<String, dynamic>)? onGroupMemberAdded;
  Function(Map<String, dynamic>)? onGroupMemberRemoved;
  Function(Map<String, dynamic>)? onGroupMemberLeft;
  Function(Map<String, dynamic>)? onGroupInfoUpdated;
  Function(Map<String, dynamic>)? onGroupDissolved;

  // Getters
  String? get deviceId => _deviceId;

  /// Single-use nonce from the server's register_challenge, completed once
  /// per socket connection. Reset on each new connect.
  Completer<String?>? _challengeCompleter;

  /// Connect-path instrumentation: elapsed since IO.io() was created. The
  /// 'connect' event elapsed = DNS + TLS + WebSocket upgrade combined
  /// (websocket-only transport — no polling upgrade).
  final Stopwatch _connectWatch = Stopwatch();

  /// Elapsed since the 'register' emit until 'device_registered' arrives.
  final Stopwatch _registerWatch = Stopwatch();

  /// When true, the connect handler skips the Remote Config wait so call
  /// signaling registers immediately. Set by CallController while a call is
  /// ringing or being answered; safe because flags hydrate from disk.
  bool callUrgency = false;

  /// Callback for inbound identity announcements (peer bundle + signature).
  /// Wired by the announcement flow.
  void Function(Map<String, dynamic>)? onIdentityAnnounce;

  /// Callback for server-side identity responses (bound / rejected / conflict).
  void Function(Map<String, dynamic>)? onIdentityBound;
  void Function(Map<String, dynamic>)? onRegisterRejected;
  void Function(Map<String, dynamic>)? onIdentityConflict;

  /// Server-side signal that the registered deviceId failed format
  /// validation (digits-only). The client must mint a new epoch-ms ID and
  /// re-register — wired by main_prod's self-repair path.
  void Function(Map<String, dynamic>)? onDeviceIdInvalid;
  void Function(Map<String, dynamic>)? onIdentityAnnounceAcked;

  /// Inbound verification echo ({from, bundle, mac}) during contact
  /// verification — wired by IdentityVerificationService.
  void Function(Map<String, dynamic>)? onVerifyEcho;

  @visibleForTesting
  static String formatClientVersion(String version, String buildNumber) =>
      '$version+$buildNumber';

  /// Initialize the socket service with device ID
  Future<SocketService> init(String deviceId) async {
    _deviceId = deviceId;
    debugPrint('🔌 SocketService initialized with deviceId: $_deviceId');
    // Cache client version for the register payload (rollout gating).
    try {
      final info = await PackageInfo.fromPlatform();
      _cachedClientVersion = formatClientVersion(
        info.version,
        info.buildNumber,
      );
    } catch (_) {}
    _setupConnectivityListener();
    await connect();
    return this;
  }

  Future<void> processPendingMessages() async {
    if (_pendingMessagesAwaitingHandler.isEmpty) return;

    final pendingMessages = List<Map<String, dynamic>>.from(
      _pendingMessagesAwaitingHandler,
    );
    final pendingHandler = onPendingMessages;
    final messageHandler = onMessageReceived;

    if (pendingHandler != null) {
      _pendingMessagesAwaitingHandler.clear();
      final result = pendingHandler(pendingMessages);
      if (result is Future) await result;
      return;
    } else if (messageHandler != null) {
      _pendingMessagesAwaitingHandler.clear();
      for (final message in pendingMessages) {
        final result = messageHandler(message);
        if (result is Future) await result;
      }
    } else {
      return;
    }

    for (final message in pendingMessages) {
      final messageId = message['messageId']?.toString();
      if (messageId != null && messageId.isNotEmpty) {
        sendMessageAck(messageId);
      }
    }
  }

  /// Setup connectivity listener for automatic reconnection
  void _setupConnectivityListener() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      final hasConnection = results.any(
        (result) => result != ConnectivityResult.none,
      );
      if (hasConnection && !isConnected.value && !_isConnecting) {
        debugPrint(
          '📶 Network connectivity restored, attempting to reconnect...',
        );
        connect();
      }
    });
  }

  /// Connect to the Socket.IO server
  Future<void> connect() async {
    // Prevent duplicate connection attempts
    if (_isConnecting) {
      debugPrint('⚡ Connection already in progress, skipping...');
      return;
    }

    if (_socket != null && isConnected.value) {
      debugPrint('⚡ Socket already connected');
      return;
    }

    _isConnecting = true;
    _connectWatch
      ..reset()
      ..start();

    try {
      connectionStatus.value = 'connecting';
      debugPrint('🔄 Connecting to socket server: $_serverUrl');

      // Cleanup any existing socket first
      if (_socket != null) {
        debugPrint('🧹 Cleaning up existing socket...');
        _socket?.disconnect();
        _socket?.dispose();
        _socket = null;
      }

      _socket = IO.io(_serverUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
        'timeout': 10000,
        'reconnectionAttempts': 5,
        'reconnectionDelay': 3000,
        'reconnectionDelayMax': 10000,
        'path': '/socket/secureconnection',
        'forceNew': true,
      });

      debugPrint('🔧 Socket configuration:');
      debugPrint('   - URL: $_serverUrl');
      debugPrint('   - Path: /socket/secureconnection');
      debugPrint('   - Transports: websocket only');
      debugPrint('   - Timeout: 10s');
      debugPrint('   - Reconnection attempts: 5');

      _setupSocketListeners();
    } catch (e) {
      debugPrint('❌ Socket connection error: $e');
      connectionStatus.value = 'error';
      _isConnecting = false;
      _scheduleReconnect();
    }
  }

  /// Force reconnect with duplicate prevention for iOS
  Future<void> safeReconnect() async {
    // Prevent multiple reconnect attempts
    if (_isConnecting) {
      debugPrint('⚡ Reconnect already in progress, skipping...');
      return;
    }

    // Clear any pending connection requests to prevent duplicates
    try {
      if (Get.isRegistered<ConnectionRequestService>()) {
        final connectionService = Get.find<ConnectionRequestService>();
        unawaited(connectionService.cleanupDuplicateConnections());
      }
    } catch (e) {
      debugPrint('⚠️ Could not cleanup connections before reconnect: $e');
    }

    await forceReconnect();
  }

  /// Setup socket event listeners
  void _setupSocketListeners() {
    _socket?.on('connect', (_) async {
      callDiag(
        '✅ Socket connected (transport=websocket, '
        '${_connectWatch.elapsedMilliseconds}ms DNS+TLS+WS)',
      );
      isConnected.value = true;
      isRegistered.value = false;
      connectionStatus.value = 'connected';
      _isConnecting = false; // Reset connecting flag
      _reconnectAttempts =
          0; // Reset reconnection attempts on successful connection
      _cancelReconnectTimer();

      // Fresh challenge nonce for this connection
      _challengeCompleter = Completer<String?>();

      // Update UserDefaults for iOS background notification handling
      _updateSocketConnectionStatus(true);

      // Store backend URL for HTTP delivery ack
      _storeBackendUrl();

      // Wait for the first Remote Config fetch (up to 3s) so the initial
      // capability announcement reflects the real feature flags instead of
      // the safe OFF defaults. Skipped while a call is ringing/being
      // answered — flags are hydrated from disk at startup, so capabilities
      // still announce correctly, and the fetch is not on the accept path.
      if (callUrgency) {
        callDiag('⚡ Skipping Remote Config wait — call in progress');
      } else {
        final rcWatch = Stopwatch()..start();
        await _waitForFeatureFlags();
        callDiag(
          '🎛️ Remote Config wait: ${rcWatch.elapsedMilliseconds}ms',
        );
      }

      _registerDevice();

      // Subscribe once to flag changes so any later Remote Config flip triggers
      // a capabilities_update re-announcement (covers app resume refresh too).
      _subscribeCapabilityFlagUpdates();

      // Send pending delivery acknowledgments for FCM messages received while offline
      FCMService.sendPendingAcknowledgments();
    });

    _socket?.on('register_challenge', (data) {
      final nonce = data is Map ? data['nonce'] as String? : null;
      if (nonce != null &&
          _challengeCompleter != null &&
          !_challengeCompleter!.isCompleted) {
        _challengeCompleter!.complete(nonce);
      }
    });

    _socket?.on('identity_announce', (data) {
      if (data is Map && onIdentityAnnounce != null) {
        onIdentityAnnounce!(Map<String, dynamic>.from(data));
      }
    });

    _socket?.on('identity_bound', (data) {
      if (data is Map && onIdentityBound != null) {
        onIdentityBound!(Map<String, dynamic>.from(data));
      }
    });

    _socket?.on('register_rejected', (data) {
      debugPrint('⚠️ Register rejected by server: $data');
      if (data is Map && onRegisterRejected != null) {
        onRegisterRejected!(Map<String, dynamic>.from(data));
      }
    });

    _socket?.on('device_id_invalid', (data) {
      debugPrint('⚠️ Server rejected deviceId format: $data');
      if (data is Map && onDeviceIdInvalid != null) {
        onDeviceIdInvalid!(Map<String, dynamic>.from(data));
      }
    });

    _socket?.on('identity_conflict', (data) {
      debugPrint('⚠️ Identity conflict from server: $data');
      if (data is Map && onIdentityConflict != null) {
        onIdentityConflict!(Map<String, dynamic>.from(data));
      }
    });

    _socket?.on('verify_echo', (data) {
      if (data is Map && onVerifyEcho != null) {
        onVerifyEcho!(Map<String, dynamic>.from(data));
      }
    });

    _socket?.on('identity_announce_acked', (data) {
      if (data is Map && onIdentityAnnounceAcked != null) {
        onIdentityAnnounceAcked!(Map<String, dynamic>.from(data));
      }
    });

    _socket?.on('device_registered', (data) {
      final deviceId = data is Map ? data['deviceId'] : null;
      if (deviceId == _deviceId) {
        isRegistered.value = true;
        callDiag(
          '✅ Socket registration confirmed for $_deviceId '
          '(register→registered: ${_registerWatch.elapsedMilliseconds}ms, '
          'total from connect: ${_connectWatch.elapsedMilliseconds}ms)',
        );
        unawaited(_registerFCMTokenIfAvailable());
      }
    });

    _socket?.on('disconnect', (reason) {
      debugPrint('🔴 Socket disconnected: $reason');
      isConnected.value = false;
      isRegistered.value = false;
      connectionStatus.value = 'disconnected';
      _isConnecting = false; // Reset connecting flag

      // Update UserDefaults for iOS background notification handling
      _updateSocketConnectionStatus(false);

      // Only schedule reconnect for certain disconnect reasons
      if (reason != 'io client disconnect' &&
          reason != 'io server disconnect') {
        debugPrint(
          '🔄 Scheduling reconnect due to unexpected disconnect: $reason',
        );
        _scheduleReconnect();
      } else {
        debugPrint('🛑 Manual disconnect, not scheduling reconnect');
      }
    });

    _socket?.on('connect_error', (error) {
      debugPrint(
        '❌ Socket connection error after '
        '${_connectWatch.elapsedMilliseconds}ms: $error',
      );
      debugPrint('❌ Error type: ${error.runtimeType}');
      debugPrint('❌ Error details: ${error.toString()}');
      isConnected.value = false;
      isRegistered.value = false;
      connectionStatus.value = 'error';
      _isConnecting = false; // Reset connecting flag
      _scheduleReconnect();
    });

    // Define message handler function first
    void handleMessage(Map<String, dynamic> data) {
      debugPrint('📨 DEBUG: Socket received message: $data');
      debugPrint(
        '🔍 DEBUG: Message handler exists: ${onMessageReceived != null}',
      );
      if (onMessageReceived != null) {
        debugPrint('📤 DEBUG: Calling message handler...');
        onMessageReceived!(data);
      } else {
        debugPrint('❌ DEBUG: No message handler registered!');
      }
    }

    // Message received from another user
    _socket?.on('receive_message', (data) {
      handleMessage(data);
    });

    // Pending messages when reconnecting
    _socket?.on('pending_messages', (data) {
      if (data is! List) {
        debugPrint('⚠️ Ignoring invalid pending messages payload');
        return;
      }

      final messages = data
          .whereType<Map>()
          .map((message) => Map<String, dynamic>.from(message))
          .toList();
      debugPrint('📬 Pending messages received: ${messages.length}');
      _pendingMessagesAwaitingHandler.addAll(messages);
      unawaited(processPendingMessages());
    });

    // Message status updates
    _socket?.on('message_status', (data) {
      debugPrint('📊 Message status: $data');
      if (onMessageStatus != null && data != null) {
        final id = data['id']?.toString();
        final status = data['status']?.toString();
        if (id != null && status != null) {
          onMessageStatus!(id, status);
        }
      }
    });

    // User offline notification
    _socket?.on('user_offline', (data) {
      debugPrint('👤 User offline: $data');
      if (onUserOffline != null && data != null) {
        onUserOffline!(data['to']);
      }
    });

    // Block status response
    _socket?.on('block_status', (data) {
      debugPrint('🚫 Block status: $data');
      if (onBlockStatus != null && data != null) {
        onBlockStatus!(Map<String, dynamic>.from(data));
      }
    });

    // User blocked notification
    _socket?.on('user_blocked', (data) {
      debugPrint('🚫 User blocked: $data');
      if (onUserBlocked != null && data != null) {
        onUserBlocked!(Map<String, dynamic>.from(data));
      }
    });

    // User unblocked notification
    _socket?.on('user_unblocked', (data) {
      debugPrint('✅ User unblocked: $data');
      if (onUserUnblocked != null && data != null) {
        onUserUnblocked!(Map<String, dynamic>.from(data));
      }
    });

    // Connection request received
    _socket?.on('connection_request', (data) {
      debugPrint('🤝 DEBUG: Connection request event received!');
      debugPrint('🤝 DEBUG: Raw data: $data');
      debugPrint('🤝 DEBUG: Handler exists: ${onConnectionRequest != null}');
      if (onConnectionRequest != null && data != null) {
        debugPrint('🤝 DEBUG: Calling connection request handler...');
        onConnectionRequest!(Map<String, dynamic>.from(data));
      } else {
        debugPrint('❌ DEBUG: No handler or null data for connection request');
      }
    });

    // Connection request response
    _socket?.on('connection_request_response', (data) {
      debugPrint('🤝 Connection request response: $data');
      if (onConnectionRequestResponse != null && data != null) {
        onConnectionRequestResponse!(Map<String, dynamic>.from(data));
      }
    });

    // WebRTC Call: Incoming call
    _socket?.on('incoming_call', (data) {
      debugPrint(
        '📞 Incoming call: callId=${data is Map ? data['callId'] : null}, encrypted=${data is Map && data['crypto'] != null}',
      );
      if (onIncomingCall != null && data != null) {
        onIncomingCall!(Map<String, dynamic>.from(data));
      }
    });

    // WebRTC Call: Call initiated (server-assigned callId for caller)
    _socket?.on('call_initiated', (data) {
      debugPrint('📞 Call initiated: $data');
      if (onCallInitiated != null && data != null) {
        onCallInitiated!(Map<String, dynamic>.from(data));
      }
    });

    _socket?.on('callee_connecting', (data) {
      debugPrint('📞 Callee connecting: $data');
      if (onCalleeConnecting != null && data != null) {
        onCalleeConnecting!(Map<String, dynamic>.from(data));
      }
    });

    // WebRTC Call: Call accepted
    _socket?.on('call_accepted', (data) {
      debugPrint(
        '📞 Call accepted: callId=${data is Map ? data['callId'] : null}, encrypted=${data is Map && data['crypto'] != null}',
      );
      if (onCallAccepted != null && data != null) {
        onCallAccepted!(Map<String, dynamic>.from(data));
      }
    });

    // WebRTC Call: Call rejected
    _socket?.on('call_rejected', (data) {
      debugPrint('📞 Call rejected: $data');
      if (onCallRejected != null && data != null) {
        onCallRejected!(Map<String, dynamic>.from(data));
      }
    });

    // WebRTC Call: Call terminated
    _socket?.on('call_terminated', (data) {
      debugPrint('📞 Call terminated: $data');
      if (data is Map && data['callId'] is String) {
        unawaited(CallKitService().reconcileNativeCalls(
          completedCallId: data['callId'] as String,
        ));
      }
      if (onCallTerminated != null && data != null) {
        onCallTerminated!(Map<String, dynamic>.from(data));
      }
    });

    // WebRTC Call: ICE candidate
    _socket?.on('ice_candidate', (data) {
      debugPrint('📞 ICE candidate received');
      if (onIceCandidate != null && data != null) {
        onIceCandidate!(Map<String, dynamic>.from(data));
      }
    });

    // WebRTC Call: Peer ringing
    _socket?.on('peer_ringing', (data) {
      debugPrint('📞 Peer ringing: $data');
      if (onPeerRinging != null && data != null) {
        onPeerRinging!(Map<String, dynamic>.from(data));
      }
    });

    // WebRTC Call: ICE restart
    _socket?.on('ice_restart', (data) {
      debugPrint(
        '📞 ICE restart: callId=${data is Map ? data['callId'] : null}, encrypted=${data is Map && data['crypto'] != null}',
      );
      if (onIceRestart != null && data != null) {
        onIceRestart!(Map<String, dynamic>.from(data));
      }
    });

    // WebRTC Call: remote camera state update
    _socket?.on('call_media_update', (data) {
      debugPrint('📞 Call media update: $data');
      if (onCallMediaUpdate != null && data != null) {
        onCallMediaUpdate!(Map<String, dynamic>.from(data));
      }
    });

    // WebRTC Call: Call resync - server resends SDP offer after cold-start accept
    _socket?.on('call_resync', (data) {
      debugPrint(
        '📞 Call resync: callId=${data is Map ? data['callId'] : null}',
      );
      if (onCallResync != null && data != null) {
        onCallResync!(Map<String, dynamic>.from(data));
      }
    });

    // WebRTC Call: Server response to a call status probe
    _socket?.on('call_status_response', (data) {
      debugPrint(
        '📞 Call status response: callId=${data is Map ? data['callId'] : null}, exists=${data is Map ? data['exists'] : null}',
      );
      if (onCallStatusResponse != null && data != null) {
        onCallStatusResponse!(Map<String, dynamic>.from(data));
      }
    });

    // Group chat: incoming message
    _socket?.on('group_message', (data) {
      debugPrint('👥 Group message: $data');
      if (onGroupMessageReceived != null && data != null) {
        onGroupMessageReceived!(Map<String, dynamic>.from(data));
      }
    });

    // Group chat: message status update
    _socket?.on('group_message_status', (data) {
      debugPrint('👥 Group message status: $data');
      if (onGroupMessageStatus != null && data != null) {
        onGroupMessageStatus!(Map<String, dynamic>.from(data));
      }
    });

    // Group chat: typing indicator
    _socket?.on('group_typing_indicator', (data) {
      debugPrint('👥 Group typing: $data');
      if (onGroupTyping != null && data != null) {
        onGroupTyping!(Map<String, dynamic>.from(data));
      }
    });

    // Group management events
    _socket?.on('group_created', (data) {
      debugPrint('👥 Group created: $data');
      if (onGroupCreated != null && data != null) {
        onGroupCreated!(Map<String, dynamic>.from(data));
      }
    });
    _socket?.on('group_member_added', (data) {
      debugPrint('👥 Group member added: $data');
      if (onGroupMemberAdded != null && data != null) {
        onGroupMemberAdded!(Map<String, dynamic>.from(data));
      }
    });
    _socket?.on('group_member_removed', (data) {
      debugPrint('👥 Group member removed: $data');
      if (onGroupMemberRemoved != null && data != null) {
        onGroupMemberRemoved!(Map<String, dynamic>.from(data));
      }
    });
    _socket?.on('group_member_left', (data) {
      debugPrint('👥 Group member left: $data');
      if (onGroupMemberLeft != null && data != null) {
        onGroupMemberLeft!(Map<String, dynamic>.from(data));
      }
    });
    _socket?.on('group_info_updated', (data) {
      debugPrint('👥 Group info updated: $data');
      if (onGroupInfoUpdated != null && data != null) {
        onGroupInfoUpdated!(Map<String, dynamic>.from(data));
      }
    });
    _socket?.on('group_dissolved', (data) {
      debugPrint('👥 Group dissolved: $data');
      if (onGroupDissolved != null && data != null) {
        onGroupDissolved!(Map<String, dynamic>.from(data));
      }
    });
  }

  /// Register device with the server
  void setAppForeground(bool isForeground) {
    _isInForeground = isForeground;
    if (isRegistered.value) {
      _socket?.emit('app_state', {'isForeground': isForeground});
    }
  }

  Future<void> _registerDevice() async {
    if (_deviceId == null) {
      debugPrint('⚠️ Cannot register: Device ID is null');
      return;
    }

    // Detect platform
    final platform = Platform.isAndroid ? 'android' : 'ios';

    // Wait briefly for the register_challenge nonce — arrives on connect.
    // If the server doesn't issue one (old deployment), we register without
    // identity fields (transition window).
    final regWatch = Stopwatch()..start();
    String? nonce;
    final challenge = _challengeCompleter;
    if (challenge != null && !challenge.isCompleted) {
      nonce = await challenge.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
    } else if (challenge != null) {
      nonce = await challenge.future;
    }
    callDiag(
      '⏱️ register_challenge wait: ${regWatch.elapsedMilliseconds}ms '
      '(nonce=${nonce != null})',
    );

    // Sign the identity bundle + login when we have keys and a nonce.
    // identitySig proves possession of the bundle's key ("vant-bind");
    // registerSig is the login signature ("vant-reg").
    final signWatch = Stopwatch()..start();
    String? identitySig;
    String? registerSig;
    final bundle = _identityBundle();
    try {
      if (Get.isRegistered<IdentityService>() && nonce != null) {
        final identity = Get.find<IdentityService>();
        final sigs = await Future.wait([
          identity.signBinding(_deviceId!, nonce),
          identity.signRegistration(_deviceId!, nonce),
        ]);
        identitySig = sigs[0];
        registerSig = sigs[1];
      }
    } catch (e) {
      debugPrint('⚠️ Identity signing failed, registering unsigned: $e');
    }
    callDiag(
      '⏱️ identity signing: ${signWatch.elapsedMilliseconds}ms',
    );

    _socket?.emit('register', {
      'deviceId': _deviceId,
      'platform': platform,
      'isForeground': _isInForeground,
      'clientVersion': _clientVersion,
      'capabilities': _announcedCapabilities,
      'identityBundle': bundle,
      'identitySig': identitySig,
      'registerSig': registerSig,
    });
    _registerWatch
      ..reset()
      ..start();
    debugPrint(
        '📝 Device registration requested: $_deviceId (platform: $platform, version: $_clientVersion)');
  }

  /// Client version reported to the server for rollout gating.
  String get _clientVersion => _cachedClientVersion;
  String _cachedClientVersion = 'unknown';

  List<String> get _announcedCapabilities {
    if (!Get.isRegistered<FeatureFlagService>()) return const [];
    final flags = Get.find<FeatureFlagService>();
    final encryptedAvailable = flags.encryptedSignaling.value &&
        Get.isRegistered<IdentityService>() &&
        Get.find<IdentityService>().hasIdentity.value;
    return [
      if (encryptedAvailable) 'encrypted_call',
      if (encryptedAvailable && flags.videoCalling.value) 'video_call',
    ];
  }

  bool _capabilityFlagListenerAdded = false;

  /// Wait up to 3 seconds for the first Remote Config fetch. This keeps the
  /// initial register from publishing capabilities while flags are still at
  /// their safe OFF defaults.
  Future<void> _waitForFeatureFlags() async {
    if (!Get.isRegistered<FeatureFlagService>()) return;
    try {
      await Get.find<FeatureFlagService>()
          .initialFetchCompleted
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
    } catch (_) {
      // Remote Config unreachable — proceed with defaults.
    }
  }

  /// Subscribe to Remote Config flag changes so the server always sees the
  /// current capability set, even when the socket already registered with
  /// an earlier flag state.
  void _subscribeCapabilityFlagUpdates() {
    if (_capabilityFlagListenerAdded ||
        !Get.isRegistered<FeatureFlagService>()) {
      return;
    }
    _capabilityFlagListenerAdded = true;
    Get.find<FeatureFlagService>().onFlagsUpdated(() {
      if (isRegistered.value) {
        sendCapabilitiesUpdate();
      }
    });
  }

  /// Re-announce capabilities over the existing socket. Used when Remote Config
  /// flags change after registration and on app resume.
  void sendCapabilitiesUpdate() {
    if (_socket == null || _deviceId == null) return;
    _socket?.emit('capabilities_update', {
      'clientVersion': _clientVersion,
      'capabilities': _announcedCapabilities,
    });
    debugPrint(
      '📡 Capabilities update sent: $_deviceId -> $_announcedCapabilities',
    );
  }

  /// Identity bundle for the new identityBundle register field.
  /// Null when IdentityService is unavailable or has no keys — the server
  /// treats that as an unbound legacy device.
  String? _identityBundle() {
    try {
      if (Get.isRegistered<IdentityService>()) {
        return Get.find<IdentityService>().identityBundleBase64;
      }
    } catch (_) {}
    return null;
  }

  int _fcmRetryCount = 0;
  static const int _maxFcmRetries = 10;

  /// Register FCM token if available
  Future<void> _registerFCMTokenIfAvailable() async {
    try {
      if (Get.isRegistered<FCMService>()) {
        final fcmService = Get.find<FCMService>();
        await fcmService.registerTokenIfAvailable();
        _fcmRetryCount = 0; // Reset on success
      } else {
        _fcmRetryCount++;
        if (_fcmRetryCount <= _maxFcmRetries) {
          // Silent retry - only log on first attempt
          if (_fcmRetryCount == 1) {
            debugPrint(
              '📱 FCM service initializing, will register token when ready...',
            );
          }
          Future.delayed(const Duration(seconds: 2), () {
            _registerFCMTokenIfAvailable();
          });
        } else {
          debugPrint(
            '⚠️ FCM service not available after $_maxFcmRetries retries',
          );
        }
      }
    } catch (e) {
      debugPrint('📱 FCM service error: $e');
    }
  }

  /// Register FCM token with server
  Future<void> registerFCMToken(String fcmToken) async {
    if (_deviceId == null) {
      debugPrint('⚠️ Cannot register FCM token: Device ID is null');
      return;
    }

    if (!isConnected.value) {
      debugPrint('⚠️ Cannot register FCM token: Socket not connected');
      return;
    }

    if (!isRegistered.value) {
      debugPrint(
          '📱 Deferring FCM token until device registration is confirmed');
      return;
    }

    if (_socket == null) {
      debugPrint('⚠️ Cannot register FCM token: Socket is null');
      return;
    }

    debugPrint('📱 Emitting register_fcm event...');
    debugPrint('📱 Device ID: $_deviceId');
    debugPrint('FCM token length: ${fcmToken.length}');

    _socket!.emit('register_fcm', {
      'deviceId': _deviceId,
      'fcmToken': fcmToken,
    });
    debugPrint('✅ FCM token sent to server for device: $_deviceId');
  }

  /// Send a message to another device with new architecture format
  Future<bool> sendMessage({
    required String messageId,
    required String recipientDeviceId,
    required String content,
    Map<String, dynamic>? replyTo,
    String? fileName,
    int? fileSize,
    bool? isCompressed,
    int? duration,
    String? waveformData,
  }) async {
    if (!isConnected.value) {
      debugPrint('❌ Cannot send message: not connected');
      return false;
    }

    // Check block status before sending (client-side protection)
    try {
      final blockService = Get.find<BlockService>();
      if (!blockService.isMessagingAllowed(recipientDeviceId)) {
        if (blockService.isUserBlocked(recipientDeviceId)) {
          debugPrint(
            '🚫 Cannot send message: I have blocked $recipientDeviceId',
          );
        } else if (blockService.hasUserBlockedMe(recipientDeviceId)) {
          debugPrint(
            '🚫 Cannot send message: $recipientDeviceId has blocked me',
          );
        } else {
          debugPrint(
            '🚫 Cannot send message: Blocking detected with $recipientDeviceId',
          );
        }
        return false;
      }
    } catch (e) {
      debugPrint('⚠️ Could not check block status before sending: $e');
      // Continue with send if block service unavailable (backend will handle)
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // ✅ Encrypt content using EncryptionService
    final encryptedContent = EncryptionService.encryptMessage(content);

    // Notification body policy: text messages send a truncated preview of
    // the content (intended product feature); media sends only its type
    // label. The server sanitizes and applies its own length cap.
    String notificationBody;
    if (content.startsWith('MEDIA:') || content.startsWith('IMAGE:')) {
      notificationBody = '📷 Photo';
    } else if (content.startsWith('FILE:')) {
      notificationBody = '📎 Document';
    } else if (content.startsWith('AUDIO:')) {
      notificationBody = '🎤 Voice message';
    } else {
      // Message previews are an intended product feature: text messages
      // send the content as the notification body, truncated to 100
      // characters (the server also enforces this). Media never sends
      // content — only its type label.
      notificationBody = content.runes.length > 100
          ? String.fromCharCodes(content.runes.take(100))
          : content;
    }

    final messageData = {
      'messageId': messageId,
      'senderDeviceId': _deviceId,
      'receiverDeviceId': recipientDeviceId,
      'encryptedPayload': encryptedContent, // ✅ Now encrypted
      'timestamp': timestamp,
      "body":
          notificationBody, // Generic notification label (never actual content)
      // Don't include sender name - recipient will determine from their local storage
      // Add replyTo if present
      if (replyTo != null) 'replyTo': replyTo,
      // File metadata so receiver can render file bubble
      if (fileName != null) 'fileName': fileName,
      if (fileSize != null) 'fileSize': fileSize,
      if (isCompressed != null) 'compressed': isCompressed,
      if (duration != null) 'duration': duration,
      if (waveformData != null) 'waveformData': waveformData,
    };

    _socket?.emit('send_message', messageData);
    debugPrint(
      '📤 Message sent: $messageId to $recipientDeviceId (hasReply: ${replyTo != null})',
    );
    return true;
  }

  /// Send message acknowledgment
  void sendMessageAck(String messageId) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot send message ack - socket not connected');
      return;
    }

    _socket?.emit('message_ack', {'messageId': messageId});
    debugPrint('✓ Message ACK sent for: $messageId');
  }

  /// Send read acknowledgment
  void sendReadAck(String messageId, String senderDeviceId) {
    if (!isConnected.value) return;

    _socket?.emit('read_ack', {
      'messageId': messageId,
      'senderDeviceId': senderDeviceId,
    });
    debugPrint('👁️ Read ack sent for: $messageId from $senderDeviceId');
  }

  /// Send media download acknowledgment.
  /// This tells the server the recipient has downloaded the multi-recipient media.
  void sendMediaDownloadAck({
    required String messageId,
    required String mediaToken,
  }) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot send media download ack - socket not connected');
      return;
    }

    _socket?.emit('media_download_ack', {
      'messageId': messageId,
      'mediaToken': mediaToken,
    });
    debugPrint('🎤 Media download ack sent for: $messageId');
  }

  /// Send a media-token message to another device.
  ///
  /// The actual image bytes live on the media server; only the tiny
  /// "MEDIA:{token}" string travels over the socket.
  Future<bool> sendMediaMessage({
    required String messageId,
    required String recipientDeviceId,
    required String mediaToken,
  }) async {
    debugPrint('📷 SocketService.sendMediaMessage token=$mediaToken');

    if (!isConnected.value) {
      debugPrint('❌ Cannot send media message: not connected');
      return false;
    }

    // Reuse the regular text send path — content is just MEDIA:{token}
    return sendMessage(
      messageId: messageId,
      recipientDeviceId: recipientDeviceId,
      content: 'MEDIA:$mediaToken',
    );
  }

  /// Send a file-token message to another device.
  Future<bool> sendFileMessage({
    required String messageId,
    required String recipientDeviceId,
    required String mediaToken,
    required String fileName,
    required int fileSize,
    bool isCompressed = false,
  }) async {
    debugPrint(
        '📎 SocketService.sendFileMessage token=$mediaToken file=$fileName');

    if (!isConnected.value) {
      debugPrint('❌ Cannot send file message: not connected');
      return false;
    }

    return sendMessage(
      messageId: messageId,
      recipientDeviceId: recipientDeviceId,
      content: 'FILE:$mediaToken',
      fileName: fileName,
      fileSize: fileSize,
      isCompressed: isCompressed,
    );
  }

  /// Send an audio-token message to another device.
  Future<bool> sendAudioMessage({
    required String messageId,
    required String recipientDeviceId,
    required String mediaToken,
    required int duration,
    String? waveformData,
  }) async {
    debugPrint(
        '🎤 SocketService.sendAudioMessage token=$mediaToken duration=$duration');

    if (!isConnected.value) {
      debugPrint('❌ Cannot send audio message: not connected');
      return false;
    }

    return sendMessage(
      messageId: messageId,
      recipientDeviceId: recipientDeviceId,
      content: 'AUDIO:$mediaToken',
      fileName: 'audio.m4a',
      fileSize: duration,
      duration: duration,
      waveformData: waveformData,
    );
  }

  /// Send a message to a group.
  /// [encryptedPayload] is the encrypted message content.
  Future<bool> sendGroupMessage({
    required String groupId,
    required String messageId,
    required String encryptedPayload,
    required String messageType,
    Map<String, dynamic>? replyTo,
    String? fileName,
    int? fileSize,
    bool? isCompressed,
    int? duration,
    String? waveformData,
  }) async {
    if (!isConnected.value) {
      debugPrint('❌ Cannot send group message: not connected');
      return false;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final payload = {
      'groupId': groupId,
      'messageId': messageId,
      'encryptedPayload': encryptedPayload,
      'messageType': messageType,
      'timestamp': timestamp,
      if (replyTo != null) 'replyTo': replyTo,
      if (fileName != null) 'fileName': fileName,
      if (fileSize != null) 'fileSize': fileSize,
      if (isCompressed != null) 'compressed': isCompressed,
      if (duration != null) 'duration': duration,
      if (waveformData != null) 'waveformData': waveformData,
    };

    _socket?.emit('group_send_message', payload);
    debugPrint('👥 Group message sent: $messageId to $groupId');
    return true;
  }

  /// Send media message to a group.
  Future<bool> sendGroupMediaMessage({
    required String groupId,
    required String messageId,
    required String mediaToken,
    Map<String, dynamic>? replyTo,
  }) async {
    return sendGroupMessage(
      groupId: groupId,
      messageId: messageId,
      encryptedPayload: 'MEDIA:$mediaToken',
      messageType: 'image',
      replyTo: replyTo,
    );
  }

  /// Send file message to a group.
  Future<bool> sendGroupFileMessage({
    required String groupId,
    required String messageId,
    required String mediaToken,
    required String fileName,
    required int fileSize,
    Map<String, dynamic>? replyTo,
    bool isCompressed = false,
  }) async {
    return sendGroupMessage(
      groupId: groupId,
      messageId: messageId,
      encryptedPayload: 'FILE:$mediaToken',
      messageType: 'file',
      replyTo: replyTo,
      fileName: fileName,
      fileSize: fileSize,
      isCompressed: isCompressed,
    );
  }

  /// Send an audio-token message to a group.
  Future<bool> sendGroupAudioMessage({
    required String groupId,
    required String messageId,
    required String mediaToken,
    required int duration,
    String? waveformData,
  }) async {
    debugPrint(
        '🎤 SocketService.sendGroupAudioMessage token=$mediaToken duration=$duration');

    if (!isConnected.value) {
      debugPrint('❌ Cannot send group audio message: not connected');
      return false;
    }

    return sendGroupMessage(
      groupId: groupId,
      messageId: messageId,
      encryptedPayload: 'AUDIO:$mediaToken',
      messageType: 'audio',
      fileName: 'audio.m4a',
      fileSize: duration,
      duration: duration,
      waveformData: waveformData,
    );
  }

  /// Send group message delivery acknowledgment.
  void sendGroupMessageAck(
      {required String messageId, required String groupId}) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot send group message ack - socket not connected');
      return;
    }

    _socket?.emit('group_message_ack', {
      'messageId': messageId,
      'groupId': groupId,
    });
    debugPrint('✓ Group message ACK sent for: $messageId in $groupId');
  }

  /// Send group message read acknowledgment.
  void sendGroupReadAck({required String messageId, required String groupId}) {
    if (!isConnected.value) return;

    _socket?.emit('group_read_ack', {
      'messageId': messageId,
      'groupId': groupId,
    });
    debugPrint('👁️ Group read ack sent for: $messageId in $groupId');
  }

  /// Send group typing indicator.
  void sendGroupTyping({required String groupId, required bool isTyping}) {
    if (!isConnected.value) return;

    _socket?.emit('group_typing', {
      'groupId': groupId,
      'isTyping': isTyping,
    });
    debugPrint('👥 Group typing sent: $isTyping to $groupId');
  }

  /// Block a user
  void blockUser(String targetDeviceId) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot block user: not connected');
      return;
    }
    _socket?.emit('block_user', {'targetDeviceId': targetDeviceId});
    debugPrint('🚫 Block user request sent for: $targetDeviceId');
  }

  /// Unblock a user
  void unblockUser(String targetDeviceId) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot unblock user: not connected');
      return;
    }
    _socket?.emit('unblock_user', {'targetDeviceId': targetDeviceId});
    debugPrint('✅ Unblock user request sent for: $targetDeviceId');
  }

  /// Check block status with a user
  void checkBlockStatus(String targetDeviceId) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot check block status: not connected');
      return;
    }
    _socket?.emit('check_block_status', {'targetDeviceId': targetDeviceId});
    debugPrint('🔍 Check block status request sent for: $targetDeviceId');
  }

  /// Schedule reconnection attempt with exponential backoff
  void _scheduleReconnect() {
    _cancelReconnectTimer();

    // Limit reconnection attempts to prevent infinite loops
    if (_reconnectAttempts >= 10) {
      debugPrint('🛑 Max reconnection attempts reached, stopping reconnection');
      return;
    }

    // Exponential backoff: 5s, 10s, 20s, 40s, 60s (max)
    final delay = Duration(
      seconds: (5 * (1 << _reconnectAttempts)).clamp(5, 60),
    );
    _reconnectAttempts++;

    debugPrint(
      '🔄 Scheduling reconnect attempt #$_reconnectAttempts in ${delay.inSeconds}s',
    );

    _reconnectTimer = Timer(delay, () {
      if (!isConnected.value && !_isConnecting) {
        debugPrint(
          '🔄 Attempting to reconnect (attempt #$_reconnectAttempts)...',
        );
        connect();
      }
    });
  }

  /// Cancel reconnection timer
  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Test connection and get diagnostic information
  Future<Map<String, dynamic>> getConnectionDiagnostics() async {
    final diagnostics = <String, dynamic>{};

    diagnostics['serverUrl'] = _serverUrl;
    diagnostics['deviceId'] = _deviceId;
    diagnostics['isConnected'] = isConnected.value;
    diagnostics['isRegistered'] = isRegistered.value;
    diagnostics['connectionStatus'] = connectionStatus.value;
    diagnostics['socketId'] = _socket?.id;
    diagnostics['socketConnected'] = _socket?.connected ?? false;

    // Test server reachability
    try {
      final response = await Future.delayed(const Duration(seconds: 3), () {
        return 'Server reachable';
      });
      diagnostics['serverReachability'] = response;
    } catch (e) {
      diagnostics['serverReachability'] = 'Error: $e';
    }

    debugPrint('🔍 Connection Diagnostics:');
    diagnostics.forEach((key, value) {
      debugPrint('   $key: $value');
    });

    return diagnostics;
  }

  Future<void> reconnectForCallResync() async {
    // A socket that is already connected (or still finishing registration)
    // is good enough for resync — tearing it down restarts registration and
    // wastes seconds on the accept path.
    if (isConnected.value || _isConnecting) {
      debugPrint(
        '⚡ Call resync: socket already connected/connecting, reusing',
      );
      return;
    }
    _reconnectAttempts = 0;
    _cancelReconnectTimer();
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    isConnected.value = false;
    isRegistered.value = false;
    _isConnecting = false;
    await connect();
  }

  /// Force reconnect - resets reconnect counter and connects immediately
  /// Called when app resumes from background to ensure socket is live
  Future<void> forceReconnect() async {
    _reconnectAttempts = 0;
    _cancelReconnectTimer();
    _isConnecting = false;
    debugPrint('🔄 Force reconnect requested');
    await connect();
  }

  /// Switch to a new device ID and re-register. Used by the identity-conflict
  /// recovery flow when this ID is already bound to a different key.
  /// Reconnects so the fresh socket gets a new register_challenge nonce.
  Future<void> switchDeviceId(String newDeviceId) async {
    if (newDeviceId == _deviceId) return;
    debugPrint('🆔 Switching device ID: $_deviceId -> $newDeviceId');
    _deviceId = newDeviceId;
    _reconnectAttempts = 0;
    _cancelReconnectTimer();
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    isConnected.value = false;
    isRegistered.value = false;
    _isConnecting = false;
    await connect();
  }

  /// Disconnect from server
  void disconnect() {
    _cancelReconnectTimer();
    _connectivitySubscription?.cancel();
    _socket?.disconnect();
    _socket = null;
    isConnected.value = false;
    isRegistered.value = false;
    connectionStatus.value = 'disconnected';

    // Update UserDefaults for iOS background notification handling
    _updateSocketConnectionStatus(false);

    debugPrint('🔌 Socket disconnected manually');
  }

  /// Update socket connection status in UserDefaults for iOS background notification handling
  void _updateSocketConnectionStatus(bool isConnected) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('socket_connected', isConnected);
      debugPrint(
        '📱 Socket connection status updated in UserDefaults: $isConnected',
      );
    } catch (e) {
      debugPrint(
        '⚠️ Failed to update socket connection status in UserDefaults: $e',
      );
    }
  }

  /// Decrypt message content
  static String decryptMessage(String content) {
    return EncryptionService.decryptMessage(content);
  }

  /// Send a connection request to another device
  Future<bool> sendConnectionRequest(
    String targetDeviceId, {
    String? messageContent,
    String? senderName,
  }) async {
    if (!isConnected.value) {
      debugPrint('❌ Cannot send connection request: not connected');
      return false;
    }

    final requestId = 'req_${DateTime.now().millisecondsSinceEpoch}';
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // Encrypt message content if provided
    String? encryptedContent;
    if (messageContent != null && messageContent.isNotEmpty) {
      encryptedContent = EncryptionService.encryptMessage(messageContent);
    }

    final requestData = {
      'requestId': requestId,
      'targetDeviceId': targetDeviceId,
      'senderDeviceId': _deviceId,
      'timestamp': timestamp,
      if (senderName != null && senderName.trim().isNotEmpty)
        'senderName': senderName.trim(),
    };

    // Add encrypted message content if provided
    if (encryptedContent != null) {
      requestData['encryptedPayload'] = encryptedContent;
      requestData['body'] = messageContent;
    }

    debugPrint('🤝 DEBUG: Emitting send_connection_request event');
    debugPrint('🤝 DEBUG: Request data: $requestData');

    _socket?.emit('send_connection_request', requestData);

    debugPrint('🤝 DEBUG: Connection request emitted successfully');
    debugPrint(
      '🤝 Connection request sent: $requestId to $targetDeviceId with message: ${messageContent ?? "none"}',
    );
    return true;
  }

  /// Respond to a connection request
  Future<bool> respondToConnectionRequest(
    String requestId,
    bool accepted, {
    String? senderDeviceId,
  }) async {
    if (!isConnected.value) {
      debugPrint('❌ Cannot respond to connection request: not connected');
      return false;
    }

    _socket?.emit('respond_connection_request', {
      'requestId': requestId,
      'accepted': accepted,
      'responderDeviceId': _deviceId,
      if (senderDeviceId != null) 'senderDeviceId': senderDeviceId,
    });

    debugPrint(
      '🤝 Connection request response sent: $requestId -> $accepted (sender: $senderDeviceId)',
    );
    return true;
  }

  /// Check if a device is online
  void checkPresence(String deviceId) {
    if (!isConnected.value) return;

    _socket?.emit('check_presence', {'deviceId': deviceId});
  }

  /// Get all online users
  void getOnlineUsers() {
    if (!isConnected.value) return;

    _socket?.emit('get_online_users');
  }

  // WebRTC Call Signaling Methods

  /// Initiate a call. Returns false when the socket is not connected so the
  /// caller can surface a visible failure instead of hanging on "Dialing…".
  bool initiateCall({
    required String callerId,
    required String calleeId,
    String? sdpOffer,
    String? callerName,
    bool isVideo = false,
    Map<String, dynamic>? crypto,
  }) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot initiate call: not connected');
      return false;
    }

    final payload = buildCallInitiatePayload(
      callerId: callerId,
      calleeId: calleeId,
      sdpOffer: sdpOffer,
      callerName: callerName,
      crypto: crypto,
    );
    if (isVideo) payload['isVideo'] = true;
    _socket?.emit('call_initiate', payload);
    debugPrint('📞 Call initiated: $callerId -> $calleeId');
    return true;
  }

  // ---------------------------------------------------------------------------
  // Call event payloads — CONTRACT: the voice-call wire shape below is frozen.
  // Any change breaks shipped clients. Pinned by test/call_contract_test.dart.
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> buildCallInitiatePayload({
    required String callerId,
    required String calleeId,
    String? sdpOffer,
    String? callerName,
    Map<String, dynamic>? crypto,
  }) =>
      {
        'callerId': callerId,
        'calleeId': calleeId,
        if (sdpOffer != null) 'sdpOffer': sdpOffer,
        if (callerName != null && callerName.isNotEmpty)
          'callerName': callerName,
        if (crypto != null) 'crypto': crypto,
      };

  static Map<String, dynamic> buildCallAcceptPayload({
    required String callId,
    required String callerId,
    String? sdpAnswer,
    Map<String, dynamic>? crypto,
  }) =>
      {
        'callId': callId,
        'callerId': callerId,
        if (sdpAnswer != null) 'sdpAnswer': sdpAnswer,
        if (crypto != null) 'crypto': crypto,
      };

  static Map<String, dynamic> buildCallRejectPayload({
    required String callId,
    required String callerId,
    String? reason,
  }) =>
      {'callId': callId, 'callerId': callerId, 'reason': reason ?? 'rejected'};

  static Map<String, dynamic> buildCallTerminatePayload({
    required String callId,
    String? reason,
  }) =>
      {'callId': callId, 'reason': reason ?? 'ended'};

  static Map<String, dynamic> buildIceCandidatePayload({
    required String callId,
    required String targetDeviceId,
    String? candidate,
    String? sdpMid,
    int? sdpMLineIndex,
    Map<String, dynamic>? crypto,
  }) =>
      {
        'callId': callId,
        'targetDeviceId': targetDeviceId,
        if (candidate != null) 'candidate': candidate,
        'sdpMid': sdpMid,
        'sdpMLineIndex': sdpMLineIndex,
        if (crypto != null) 'crypto': crypto,
      };

  /// Accept a call
  void acceptCall({
    required String callId,
    required String callerId,
    String? sdpAnswer,
    Map<String, dynamic>? crypto,
  }) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot accept call: not connected');
      return;
    }

    _socket?.emit(
        'call_accept',
        buildCallAcceptPayload(
          callId: callId,
          callerId: callerId,
          sdpAnswer: sdpAnswer,
          crypto: crypto,
        ));
    debugPrint('📞 Call accepted: $callId');
  }

  /// Reject a call
  void rejectCall({
    required String callId,
    required String callerId,
    String? reason,
  }) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot reject call: not connected');
      return;
    }

    _socket?.emit(
        'call_reject',
        buildCallRejectPayload(
          callId: callId,
          callerId: callerId,
          reason: reason,
        ));
    debugPrint('📞 Call rejected: $callId');
  }

  /// Terminate a call
  void terminateCall({required String callId, String? reason}) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot terminate call: not connected');
      return;
    }

    _socket?.emit(
        'call_terminate',
        buildCallTerminatePayload(
          callId: callId,
          reason: reason,
        ));
    debugPrint('📞 Call terminated: $callId');
  }

  /// Send ICE candidate
  void sendIceCandidate({
    required String callId,
    required String targetDeviceId,
    String? candidate,
    String? sdpMid,
    int? sdpMLineIndex,
    Map<String, dynamic>? crypto,
  }) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot send ICE candidate: not connected');
      return;
    }

    _socket?.emit(
        'ice_candidate',
        buildIceCandidatePayload(
          callId: callId,
          targetDeviceId: targetDeviceId,
          candidate: candidate,
          sdpMid: sdpMid,
          sdpMLineIndex: sdpMLineIndex,
          crypto: crypto,
        ));
    debugPrint(
      '📞 ICE candidate sent: sdpMid=$sdpMid, sdpMLineIndex=$sdpMLineIndex',
    );
  }

  /// Notify peer that device is ringing
  void notifyPeerRinging({required String callId, required String callerId}) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot notify peer ringing: not connected');
      return;
    }

    _socket?.emit('peer_ringing', {'callId': callId, 'callerId': callerId});
    debugPrint('📞 Peer ringing notified');
  }

  /// Request ICE restart
  void requestIceRestart({
    required String callId,
    required String targetDeviceId,
    String? sdpOffer,
    String? sdpAnswer,
    Map<String, dynamic>? crypto,
  }) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot request ICE restart: not connected');
      return;
    }

    _socket?.emit('ice_restart', {
      'callId': callId,
      'targetDeviceId': targetDeviceId,
      if (sdpOffer != null) 'sdpOffer': sdpOffer,
      if (sdpAnswer != null) 'sdpAnswer': sdpAnswer,
      if (crypto != null) 'crypto': crypto,
    });
    debugPrint('📞 ICE restart requested');
  }

  /// Notify the peer that local camera transmission changed.
  void sendCallMediaUpdate({
    required String callId,
    required bool video,
  }) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot send call media update: not connected');
      return;
    }
    _socket?.emit(
      'call_media_update',
      CallMediaHelper.mediaUpdatePayload(callId: callId, video: video),
    );
  }

  /// Memoized ICE list — TURN creds stay valid for their server TTL, so a
  /// burst of peer connections must not mint a credential per request.
  final _iceServersCache = IceServersRequestCache();

  /// Fetch the current STUN/TURN ICE configuration for this registered device.
  /// TURN credentials are generated by the server and expire server-side.
  /// A failed/rate-limited fetch falls back to the last still-valid list
  /// instead of a STUN-only configuration.
  Future<List<Map<String, dynamic>>?> requestIceServers() async {
    if (!isRegistered.value || _socket == null) return null;
    return _iceServersCache.request(_fetchIceServers);
  }

  Future<({List<Map<String, dynamic>>? servers, int? expiresAtEpoch})>
      _fetchIceServers() {
    final completer =
        Completer<({List<Map<String, dynamic>>? servers, int? expiresAtEpoch})>();
    const empty = (
      servers: null as List<Map<String, dynamic>>?,
      expiresAtEpoch: null as int?,
    );
    _socket!.emitWithAck(
      'call_ice_servers',
      <String, dynamic>{},
      ack: (data) {
        if (data is! Map || data['iceServers'] is! List) {
          completer.complete(empty);
          return;
        }
        final servers = <Map<String, dynamic>>[];
        for (final item in data['iceServers'] as List) {
          if (item is Map) {
            servers.add(Map<String, dynamic>.from(item));
          }
        }
        final exp = data['expiresAt'];
        completer.complete((
          servers: servers.isEmpty ? null : servers,
          expiresAtEpoch: exp is num ? exp.toInt() : null,
        ));
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => empty,
    );
  }

  /// Ask the server for a peer's rollout capabilities.
  Future<Map<String, dynamic>?> requestPeerCapabilities(
    String deviceId,
  ) async {
    if (!isConnected.value || _socket == null) return null;
    final completer = Completer<Map<String, dynamic>?>();
    _socket!.emitWithAck(
      'peer_capability',
      {'deviceId': deviceId},
      ack: (data) {
        completer.complete(
          data is Map ? Map<String, dynamic>.from(data) : null,
        );
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => null,
    );
  }

  /// Send an identity announcement (self-signed bundle) to a contact.
  /// Returns true if the server relayed it to an online peer socket.
  Future<bool> sendIdentityAnnounce({
    required String to,
    required String bundle,
    required String signature,
    List<String>? capabilities,
    int? capabilitySeq,
    String? capabilitySig,
  }) async {
    if (_socket == null || !_socket!.connected) return false;
    final completer = Completer<bool>();
    _socket!.emitWithAck(
      'identity_announce',
      {
        'to': to,
        'bundle': bundle,
        'signature': signature,
        if (capabilities != null &&
            capabilitySeq != null &&
            capabilitySig != null)
          'capabilities': capabilities,
        if (capabilities != null &&
            capabilitySeq != null &&
            capabilitySig != null)
          'capabilitySeq': capabilitySeq,
        if (capabilities != null &&
            capabilitySeq != null &&
            capabilitySig != null)
          'capabilitySig': capabilitySig,
      },
      ack: (data) {
        completer.complete(data is Map && data['delivered'] == true);
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
  }

  /// Tell the announcer our pin result for their bundle, so they stop
  /// retrying. The server relays it as 'identity_announce_acked'.
  /// [bundleHash] lets the sender match the ack to the exact bundle sent —
  /// stale or misattributed acks are ignored.
  void sendIdentityAnnounceAck({
    required String to,
    required String status,
    String? bundleHash,
  }) {
    if (_socket == null || !_socket!.connected) return;
    _socket!.emit('identity_announce_ack', {
      'to': to,
      'status': status,
      'bundleHash': bundleHash,
    });
  }

  /// Send a verification echo to the QR displayer. The server requires the
  /// echoed bundle to equal our durably bound bundle. Returns delivery ack.
  Future<bool> sendVerifyEcho({
    required String to,
    required String bundle,
    required String mac,
  }) async {
    if (_socket == null || !_socket!.connected) return false;
    final completer = Completer<bool>();
    _socket!.emitWithAck(
      'verify_echo',
      {'to': to, 'bundle': bundle, 'mac': mac},
      ack: (data) {
        completer.complete(data is Map && data['delivered'] == true);
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
  }

  /// Request call status - used when the socket reconnects mid-call to ask the
  /// server whether the call still exists. Server answers with
  /// call_status_response; if the call is gone the client ends locally.
  void requestCallStatus({required String callId}) {
    if (!isRegistered.value) {
      debugPrint('❌ Cannot request call status: socket is not registered');
      return;
    }

    _socket?.emit('call_status', {'callId': callId});
    debugPrint('📞 Call status requested for $callId');
  }

  /// Request call resync - used when app cold-starts after accepting from CallKit
  /// Server will resend the SDP offer so the callee can answer
  /// Last resync emit per callId — duplicate triggers (pending-accept
  /// watcher + isRegistered listener firing together) produce duplicate
  /// server responses that race the accept path.
  String? _lastResyncCallId;
  DateTime? _lastResyncAt;

  void requestCallResync({required String callId}) {
    if (!isRegistered.value) {
      debugPrint('❌ Cannot request call resync: socket is not registered');
      return;
    }
    final now = DateTime.now();
    if (_lastResyncCallId == callId &&
        _lastResyncAt != null &&
        now.difference(_lastResyncAt!) < const Duration(seconds: 3)) {
      debugPrint('📞 Resync for $callId already sent — skipping duplicate');
      return;
    }
    _lastResyncCallId = callId;
    _lastResyncAt = now;

    _socket?.emit('call_resync', {'callId': callId});
    debugPrint('📞 Call resync requested for $callId');
    logCallBreadcrumb(CallBreadcrumb.resyncRequest);
  }

  /// Get socket instance for direct event listening
  get socket => _socket;

  /// Store backend URL for HTTP delivery acknowledgments
  Future<void> _storeBackendUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('backend_url', _serverUrl);
      debugPrint('💾 Backend URL stored: $_serverUrl');
    } catch (e) {
      debugPrint('⚠️ Error storing backend URL: $e');
    }
  }

  @override
  void onClose() {
    _connectivitySubscription?.cancel();
    disconnect();
    super.onClose();
  }
}
