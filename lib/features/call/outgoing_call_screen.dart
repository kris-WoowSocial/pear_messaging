import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'call_controller.dart';
import 'call_encryption_indicator.dart';

/// Outgoing Call Screen - Full-screen overlay for outgoing audio calls
class OutgoingCallScreen extends StatefulWidget {
  const OutgoingCallScreen({super.key});

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> {
  Worker? _callStateWorker;

  CallController get _controller => Get.find<CallController>();

  @override
  void initState() {
    super.initState();
    _callStateWorker = ever(_controller.callState, _onCallStateChanged);
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
    Navigator.of(context).popUntil((route) => route.settings.name != routeName);
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
        body: SafeArea(
          child: Column(
            children: [
              // Top section - Callee info
              Expanded(
                flex: 1,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Avatar
                      Container(
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
                      const SizedBox(height: 32),
                      // Callee name
                      Obx(
                        () => Text(
                          controller.remoteDisplayLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Call status
                      Obx(
                        () => Text(
                          _getCallStatusText(controller.callState.value),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                          ),
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
                    horizontal: 32,
                    vertical: 24,
                  ),
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
                              label:
                                  controller.isMuted.value ? 'Unmute' : 'Mute',
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
        ),
      ),
    );
  }

  String _getCallStatusText(CallState state) {
    switch (state) {
      case CallState.dialing:
        return 'Dialing...';
      case CallState.ringing:
        return 'Ringing...';
      case CallState.connected:
        return 'Connected';
      default:
        return 'Calling...';
    }
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
