import 'dart:async';
import 'dart:io' show Platform;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'encryption_service.dart';
import 'fcm_service.dart';
import 'block_service.dart';
import 'connection_request_service.dart';
import '../constants/network_constants.dart';

class SocketService extends GetxService {
  // Live server URL
  static const String _serverUrl = NetworkConstants.socketUrl;
  IO.Socket? _socket;
  String? _deviceId;
  Timer? _reconnectTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isConnecting = false; // Prevent duplicate connection attempts
  int _reconnectAttempts = 0;

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
  Function(Map<String, dynamic>)? onCallResync;

  // Getters
  String? get deviceId => _deviceId;

  /// Initialize the socket service with device ID
  Future<SocketService> init(String deviceId) async {
    _deviceId = deviceId;
    debugPrint('🔌 SocketService initialized with deviceId: $_deviceId');
    _setupConnectivityListener();
    await connect();
    return this;
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
      debugPrint('   - Transports: polling, websocket');
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
        await connectionService.cleanupDuplicateConnections();
      }
    } catch (e) {
      debugPrint('⚠️ Could not cleanup connections before reconnect: $e');
    }

    await forceReconnect();
  }

  /// Setup socket event listeners
  void _setupSocketListeners() {
    _socket?.on('connect', (_) {
      debugPrint('✅ Socket connected');
      isConnected.value = true;
      connectionStatus.value = 'connected';
      _isConnecting = false; // Reset connecting flag
      _reconnectAttempts =
          0; // Reset reconnection attempts on successful connection
      _cancelReconnectTimer();

      // Update UserDefaults for iOS background notification handling
      _updateSocketConnectionStatus(true);

      // Store backend URL for HTTP delivery ack
      _storeBackendUrl();

      _registerDevice();

      // Send pending delivery acknowledgments for FCM messages received while offline
      FCMService.sendPendingAcknowledgments();
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
      debugPrint('❌ Socket connection error: $error');
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
      debugPrint('📬 Pending messages received: ${(data as List).length}');
      if (onPendingMessages != null) {
        final messages = (data)
            .map((msg) => Map<String, dynamic>.from(msg))
            .toList();
        onPendingMessages!(messages);
        // Send message acks for all pending messages
        for (final message in messages) {
          sendMessageAck(message['messageId']);
        }
      }
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
      debugPrint('📞 Incoming call: $data');
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

    // WebRTC Call: Call accepted
    _socket?.on('call_accepted', (data) {
      debugPrint('📞 Call accepted: $data');
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
      debugPrint('📞 ICE restart: $data');
      if (onIceRestart != null && data != null) {
        onIceRestart!(Map<String, dynamic>.from(data));
      }
    });

    // WebRTC Call: Call resync - server resends SDP offer after cold-start accept
    _socket?.on('call_resync', (data) {
      debugPrint('📞 Call resync: $data');
      if (onCallResync != null && data != null) {
        onCallResync!(Map<String, dynamic>.from(data));
      }
    });
  }

  /// Register device with the server
  void _registerDevice() {
    if (_deviceId == null) {
      debugPrint('⚠️ Cannot register: Device ID is null');
      return;
    }

    // Detect platform
    final platform = Platform.isAndroid ? 'android' : 'ios';

    _socket?.emit('register', {'deviceId': _deviceId, 'platform': platform});
    isRegistered.value = true;
    debugPrint('📝 Device registered: $_deviceId (platform: $platform)');

    // Also register FCM token if available
    _registerFCMTokenIfAvailable();
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

    if (_socket == null) {
      debugPrint('⚠️ Cannot register FCM token: Socket is null');
      return;
    }

    debugPrint('📱 Emitting register_fcm event...');
    debugPrint('📱 Device ID: $_deviceId');
    debugPrint('📱 FCM Token: $fcmToken');

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

    // PRIVACY: Never send actual message content in the notification body.
    // The server sends a generic "You have a new message" notification body to
    // FCM/APNs so no message content is ever visible to push servers or on
    // the lock screen.
    String notificationBody = 'You have a new message';
    if (content.startsWith('MEDIA:') || content.startsWith('IMAGE:')) {
      notificationBody = '📷 Photo';
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
    };

    _socket?.emit('send_message', messageData);
    debugPrint(
      '📤 Message sent: $messageId to $recipientDeviceId (notification: $notificationBody, hasReply: ${replyTo != null})',
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

  /// Force reconnect - resets reconnect counter and connects immediately
  /// Called when app resumes from background to ensure socket is live
  Future<void> forceReconnect() async {
    _reconnectAttempts = 0;
    _cancelReconnectTimer();
    _isConnecting = false;
    debugPrint('🔄 Force reconnect requested');
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

  /// Initiate a call
  void initiateCall({
    required String callerId,
    required String calleeId,
    required String sdpOffer,
    String? callerName,
  }) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot initiate call: not connected');
      return;
    }

    _socket?.emit('call_initiate', {
      'callerId': callerId,
      'calleeId': calleeId,
      'sdpOffer': sdpOffer,
      if (callerName != null && callerName.isNotEmpty) 'callerName': callerName,
    });
    debugPrint('📞 Call initiated: $callerId -> $calleeId');
  }

  /// Accept a call
  void acceptCall({
    required String callId,
    required String callerId,
    required String sdpAnswer,
  }) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot accept call: not connected');
      return;
    }

    _socket?.emit('call_accept', {
      'callId': callId,
      'callerId': callerId,
      'sdpAnswer': sdpAnswer,
    });
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

    _socket?.emit('call_reject', {
      'callId': callId,
      'callerId': callerId,
      'reason': reason ?? 'rejected',
    });
    debugPrint('📞 Call rejected: $callId');
  }

  /// Terminate a call
  void terminateCall({required String callId, String? reason}) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot terminate call: not connected');
      return;
    }

    _socket?.emit('call_terminate', {
      'callId': callId,
      'reason': reason ?? 'ended',
    });
    debugPrint('📞 Call terminated: $callId');
  }

  /// Send ICE candidate
  void sendIceCandidate({
    required String callId,
    required String targetDeviceId,
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot send ICE candidate: not connected');
      return;
    }

    _socket?.emit('ice_candidate', {
      'callId': callId,
      'targetDeviceId': targetDeviceId,
      'candidate': candidate,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
    });
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
  }) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot request ICE restart: not connected');
      return;
    }

    _socket?.emit('ice_restart', {
      'callId': callId,
      'targetDeviceId': targetDeviceId,
    });
    debugPrint('📞 ICE restart requested');
  }

  /// Request call resync - used when app cold-starts after accepting from CallKit
  /// Server will resend the SDP offer so the callee can answer
  void requestCallResync({required String callId}) {
    if (!isConnected.value) {
      debugPrint('❌ Cannot request call resync: not connected');
      return;
    }

    _socket?.emit('call_resync', {'callId': callId});
    debugPrint('📞 Call resync requested for $callId');
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
