import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'call_controller.dart';
import '../../core/services/ringtone_service.dart';

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

  @override
  void initState() {
    super.initState();
    _setupAnimation();
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
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final callData = Get.arguments as Map<String, dynamic>?;
    final callerId = callData?['callerId'] as String? ?? '';
    final controller = Get.find<CallController>();
    if (callerId.isNotEmpty && controller.remoteDisplayName.value.isEmpty) {
      controller.resolveDisplayNamePublic(callerId);
    }

    return Scaffold(
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
                    Obx(() => Text(
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
                        )),
                    const SizedBox(height: 8),
                    // Call status
                    const Text(
                      'Incoming call...',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Decline button
                    _buildActionButton(
                      icon: Icons.call_end,
                      color: Colors.red,
                      label: 'Decline',
                      onTap: () => _declineCall(callData),
                    ),
                    // Accept button
                    _buildActionButton(
                      icon: Icons.call,
                      color: Colors.green,
                      label: 'Accept',
                      onTap: () => _acceptCall(callData),
                    ),
                  ],
                ),
              ),
            ),
          ],
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
            child: Icon(
              icon,
              size: 32,
              color: Colors.white,
            ),
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

  void _acceptCall(Map<String, dynamic>? callData) {
    if (callData == null) return;

    // Stop ringtone
    final ringtoneService = RingtoneService();
    ringtoneService.stopRingtone();

    try {
      final controller = Get.find<CallController>();
      controller.acceptCall(callData);

      // Navigate to active call screen
      Get.offNamed('/call/active');
    } catch (e) {
      debugPrint('❌ Error accepting call: $e');
      Get.back();
    }
  }

  void _declineCall(Map<String, dynamic>? callData) {
    if (callData == null) return;

    // Stop ringtone
    final ringtoneService = RingtoneService();
    ringtoneService.stopRingtone();

    try {
      final controller = Get.find<CallController>();
      controller.rejectCall(callData);

      // Go back to previous screen
      Get.back();
    } catch (e) {
      debugPrint('❌ Error declining call: $e');
      Get.back();
    }
  }
}
