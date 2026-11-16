import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/constants/network_constants.dart';
import '../../core/services/review_service.dart';
import '../../core/services/membership_service.dart';
import '../../core/utils/string_utils.dart';
import '../../routes/app_routes.dart';
import 'profile_controller.dart';
import '../contact/contact_us_screen.dart';
import '../../widgets/vant_avatar.dart';
import '../../core/services/user_profile_cache.dart';
import '../../core/services/profile_avatar_service.dart';

class ProfileScreen extends GetView<ProfileController> {
  const ProfileScreen({super.key});

  Future<String> _generateQRData() async {
    final deviceId = controller.deviceId.value;
    // Branch quick-link: vantchatting.app.link resolves to the app when
    // installed (deep-link data includes device_id) and falls back to the
    // app store when it is not. The in-app scanner reads the device_id
    // query param directly, so Vant users still go straight to chat.
    // user_name rides the link the same way it does on share links — Branch
    // delivers link params on open AND deferred after an install, so the
    // inviter's real name reaches the first-launch invite path.
    final userName = Uri.encodeComponent(
      controller.userName.value.isNotEmpty
          ? controller.userName.value
          : StringUtils.generateFriendlyName(deviceId),
    );
    final playStore = Uri.encodeComponent(
      '${NetworkConstants.playStoreUrl}?id=com.vant.chat',
    );
    final appStore = Uri.encodeComponent(
      '${NetworkConstants.appStoreReviewUrl}6758916131',
    );
    // Inviter avatar rides the link for both the in-app scanner and the
    // OpenGraph preview ($og_image_url) shown by iMessage/WhatsApp/Telegram.
    final cachedAvatar = Get.isRegistered<UserProfileCache>()
        ? Get.find<UserProfileCache>().myAvatarUrl.value
        : '';
    // WhatsApp/iMessage crawlers need a public https URL.
    final avatarUrl =
        cachedAvatar.startsWith('https://') ? cachedAvatar : '';
    final avatarParam = avatarUrl.isNotEmpty
        ? '&avatar_url=${Uri.encodeComponent(avatarUrl)}'
            '&\$og_image_url=${Uri.encodeComponent(avatarUrl)}'
        : '';
    return 'https://vantchatting.app.link/?device_id=$deviceId'
        '&user_name=$userName$avatarParam'
        '&\$android_url=$playStore'
        '&\$ios_url=$appStore'
        '&\$fallback_url=$playStore';
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
          snackPosition: SnackPosition.TOP,
          backgroundColor: Colors.red.shade100,
          colorText: Colors.red.shade800,
        );
      }
    } catch (e) {
      debugPrint('❌ Error launching Terms of Service: $e');
      Get.snackbar(
        'Error',
        'Could not open Terms of Service',
        snackPosition: SnackPosition.TOP,
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
              // Own avatar above the QR card so the scanner sees a face too.
              Obx(
                () => VantAvatar(
                  userId: controller.deviceId.value,
                  name: controller.userName.value,
                  size: 64,
                  borderRadius: 32,
                ),
              ),
              const SizedBox(height: AppSizes.paddingM),
              Container(
                // Obx so a new/changed avatar regenerates the QR payload —
                // _generateQRData() reads myAvatarUrl, making it a reactive
                // dependency, so the scanned link always carries the live URL.
                child: Obx(() => FutureBuilder<String>(
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
                )),
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
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final collapsedHeight = kToolbarHeight + statusBarHeight;
    final expandedHeight = statusBarHeight + 150;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _ProfileHeaderDelegate(
              expandedHeight: expandedHeight,
              collapsedHeight: collapsedHeight,
              statusBarHeight: statusBarHeight,
              controller: controller,
              onQrTap: () => _showQrCodeSheet(context),
              onEditName: () => _showEditNameSheet(context),
            ),
          ),
          SliverToBoxAdapter(
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
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSizes.paddingM,
                  AppSizes.paddingL,
                  AppSizes.paddingM,
                  AppSizes.paddingXL,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
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
                    // _buildSectionCard(
                    //   title: 'Calls',
                    //   children: [
                    //     Obx(
                    //       () => _buildSwitchTile(
                    //         icon: Icons.vpn_key_outlined,
                    //         iconColor: AppColors.primaryDark,
                    //         title: 'Protect IP address in calls',
                    //         subtitle:
                    //             'To make it harder for people to infer your location, calls will be relayed through Vant servers. This will reduce call quality.',
                    //         value: controller.protectCallIpAddress.value,
                    //         onChanged: controller.toggleProtectCallIp,
                    //       ),
                    //     ),
                    //   ],
                    // ),
                    // const SizedBox(height: AppSizes.paddingM),
                    _buildSectionCard(
                      title: 'Account',
                      children: [
                        Obx(() {
                          final influencer = controller.linkedInfluencer.value;
                          final isLinked = influencer != null &&
                              influencer['status'] == 'active';
                          return _buildActionTile(
                            icon: isLinked ? Icons.check_circle : Icons.link,
                            iconColor:
                                isLinked ? AppColors.success : AppColors.info,
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
                                        const SizedBox(height: AppSizes.paddingXL),

                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One-tap name editor: a focused bottom sheet is far more reliable than
  /// the old inline header field, which lost focus to the collapsing-header
  /// rebuilds and couldn't open at all once the page was scrolled.
  void _showEditNameSheet(BuildContext context) {
    controller.startEditingName();
    Get.bottomSheet(
      Padding(
        padding: EdgeInsets.only(
          left: AppSizes.paddingL,
          right: AppSizes.paddingL,
          top: AppSizes.paddingL,
          bottom: MediaQuery.of(context).viewInsets.bottom +
              AppSizes.paddingL,
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Your name',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppSizes.fontL,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: AppSizes.paddingM),
              TextField(
                controller: controller.nameController.value,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                maxLength: 25,
                style: const TextStyle(
                  fontSize: AppSizes.fontL,
                  color: AppColors.textPrimary,
                ),
                decoration: const InputDecoration(
                  hintText: 'Enter your name',
                  counterText: '',
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.textPrimary),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(
                        color: AppColors.primaryDark, width: 2),
                  ),
                ),
                onSubmitted: (_) => _saveNameFromSheet(),
              ),
              const SizedBox(height: AppSizes.paddingM),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.surface,
                        foregroundColor: AppColors.textPrimary,
                      ),
                      onPressed: () => Get.back(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: AppSizes.paddingM),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _saveNameFromSheet,
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppSizes.radiusL),
        ),
      ),
    );
  }

  Future<void> _saveNameFromSheet() async {
        if (Get.isBottomSheetOpen ?? false) Get.back();
    await controller.saveUserName();
    if (Get.isBottomSheetOpen ?? false) Get.back();
  }

  /// Row of quick-glance shortcut cards (Scan QR, Share app)
  Widget _buildQuickActionsRow(BuildContext context) {
    return Row(
      children: [
            Expanded(
          child: _buildQuickActionCard(
            icon: Icons.ios_share_rounded,
            label: 'Show my QR code',
            color: AppColors.primaryDark,
            onTap: () => _showQrCodeSheet(context),
          ),
        ),
              const SizedBox(width: AppSizes.paddingM),

        Expanded(
          child: _buildQuickActionCard(
            icon: Icons.qr_code_scanner,
            label: 'Scan Code',
            color: AppColors.info,
            onTap: () => Get.toNamed('/qr-scanner'),
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

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// Collapsing WhatsApp-style profile header: the avatar shrinks and slides
/// next to the back button while the username moves into the title row as
/// the sheet is scrolled up.
class _ProfileHeaderDelegate extends SliverPersistentHeaderDelegate {
  _ProfileHeaderDelegate({
    required this.expandedHeight,
    required this.collapsedHeight,
    required this.statusBarHeight,
    required this.controller,
    required this.onQrTap,
    required this.onEditName,
  });

  final double expandedHeight;
  final double collapsedHeight;
  final double statusBarHeight;
  final ProfileController controller;
  final VoidCallback onQrTap;
  final VoidCallback onEditName;

  static const double _avatarExpandedSize = 72.0;
  static const double _avatarCollapsedSize = 34.0;
  static const double _leadingSlot = 52.0;

  @override
  double get minExtent => collapsedHeight;

  @override
  double get maxExtent => expandedHeight;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final maxShrink = maxExtent - minExtent;
    final t = maxShrink > 0 ? (shrinkOffset / maxShrink).clamp(0.0, 1.0) : 0.0;
    final width = MediaQuery.of(context).size.width;

    // Toolbar row lives below the status bar; center collapsed elements
    // within that row (not the full collapsed height) so they line up
    // vertically with the back button.
    final toolbarCenterY = statusBarHeight + kToolbarHeight / 2;

    final avatarSize = _lerp(_avatarExpandedSize, _avatarCollapsedSize, t);
    final avatarLeftExpanded = (width - _avatarExpandedSize) / 2;
    final avatarLeft = _lerp(avatarLeftExpanded, _leadingSlot, t);
    final avatarTopExpanded = statusBarHeight + 14.0;
    final avatarTopCollapsed = toolbarCenterY - _avatarCollapsedSize / 2;
    final avatarTop = _lerp(avatarTopExpanded, avatarTopCollapsed, t);

    final nameFontSize = _lerp(AppSizes.fontXXL, AppSizes.fontL, t);
    final nameTopExpanded = avatarTopExpanded + _avatarExpandedSize + 10.0;
    final nameTopCollapsed = toolbarCenterY - (nameFontSize * 1.25) / 2;
    final nameTop = _lerp(nameTopExpanded, nameTopCollapsed, t);
    final nameLeftCollapsed = _leadingSlot + _avatarCollapsedSize + 12.0;

    // Fades out the edit hint + QR chip quickly as collapse begins.
    final secondaryOpacity = (1 - t * 2.5).clamp(0.0, 1.0);
    final showSecondary = secondaryOpacity > 0.01;

    return Container(
      height: expandedHeight - shrinkOffset < collapsedHeight
          ? collapsedHeight
          : expandedHeight - shrinkOffset,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primaryDark, AppColors.primary],
        ),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (Navigator.canPop(context))
            Positioned(
              left: 4,
              top: statusBarHeight,
              height: kToolbarHeight,
              child: Center(
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          Positioned(
            left: avatarLeft,
            top: avatarTop,
            child: Obx(
              () => Container(
                width: avatarSize,
                height: avatarSize,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: Colors.white, width: _lerp(3, 2, t)),
                ),
                child: ClipOval(
                  child: VantAvatar(
                    userId: controller.deviceId.value,
                    name: controller.userName.value,
                    size: avatarSize,
                    borderRadius: avatarSize / 2,
                    // Pencil badge only while expanded — it would cover most
                    // of the shrunken 34px collapsed avatar.
                    showEditBadge: t < 0.5,
                    onTap: () => Get.isRegistered<ProfileAvatarService>()
                        ? Get.find<ProfileAvatarService>()
                            .showAvatarOptions()
                        : null,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: _lerp(0, nameLeftCollapsed, t),
            right: _lerp(0, _leadingSlot, t),
            top: nameTop,
            child: Obx(() {
              return Align(
                alignment: Alignment.lerp(
                  Alignment.center,
                  Alignment.centerLeft,
                  t,
                )!,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onEditName,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 6, horizontal: 4),
                          child: Text(
                            controller.userName.value,
                            style: TextStyle(
                              fontSize: nameFontSize,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    if (showSecondary)
                      Opacity(
                        opacity: secondaryOpacity,
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 18,
                          icon: const Icon(Icons.edit,
                              color: Colors.black87),
                          onPressed: onEditName,
                        ),
                      ),
                  ],
                ),
              );
            }),
          ),
      
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _ProfileHeaderDelegate oldDelegate) => true;
}
