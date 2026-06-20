import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'call_controller.dart';

/// Outgoing Call Screen - Full-screen overlay for outgoing audio calls
class OutgoingCallScreen extends StatelessWidget {
  const OutgoingCallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<CallController>();

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top section - Callee info
            Expanded(
              flex: 2,
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
                    Obx(() => Text(
                          controller.remoteDisplayName.value.isNotEmpty
                              ? controller.remoteDisplayName.value
                              : '@user_...',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        )),
                    const SizedBox(height: 8),
                    // Call status
                    Obx(() => Text(
                          _getCallStatusText(controller.callState.value),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                          ),
                        )),
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
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // End call button
                    GestureDetector(
                      onTap: () => _endCall(controller),
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
                        child: const Icon(
                          Icons.call_end,
                          size: 32,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'End Call',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
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

  void _endCall(CallController controller) {
    controller.endCall();
    Get.back();
  }
}
