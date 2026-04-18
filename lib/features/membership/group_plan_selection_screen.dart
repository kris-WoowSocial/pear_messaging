import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'membership_screen.dart';

// Group plans have been removed. This redirects to the main membership screen.
class GroupPlanSelectionScreen extends StatelessWidget {
  const GroupPlanSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Get.offNamed('/membership');
    });
    return const MembershipScreen();
  }
}
