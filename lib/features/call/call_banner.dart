import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'call_controller.dart';
import '../../routes/app_routes.dart';

/// Persistent call status banner shown at the top of the screen when the user
/// navigates away from the active call screen. Mimics the iOS/WhatsApp-style
/// green bar with a live call duration counter that taps back to the call.
class CallBanner extends StatelessWidget {
  const CallBanner({super.key});

  static const _callRoutes = {
    AppRoutes.callActive,
    AppRoutes.callIncoming,
    AppRoutes.callOutgoing,
  };

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // CallController may not be registered yet (e.g. before first call).
      if (!Get.isRegistered<CallController>()) {
        return const SizedBox.shrink();
      }

      final controller = Get.find<CallController>();

      // Only show when in an active call AND not currently on a call screen.
      // callDuration is read here so Obx rebuilds every second, which also
      // re-evaluates the route check — giving near-instant show/hide.
      if (!controller.isInCall) return const SizedBox.shrink();

      final currentRoute = Get.currentRoute;
      if (_callRoutes.contains(currentRoute)) {
        return const SizedBox.shrink();
      }

      final duration = controller.callDuration.value;

      return GestureDetector(
        onTap: () => Get.toNamed(AppRoutes.callActive),
        child: Container(
          width: double.infinity,
          color: const Color(0xFF4CD964), // iOS-style call green
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.phone_in_talk,
                    color: Colors.white,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Tap to return to call  $duration',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}
