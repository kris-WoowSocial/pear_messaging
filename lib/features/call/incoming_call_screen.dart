import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pear_messaging/core/services/feature_flag_service.dart';
import 'package:pear_messaging/core/services/notification_service.dart';
import 'package:pear_messaging/core/services/socket_service.dart';
import 'call_controller.dart';
import 'call_encryption_indicator.dart';
import '../../core/services/ringtone_service.dart';
import '../../core/services/callkit_service.dart';

/// Incoming Call Screen - Full-screen overlay for incoming audio calls
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({super.key});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _pulseAnimation;
  bool _isAccepting = false;
  Worker? _callStateWorker;

  CallController get _controller => Get.find<CallController>();

  @override
  void initState() {
    super.initState();
    _setupAnimation();
    _callStateWorker = ever(_controller.callState, _onCallStateChanged);
    if (Platform.isIOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        final callId = (Get.arguments as Map?)?['callId'] as String?;
        // Never 'late'-end a PushKit-owned call — its CallKit record is the
        // real call UI, not a foreground ghost.
        if (callId != null && !_controller.isPushOwnedCallId(callId)) {
          CallKitService().endGhostCallKitForCall(callId, reason: 'late');
        }
      });
    }
  }

  void _onCallStateChanged(CallState state) {
    if (state == CallState.ended || state == CallState.idle) {
      _closeCallRoute();
    }
  }

  /// Pop this call route and anything that may have been pushed on top of it
  /// (snackbars, dialogs) without touching routes underneath.
  void _closeCallRoute() {
    if (!mounted) return;
    final routeName = ModalRoute.of(context)?.settings.name;
    if (routeName == null || !routeName.startsWith('/call/')) return;
    final navigator = Navigator.of(context);
    // If the call screen is the root route (CallKit/PushKit accept replaced the
    // stack, or the app cold-started for the call), popping would leave an
    // empty navigator — iOS shows a black screen. Land on the chat list instead.
    if (!navigator.canPop()) {
      Get.offAllNamed('/chat-list');
      return;
    }
    navigator.popUntil((route) => route.settings.name != routeName);
  }

  void _setupAnimation() {
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _callStateWorker?.dispose();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final callData = Get.arguments as Map<String, dynamic>?;
    final callerId = callData?['callerId'] as String? ?? '';
    final isVideo = callData?['isVideo'] == true;
    final controller = Get.find<CallController>();
    if (callerId.isNotEmpty && controller.remoteDisplayName.value.isEmpty) {
      controller.resolveDisplayNamePublic(callerId);
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        // Intercept the Android back button and minimize instead of leaving
        // the app — the incoming call keeps ringing via the notification.
        if (didPop) return;
        controller.minimizeCallScreen(context);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              // Top section - Caller info
              Expanded(
                flex: 2,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Avatar with pulse animation
                      AnimatedBuilder(
                        animation: _pulseAnimation,
                        builder: (context, child) {
                          return Transform.scale(
                            scale: _pulseAnimation.value,
                            child: Container(
                              width: 120,
                              height: 120,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.grey[800],
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.3),
                                  width: 2,
                                ),
                              ),
                              child: const Icon(
                                Icons.person,
                                size: 60,
                                color: Colors.white,
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 32),
                      // Caller name
                      Obx(
                        () => Text(
                          controller.remoteDisplayName.value.isNotEmpty
                              ? controller.remoteDisplayName.value
                              : (callerId.isNotEmpty
                                  ? '@user_${callerId.substring(callerId.length >= 5 ? callerId.length - 5 : 0)}'
                                  : 'Unknown'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Call status
                      Text(
                        isVideo ? 'Incoming video call' : 'Incoming call...',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Obx(
                        () => CallEncryptionIndicator(
                          state: controller.callEncryptionState.value,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Bottom section - Action buttons
              Expanded(
                flex: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 48,
                    vertical: 32,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Decline button
                      _buildActionButton(
                        icon: Icons.call_end,
                        color: Colors.red,
                        label: 'Decline',
                        onTap: () {
                          _declineCall(callData);
                        },
                      ),
                      // Accept button
                      _buildActionButton(
                        icon: Icons.call,
                        color: Colors.green,
                        label: _isAccepting ? 'Connecting...' : 'Accept',
                        onTap: _isAccepting
                            ? () {}
                            : () {
                                _acceptCall(callData);
                              },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(0.4),
                  blurRadius: 12,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Icon(icon, size: 32, color: Colors.white),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Future<void> _acceptCall(Map<String, dynamic>? callData) async {
    if (callData == null || _isAccepting) return;

    setState(() {
      _isAccepting = true;
    });

    final callId = callData['callId'] as String?;
    final callerId = callData['callerId'] as String? ?? '';
    final sdpOffer = callData['sdpOffer'] as String?;
    final isVideo = callData['isVideo'] == true;

    try {
      final controller = Get.find<CallController>();
      final ringtoneService = RingtoneService();
      if (Platform.isIOS && callId != null) {
        final status = await CallKitService().endGhostCallKitForCall(callId, reason: 'accept');
        await ringtoneService.stopRingtone();
        if (status == 'native_answered') return;
      }
      final hasDirectOffer = (sdpOffer != null && sdpOffer.isNotEmpty) ||
          callData['crypto'] is Map;
      final videoUiEnabled = isVideo &&
          Get.isRegistered<FeatureFlagService>() &&
          Get.find<FeatureFlagService>().videoCalling.value;
      if (videoUiEnabled) {
        controller.prepareVideoCallScreen(callerId, incoming: true);
        Get.offNamed('/call/video');
      }
      Future<bool>? acceptFuture;
      if (hasDirectOffer && videoUiEnabled) {
        acceptFuture = controller.acceptCall(callData);
      }

      // Stop ringtone immediately so it doesn't keep ringing
      await ringtoneService.stopRingtone();

      // Cancel incoming call notification
      if (callId != null && callId.isNotEmpty) {
        NotificationService().cancelNotification(callId.hashCode);
      }

      // Dismiss the native CallKit/full-screen notification right away
      // Only on Android - iOS CallKit handles state transition automatically
      if (callId != null && callId.isNotEmpty && !Platform.isIOS) {
        await CallKitService().setCallConnected(callId);
      }

      // If we have a plaintext SDP offer or a complete encrypted offer
      // (socket was connected), accept directly without a resync round trip.
      if (hasDirectOffer) {
        acceptFuture ??= controller.acceptCall(callData);
        final success = await acceptFuture;
        if (!success && Get.currentRoute == '/call/video') {
          Get.back();
        } else if (success && Get.currentRoute != controller.activeCallRoute) {
          Get.offNamed(controller.activeCallRoute);
        }
      } else {
        // No SDP offer (socket was disconnected) - request resync from server
        debugPrint('📞 No SDP offer, requesting call resync for $callId');

        // Set pending auto-accept so resync response is auto-accepted
        await controller.setPendingAutoAccept(callId ?? '');

        // Request resync from server with retry
        final socketService = Get.find<SocketService>();
        _requestResyncWithRetry(socketService, callId ?? '');
      }
    } catch (e) {
      debugPrint('❌ Error accepting call: $e');
      setState(() {
        _isAccepting = false;
      });
      Get.back();
    }
  }

  Future<void> _declineCall(Map<String, dynamic>? callData) async {
    if (callData == null) return;

    final callId = callData['callId'] as String?;

    // Stop ringtone
    final ringtoneService = RingtoneService();
    await ringtoneService.stopRingtone();

    // Cancel incoming call notification
    if (callId != null && callId.isNotEmpty) {
      NotificationService().cancelNotification(callId.hashCode);
    }

    try {
      final controller = Get.find<CallController>();
      controller.rejectCall(callData);
      // The incoming call screen closes reactively when callState becomes idle/ended.
    } catch (e) {
      debugPrint('❌ Error declining call: $e');
      Get.back();
    }
  }

  Future<void> _requestResyncWithRetry(
    SocketService socketService,
    String callId,
  ) async {
    int retryCount = 0;
    const maxRetries = 30; // 15 seconds total (30 * 500ms)

    while (retryCount < maxRetries && _isAccepting) {
      if (socketService.isConnected.value) {
        debugPrint('📞 Socket connected, requesting resync for $callId');
        socketService.requestCallResync(callId: callId);
        return;
      }

      retryCount++;
      if (retryCount < maxRetries) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    // If we get here, socket didn't connect in time
    if (_isAccepting) {
      debugPrint('❌ Socket failed to connect within timeout');
      Get.snackbar(
        'Connection Error',
        'Please check your internet connection',
        snackPosition: SnackPosition.BOTTOM,
      );
      setState(() {
        _isAccepting = false;
      });
      Get.back();
    }
  }
}
