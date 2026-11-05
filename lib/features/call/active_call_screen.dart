import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'call_controller.dart';
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
        body: Obx(() {
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
    return Obx(() {
      final avatarUrl = controller.remoteAvatarUrl.value.trim();
      final hasAvatar = avatarUrl.isNotEmpty;
      return Container(
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
          child: hasAvatar
              ? CachedNetworkImage(
                  imageUrl: avatarUrl,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  errorWidget: (context, url, error) => const Icon(
                    Icons.person,
                    size: 58,
                    color: Colors.white,
                  ),
                )
              : const Icon(
                  Icons.person,
                  size: 58,
                  color: Colors.white,
                ),
        ),
      );
    });
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
