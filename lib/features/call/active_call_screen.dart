import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'call_controller.dart';
import '../../widgets/vant_avatar.dart';
import 'call_encryption_indicator.dart';

/// Active Call Screen - Full-screen overlay for connected audio calls
class ActiveCallScreen extends StatefulWidget {
  const ActiveCallScreen({super.key});

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen> {
  Worker? _callStateWorker;

  CallController get _controller => Get.find<CallController>();

  @override
  void initState() {
    super.initState();
    _callStateWorker = ever(_controller.callState, _onCallStateChanged);
  }

  void _onCallStateChanged(CallState state) {
    if (state == CallState.ended || state == CallState.idle) {
      // The caller no-answer screen intentionally stays up after end —
      // this screen can render it when a video call fell back to audio UI.
      if (_controller.noAnswerUi.value != null) return;
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

  @override
  void dispose() {
    _callStateWorker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<CallController>();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        // Intercept the Android back button and minimize the call instead of
        // leaving the app — the call keeps running behind the CallBanner.
        if (didPop) return;
        controller.minimizeCallScreen(context);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Obx(() {
              // Dim screen when near ear (proximity sensor)
              final isDimmed =
                  controller.isNearEar.value && !controller.isSpeakerOn.value;

              return AnimatedOpacity(
                opacity: isDimmed ? 0.1 : 1.0,
                duration: const Duration(milliseconds: 300),
                child: IgnorePointer(
                  ignoring: isDimmed,
                  child: _buildCallUI(controller, context),
                ),
              );
            }),
            // Incoming video-upgrade consent prompt — lives outside the
            // proximity-dimmed layer so it stays interactive near the ear.
            Obx(
              () => controller.hasIncomingVideoUpgradeRequest.value
                  ? _buildVideoUpgradePrompt(controller)
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallUI(CallController controller, BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          // Top section - Contact info and E2EE indicator
          Expanded(
            flex: 1,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Avatar
                  _buildAvatar(controller),
                  const SizedBox(height: 16),
                  // Contact name
                  Obx(
                    () => Text(
                      controller.remoteDisplayLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 25,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // E2EE indicator
                  Obx(
                    () => CallEncryptionIndicator(
                      state: controller.callEncryptionState.value,
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Call duration
                  Obx(
                    () => Text(
                      controller.callTimerLabel,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 24,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Bottom section - Control buttons
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Minimize button - keeps the call running behind the
                  // CallBanner so the user can continue using the app
                  _buildControlButton(
                    icon: Icons.close_fullscreen,
                    label: 'Minimize',
                    isActive: false,
                    onTap: () => controller.minimizeCallScreen(context),
                  ),
                  const SizedBox(height: 24),
                  // "Requesting video call…" pill while a consent request
                  // is in flight — tap Cancel to withdraw it.
                  Obx(
                    () => controller.isVideoUpgradePending.value
                        ? Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.grey[850],
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.15),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white70,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  const Text(
                                    'Requesting video call…',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  GestureDetector(
                                    onTap: () {
                                      HapticFeedback.lightImpact();
                                      controller.cancelVideoUpgradeRequest();
                                    },
                                    child: const Text(
                                      'Cancel',
                                      style: TextStyle(
                                        color: Color(0xFF25D366),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  // Second row: Mute and Speaker (Obx for reactive updates)
                  Obx(
                    () => Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildControlButton(
                          icon: controller.isMuted.value
                              ? Icons.mic_off
                              : Icons.mic,
                          label: controller.isMuted.value ? 'Unmute' : 'Mute',
                          isActive: controller.isMuted.value,
                          onTap: controller.toggleMute,
                        ),
                        _buildControlButton(
                          icon: Icons.volume_up,
                          label: 'Speaker',
                          isActive: controller.isSpeakerOn.value,
                          onTap: () => controller.toggleSpeaker(),
                        ),
                        if (controller.canUpgradeToVideo)
                          _buildControlButton(
                            icon: Icons.videocam,
                            label: 'Video',
                            isActive: false,
                            // Consent handshake — camera only turns on
                            // after the peer accepts.
                            onTap: controller.isVideoUpgradePending.value
                                ? () {}
                                : controller.requestVideoUpgrade,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Third row: End call
                  _buildEndCallButton(controller),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(CallController controller) {
    return Obx(
      () => Container(
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
        child: ClipOval(
          child: VantAvatar(
            userId: controller.remoteDeviceId.value.isNotEmpty
                ? controller.remoteDeviceId.value
                : null,
            name: controller.remoteDisplayName.value,
            avatarUrl: controller.remoteAvatarUrl.value.trim(),
            size: 120,
            borderRadius: 60,
          ),
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return Column(
      children: [
        GestureDetector(
          onTap: () {
            // Haptic feedback
            HapticFeedback.lightImpact();
            onTap();
          },
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive ? Colors.white : Colors.grey[800],
              border: Border.all(
                color: isActive ? Colors.white : Colors.white.withOpacity(0.3),
                width: 2,
              ),
            ),
            child: Icon(
              icon,
              size: 28,
              color: isActive ? Colors.black : Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            color: isActive ? Colors.white : Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  /// WhatsApp-style consent card shown when the peer asks to switch the
  /// audio call to video — Decline keeps the voice call untouched.
  Widget _buildVideoUpgradePrompt(CallController controller) {
    return Container(
      color: Colors.black.withOpacity(0.55),
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          decoration: BoxDecoration(
            color: const Color(0xFF1F2C34),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF25D366).withOpacity(0.15),
                ),
                child: const Icon(
                  Icons.videocam,
                  color: Color(0xFF25D366),
                  size: 26,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Switch to video call?',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${controller.remoteDisplayLabel} wants to switch to a video call',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        controller.respondToVideoUpgrade(false);
                      },
                      child: Container(
                        height: 46,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(23),
                          border: Border.all(color: Colors.white38),
                        ),
                        child: const Center(
                          child: Text(
                            'Decline',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        controller.respondToVideoUpgrade(true);
                      },
                      child: Container(
                        height: 46,
                        decoration: BoxDecoration(
                          color: const Color(0xFF25D366),
                          borderRadius: BorderRadius.circular(23),
                        ),
                        child: const Center(
                          child: Text(
                            'Switch',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEndCallButton(CallController controller) {
    return GestureDetector(
      onTap: () {
        // Haptic feedback
        HapticFeedback.heavyImpact();
        controller.endCall();
      },
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.red,
          boxShadow: [
            BoxShadow(
              color: Colors.red.withOpacity(0.4),
              blurRadius: 12,
              spreadRadius: 4,
            ),
          ],
        ),
        child: const Icon(Icons.call_end, size: 32, color: Colors.white),
      ),
    );
  }
}
