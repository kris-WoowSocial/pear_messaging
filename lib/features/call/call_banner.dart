import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'call_controller.dart';

/// Persistent call status banner shown at the top of the screen when the user
/// navigates away from the call screen. Mimics the WhatsApp-style minimized
/// call bar: contact name with a live duration counter, a "Click here for
/// full screen" hint that taps back to the call, and a hang-up button.
class CallBanner extends StatelessWidget {
  const CallBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // CallController may not be registered yet (e.g. before first call).
      if (!Get.isRegistered<CallController>()) {
        return const SizedBox.shrink();
      }

      final controller = Get.find<CallController>();

      if (!controller.isInCall || !controller.isCallMinimized.value) {
        return const SizedBox.shrink();
      }

      final duration = controller.callDuration.value;
      final name = controller.remoteDisplayName.value.isNotEmpty
          ? controller.remoteDisplayName.value
          : 'Unknown';

      return Material(
        color: const Color(0xFF1F1F1F),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                // Tapping the icon/name area returns to the full-screen call.
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: controller.restoreCallScreen,
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.grey[800],
                          ),
                          child: const Icon(
                            Icons.open_in_full,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '$name - $duration',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF4CD964),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const Text(
                                'Click here for full screen',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Hang up directly from the banner without opening the call.
                GestureDetector(
                  onTap: controller.endCall,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.red,
                    ),
                    child: const Icon(
                      Icons.call_end,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}
