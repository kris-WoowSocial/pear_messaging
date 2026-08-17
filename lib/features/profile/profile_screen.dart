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
      final canLaunch = await canLaunchUrl(url);
      debugPrint('🔍 Can launch URL: $canLaunch');

      if (canLaunch) {
        final launched = await launchUrl(
          url,
          mode: LaunchMode.externalApplication,
        );
        if (!launched) {
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

  /// Show the QR code in a bottom sheet instead of an always-visible black box
  void _showQrCodeSheet(BuildContext context) {
    Get.bottomSheet(
      SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            AppSizes.paddingL,
            AppSizes.paddingM,
            AppSizes.paddingL,
            AppSizes.paddingXL,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: AppSizes.paddingM),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Text(
                'My QR Code',
                style: TextStyle(
                  fontSize: AppSizes.fontXL,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppSizes.paddingL),
              Container(
                padding: const EdgeInsets.all(AppSizes.paddingM),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppSizes.radiusM),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: FutureBuilder<String>(
                  future: _generateQRData(),
                  builder: (context, snapshot) {
                    if (snapshot.hasData) {
                      return QrImageView(
                        data: snapshot.data!,
                        version: QrVersions.auto,
                        size: 220.0,
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                      );
                    }
                    return const SizedBox(
                      width: 220,
                      height: 220,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  },
                ),
              ),
              const SizedBox(height: AppSizes.paddingL),
              Text(
                'Your QR code is private. If you share it, others can scan it to add you as a contact.',
                style: TextStyle(
                  fontSize: AppSizes.fontM,
                  color: Colors.grey.shade600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSizes.paddingL),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Get.back();
                    Get.toNamed('/qr-scanner');
                  },
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan a Vant Chat QR Code'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: BorderSide(color: Colors.grey.shade300),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppSizes.radiusM),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      isScrollControlled: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          AppStrings.setting,
          style: TextStyle(color: AppColors.textPrimary),
        ),
        elevation: 0,
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
      ),
      body: SafeArea(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) {
            return Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, (1 - value) * 24),
                child: child,
              ),
            );
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSizes.paddingM,
              0,
              AppSizes.paddingM,
              AppSizes.paddingXL,
            ),
            children: [
              _buildProfileHero(context),
              const SizedBox(height: AppSizes.paddingL),
              _buildQuickActionsRow(context),
              const SizedBox(height: AppSizes.paddingL),
              _buildMembershipCard(context),
              const SizedBox(height: AppSizes.paddingM),
              _buildSectionCard(
                title: 'Security',
                children: [
                  Obx(
                    () => _buildSwitchTile(
                      icon: Icons.fingerprint,
                      iconColor: AppColors.primaryDark,
                      title: 'App Lock',
                      subtitle: 'Require authentication to open app',
                      value: controller.isAuthEnabled.value,
                      onChanged: controller.toggleAuth,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSizes.paddingM),
              _buildSectionCard(
                title: 'Account',
                children: [
                  Obx(() {
                    final influencer = controller.linkedInfluencer.value;
                    final isLinked =
                        influencer != null && influencer['status'] == 'active';
                    return _buildActionTile(
                      icon: isLinked ? Icons.check_circle : Icons.link,
                      iconColor: isLinked ? AppColors.success : AppColors.info,
                      title: isLinked
                          ? 'Linked: ${influencer['name']}'
                          : 'Link Influencer Account',
                      subtitle: isLinked
                          ? 'Code: ${influencer['referralCode']}'
                          : 'Enter token from influencer dashboard',
                      trailing: isLinked
                          ? const Icon(Icons.check,
                              size: 18, color: AppColors.success)
                          : const Icon(Icons.arrow_forward_ios,
                              size: 14, color: AppColors.textSecondary),
                      onTap: isLinked
                          ? null
                          : () => _showLinkInfluencerDialog(context),
                    );
                  }),
                  _divider(),
                  _buildActionTile(
                    icon: Icons.delete_sweep_outlined,
                    iconColor: AppColors.warning,
                    title: 'Clear Chat History',
                    subtitle: 'Delete all conversations from this device',
                    trailing: const Icon(Icons.arrow_forward_ios,
                        size: 14, color: AppColors.textSecondary),
                    onTap: controller.clearChatHistory,
                  ),
                ],
              ),
              const SizedBox(height: AppSizes.paddingM),
              _buildSectionCard(
                title: 'Legal & Support',
                children: [
                  _buildActionTile(
                    icon: Icons.description_outlined,
                    iconColor: AppColors.textPrimary,
                    title: 'Terms & Privacy Policy',
                    trailing: const Icon(Icons.open_in_new,
                        size: 16, color: AppColors.textSecondary),
                    onTap: _openTermsOfService,
                  ),
                  _divider(),
                  _buildActionTile(
                    icon: Icons.email_outlined,
                    iconColor: AppColors.textPrimary,
                    title: 'Contact Us',
                    subtitle: 'Send us a message',
                    trailing: const Icon(Icons.arrow_forward_ios,
                        size: 14, color: AppColors.textSecondary),
                    onTap: () => Get.to(() => const ContactUsScreen()),
                  ),
                  _divider(),
                  _buildActionTile(
                    icon: Icons.star_rate_rounded,
                    iconColor: AppColors.warning,
                    title: 'Rate Us',
                    subtitle: 'Share your feedback',
                    trailing: const Icon(Icons.arrow_forward_ios,
                        size: 14, color: AppColors.textSecondary),
                    onTap: () {
                      final reviewService = Get.find<ReviewService>();
                      reviewService.requestReview();
                    },
                  ),
                ],
              ),
              const SizedBox(height: AppSizes.paddingL),
           
            ],
          ),
        ),
      ),
    );
  }

  /// Hero profile header: avatar, name (tap to edit), device ID chip
  Widget _buildProfileHero(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSizes.paddingL),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primaryDark, AppColors.primary],
        ),
        borderRadius: BorderRadius.circular(AppSizes.radiusXL),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
            ),
            child: Center(
              child: Obx(
                () => Text(
                  controller.userInitial,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryDark,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSizes.paddingM),
          Obx(
            () => AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SizeTransition(
                  sizeFactor: animation,
                  axis: Axis.horizontal,
                  child: child,
                ),
              ),
              child: controller.isEditingName.value
                  ? _buildNameEditor()
                  : GestureDetector(
                      key: const ValueKey('name_display'),
                      onTap: controller.startEditingName,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              controller.userName.value,
                              style: const TextStyle(
                                fontSize: AppSizes.fontXXL,
                                fontWeight: FontWeight.bold,
                              color: Colors.black,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                        const Icon(Icons.edit, size: 16, color: Colors.black54),
                        ],
                      ),
                    ),
            ),
          ),
          const SizedBox(height: AppSizes.paddingS),
          GestureDetector(
            onTap: () => _showQrCodeSheet(context),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSizes.paddingM,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(AppSizes.radiusCircular),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.qr_code_2, size: 16, color: Colors.black),
                  SizedBox(width: 6),
                  Text(
                    'Show my QR code',
                    style: TextStyle(
                      fontSize: AppSizes.fontS,
                      color: Colors.black,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNameEditor() {
    return Row(
      key: const ValueKey('name_editor'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 160,
          child: TextField(
            controller: controller.nameController.value,
            autofocus: true,
            textAlign: TextAlign.center,
            style:
                const TextStyle(color: Colors.white, fontSize: AppSizes.fontL),
            onSubmitted: (_) => controller.saveUserName(),
            decoration: InputDecoration(
              hintText: 'Enter your name',
              hintStyle: const TextStyle(color: Colors.white70),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSizes.paddingS,
                vertical: AppSizes.paddingS,
              ),
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.white70),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.white),
              ),
            ),
          ),
        ),
        IconButton(
          onPressed: controller.cancelEditingName,
          icon: const Icon(Icons.close, color: Colors.white70),
          iconSize: 20,
        ),
        IconButton(
          onPressed: controller.saveUserName,
          icon: const Icon(Icons.check, color: Colors.white),
          iconSize: 20,
        ),
      ],
    );
  }

  /// Row of quick-glance shortcut cards (Scan QR, Share app)
  Widget _buildQuickActionsRow(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _buildQuickActionCard(
            icon: Icons.qr_code_scanner,
            label: 'Scan Code',
            color: AppColors.info,
            onTap: () => Get.toNamed('/qr-scanner'),
          ),
        ),
        const SizedBox(width: AppSizes.paddingM),
        Expanded(
          child: _buildQuickActionCard(
            icon: Icons.ios_share_rounded,
            label: 'Share App',
            color: AppColors.primaryDark,
            onTap: controller.shareApp,
          ),
        ),
      ],
    );
  }

  Widget _buildQuickActionCard({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppSizes.radiusL),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppSizes.radiusL),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppSizes.radiusL),
          splashColor: color.withValues(alpha: 0.12),
          highlightColor: color.withValues(alpha: 0.06),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: AppSizes.paddingM),
            child: Column(
              children: [
                Icon(icon, color: color, size: AppSizes.iconM),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: AppSizes.fontS,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMembershipCard(BuildContext context) {
    return Obx(() {
      final membershipService = Get.find<MembershipService>();
      final isPremium = membershipService.isPremium;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppSizes.radiusL),
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
              borderRadius: BorderRadius.circular(AppSizes.radiusL),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isPremium
                        ? AppColors.primary.withValues(alpha: 0.2)
                        : Colors.white.withValues(alpha: 0.1),
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
                          color: isPremium ? AppColors.primary : Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        membershipService.statusDescription,
                        style: TextStyle(
                          fontSize: AppSizes.fontS,
                          color: Colors.white.withValues(alpha: 0.65),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios,
                  size: 14,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  /// Generic rounded card wrapping a titled group of settings rows
  Widget _buildSectionCard({
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSizes.paddingM,
        vertical: AppSizes.paddingS,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppSizes.radiusL),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSizes.paddingS),
            child: Text(
              title,
              style: TextStyle(
                fontSize: AppSizes.fontS,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _divider() => Divider(
        height: 1,
        thickness: 1,
        color: Colors.grey.shade100,
      );

  /// Consistent row style: icon chip + title/subtitle + trailing widget
  Widget _buildActionTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSizes.radiusS),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSizes.paddingS),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppSizes.radiusS),
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: AppSizes.paddingM),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: AppSizes.fontM,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: AppSizes.fontS,
                          color: Colors.grey.shade500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AppSizes.paddingS),
                trailing,
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Consistent row style for a toggle switch setting
  Widget _buildSwitchTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSizes.paddingS),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppSizes.radiusS),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: AppSizes.paddingM),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: AppSizes.fontM,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: AppSizes.fontS,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: AppColors.primary,
          ),
        ],
      ),
    );
  }
}
