import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pear_messaging/routes/app_routes.dart';

// Group plans have been removed. This redirects to the new Stripe subscription screen.
class GroupPlanSelectionScreen extends StatelessWidget {
  const GroupPlanSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Get.offNamed(AppRoutes.stripeSubscription);
    });
    return const Scaffold(body: SizedBox.shrink());
  }
}
