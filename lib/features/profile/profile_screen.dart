import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_strings.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/constants/network_constants.dart';
import '../../core/services/review_service.dart';
import '../../core/services/membership_service.dart';
import '../../routes/app_routes.dart';
import 'profile_controller.dart';
import '../contact/contact_us_screen.dart';

class ProfileScreen extends GetView<ProfileController> {
  const ProfileScreen({super.key});

  Future<String> _generateQRData() async {
    final deviceId = controller.deviceId.value;
    return '${NetworkConstants.chatShareUrl}?device_id=$deviceId';
  }

  /// Show dialog to enter influencer link token
  void _showLinkInfluencerDialog(BuildContext context) {
    final tokenController = TextEditingController();
    Get.defaultDialog(
      title: 'Link Influencer Account',
      content: TextField(
        controller: tokenController,
        decoration: const InputDecoration(
          hintText: 'Paste your token',
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
      ),
      textConfirm: 'Link',
      textCancel: 'Cancel',
      onConfirm: () {
        final token = tokenController.text.trim();
        controller.linkInfluencerAccount(token);
      },
    );
  }

  /// Open Terms of Service in external browser
  void _openTermsOfService() async {
    final Uri url = Uri.parse(NetworkConstants.privacyPolicyUrl);
    try {
      debugPrint('🌐 Attempting to launch URL: $url');

      // Check if URL can be launched
      final canLaunch = await canLaunchUrl(url);
      debugPrint('🔍 Can launch URL: $canLaunch');

      if (canLaunch) {
        // Try external application mode first
        final launched = await launchUrl(
          url,
          mode: LaunchMode.externalApplication,
        );

        if (!launched) {
          // Fallback to platform default
          debugPrint('🔄 External launch failed, trying platform default...');
          await launchUrl(url, mode: LaunchMode.platformDefault);
        }
      } else {
        debugPrint('❌ Cannot launch URL: $url');
        Get.snackbar(
          'Error',
          'Could not open Terms of Service. No browser available.',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.shade100,
          colorText: Colors.red.shade800,
        );
      }
    } catch (e) {
      debugPrint('❌ Error launching Terms of Service: $e');
      Get.snackbar(
        'Error',
        'Could not open Terms of Service',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text(AppStrings.setting)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSizes.paddingM),
          children: [
            // Profile header
            Container(
              height: 80,
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSizes.paddingS),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppSizes.radiusL),
              ),
              child: Row(
                children: [
                  // Circular avatar container
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Obx(
                        () => Text(
                          controller.userInitial,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSizes.paddingS),

                  // User name field
                  Expanded(
                    child: Obx(
                      () => controller.isEditingName.value
                          ? TextField(
                              controller: controller.nameController.value,
                              autofocus: true,
                              onSubmitted: (_) => controller.saveUserName(),
                              decoration: InputDecoration(
                                hintText: 'Enter your name',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(
                                    AppSizes.radiusS,
                                  ),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: AppSizes.paddingM,
                                  vertical: AppSizes.paddingS,
                                ),
                              ),
                            )
                          : GestureDetector(
                              onTap: controller.startEditingName,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSizes.paddingM,
                                  vertical: AppSizes.paddingS,
                                ),
                                decoration: BoxDecoration(
                                  border:
                                      Border.all(color: Colors.grey.shade300),
                                  borderRadius: BorderRadius.circular(
                                    AppSizes.radiusS,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        controller.userName.value,
                                        style: const TextStyle(
                                          fontSize: AppSizes.fontM,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    const Icon(
                                      Icons.edit,
                                      size: 16,
                                      color: Colors.grey,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                    ),
                  ),

                  // Save/Cancel buttons when editing
                  Obx(
                    () => controller.isEditingName.value
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: controller.cancelEditingName,
                                icon:
                                    const Icon(Icons.close, color: Colors.red),
                                iconSize: 20,
                              ),
                              IconButton(
                                onPressed: controller.saveUserName,
                                icon: const Icon(Icons.check,
                                    color: Colors.green),
                                iconSize: 20,
                              ),
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSizes.paddingL),

            // QR Code section
            Container(
              padding: const EdgeInsets.all(AppSizes.paddingL),
              decoration: BoxDecoration(
                // gradient: const LinearGradient(
                //   begin: Alignment.topLeft,
                //   end: Alignment.bottomRight,
                //   colors: [
                //     Color(0xFF667eea),
                //     Color(0xFF764ba2),
                //     Color(0xFFf093fb),
                //     Color(0xFFf5576c),
                //   ],
                //   stops: [0.0, 0.3, 0.7, 1.0],
                // ),
                color: Colors.black,
                borderRadius: BorderRadius.circular(AppSizes.radiusL),
              ),
              child: Column(
                children: [
                  const Text(
                    'My QR Code',
                    style: TextStyle(
                      fontSize: AppSizes.fontL,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: AppSizes.paddingM),
                  Container(
                    padding: const EdgeInsets.all(AppSizes.paddingM),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppSizes.radiusM),
                    ),
                    child: FutureBuilder<String>(
                      future: _generateQRData(),
                      builder: (context, snapshot) {
                        if (snapshot.hasData) {
                          return QrImageView(
                            data: snapshot.data!,
                            version: QrVersions.auto,
                            size: 200.0,
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                          );
                        }
                        return const SizedBox(
                          width: 200,
                          height: 200,
                          child: Center(child: CircularProgressIndicator()),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: AppSizes.paddingM),
                  const Text(
                    'Your QR code is private. If you share it with someone, they can scan it with their Vant Chat camera to add you as a contact.',
                    style: TextStyle(
                      fontSize: AppSizes.fontM,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),

            const SizedBox(height: AppSizes.paddingM),

            // Scan Code button
            ElevatedButton.icon(
              onPressed: () => Get.toNamed('/qr-scanner'),
              icon: const Icon(Icons.qr_code_scanner, color: Colors.black),
              label: const Text(
                'Scan a Vant Chat QR Code',
                style: TextStyle(color: Colors.black),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                minimumSize: const Size.fromHeight(AppSizes.buttonHeight),
              ),
            ),
            const SizedBox(height: AppSizes.paddingM),

            // App version section
            // Container(
            //   padding: const EdgeInsets.all(AppSizes.paddingM),
            //   decoration: BoxDecoration(
            //     color: AppColors.surface,
            //     borderRadius: BorderRadius.circular(AppSizes.radiusM),
            //   ),
            //   child: Column(
            //     crossAxisAlignment: CrossAxisAlignment.start,
            //     children: const [
            //       Text(
            //         'App Version',
            //         style: TextStyle(
            //           fontSize: AppSizes.fontS,
            //           color: AppColors.textSecondary,
            //         ),
            //       ),
            //       SizedBox(height: AppSizes.paddingS),
            //       Text(
            //         AppStrings.appVersion,
            //         style: TextStyle(
            //           fontSize: AppSizes.fontL,
            //           fontWeight: FontWeight.w600,
            //         ),
            //       ),
            //     ],
            //   ),
            // ),
            // const SizedBox(height: AppSizes.paddingXL),

            // Security section
            Container(
              padding: const EdgeInsets.all(AppSizes.paddingM),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppSizes.radiusM),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Security',
                    style: TextStyle(
                      fontSize: AppSizes.fontM,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: AppSizes.paddingM),
                  Obx(
                    () => SwitchListTile(
                      title: const Text('App Lock'),
                      subtitle:
                          const Text('Require authentication to open app'),
                      value: controller.isAuthEnabled.value,
                      onChanged: controller.toggleAuth,
                      secondary: const Icon(Icons.fingerprint),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: AppSizes.paddingM),

            // Influencer section
            Container(
              padding: const EdgeInsets.all(AppSizes.paddingM),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppSizes.radiusM),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Influencer',
                    style: TextStyle(
                      fontSize: AppSizes.fontM,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: AppSizes.paddingM),
                  Obx(() {
                    final influencer = controller.linkedInfluencer.value;
                    if (influencer != null && influencer['status'] == 'active') {
                      return ListTile(
                        leading: const Icon(Icons.check_circle, color: Colors.green),
                        title: Text('Linked: ${influencer['name']}'),
                        subtitle: Text('Code: ${influencer['referralCode']}'),
                        trailing: const Icon(Icons.check, color: Colors.green),
                        contentPadding: EdgeInsets.zero,
                      );
                    }
                    return ListTile(
                      leading: const Icon(Icons.link, color: AppColors.textPrimary),
                      title: const Text('Link Influencer Account'),
                      subtitle: const Text('Enter token from influencer dashboard'),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: AppColors.textSecondary),
                      onTap: () => _showLinkInfluencerDialog(context),
                      contentPadding: EdgeInsets.zero,
                    );
                  }),
                ],
              ),
            ),

            const SizedBox(height: AppSizes.paddingM),

            // Membership section
            Obx(() {
              final membershipService = Get.find<MembershipService>();
              final isPremium = membershipService.isPremium;
              return GestureDetector(
                onTap: () => Get.toNamed(AppRoutes.stripeSubscription),
                child: Container(
                  padding: const EdgeInsets.all(AppSizes.paddingM),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: isPremium
                          ? [const Color(0xFF1A1A2E), const Color(0xFF16213E)]
                          : [Colors.black87, Colors.black54],
                    ),
                    borderRadius: BorderRadius.circular(AppSizes.radiusM),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isPremium
                              ? AppColors.primary.withOpacity(0.2)
                              : Colors.white.withOpacity(0.1),
                        ),
                        child: Icon(
                          isPremium ? Icons.auto_awesome : Icons.lock_open,
                          color: isPremium ? AppColors.primary : Colors.white70,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: AppSizes.paddingM),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              membershipService.statusLabel,
                              style: TextStyle(
                                fontSize: AppSizes.fontM,
                                fontWeight: FontWeight.w700,
                                color: isPremium
                                    ? AppColors.primary
                                    : Colors.white,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              membershipService.statusDescription,
                              style: TextStyle(
                                fontSize: AppSizes.fontS,
                                color: Colors.white.withOpacity(0.65),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios,
                        size: 14,
                        color: Colors.white.withOpacity(0.5),
                      ),
                    ],
                  ),
                ),
              );
            }),

            const SizedBox(height: AppSizes.paddingM),

            // Legal & Support section
            Container(
              padding: const EdgeInsets.all(AppSizes.paddingM),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppSizes.radiusM),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Legal & Support',
                    style: TextStyle(
                      fontSize: AppSizes.fontM,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: AppSizes.paddingM),

                  // Terms & Privacy Policy
                  ListTile(
                    leading: const Icon(
                      Icons.description_outlined,
                      color: AppColors.textPrimary,
                    ),
                    title: const Text('Terms & Privacy Policy'),
                    trailing: const Icon(
                      Icons.open_in_new,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                    onTap: _openTermsOfService,
                    contentPadding: EdgeInsets.zero,
                  ),

                  const Divider(height: 1),

                  // Contact Us
                  ListTile(
                    leading: const Icon(
                      Icons.email_outlined,
                      color: AppColors.textPrimary,
                    ),
                    title: const Text('Contact Us'),
                    subtitle: const Text('Send us a message'),
                    trailing: const Icon(
                      Icons.arrow_forward_ios,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                    onTap: () => Get.to(() => const ContactUsScreen()),
                    contentPadding: EdgeInsets.zero,
                  ),

                  const Divider(height: 1),

                  // Rate Us
                  ListTile(
                    leading: const Icon(
                      Icons.star_rate,
                      color: AppColors.textPrimary,
                    ),
                    title: const Text('Rate Us'),
                    subtitle: const Text('Share your feedback'),
                    trailing: const Icon(
                      Icons.arrow_forward_ios,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                    onTap: () {
                      final reviewService = Get.find<ReviewService>();
                      reviewService.requestReview();
                    },
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSizes.paddingXL),
          ],
        ),
      ),
    );
  }
}
