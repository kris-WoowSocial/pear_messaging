import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/services/socket_service.dart';
import 'strict_account_settings_screen.dart';

/// Settings → Advanced — WhatsApp-style advanced privacy controls.
/// All four controls persist via LocalStorageService and enforce
/// client-side + server-side:
///  1. Block unknown account messages (burst throttle, client + server)
///  2. Protect IP address in calls (WebRTC relay-only ICE policy)
///  3. Disable link previews (no OG metadata fetch, plain URLs)
///  4. Strict account settings (locks 1–3 ON + silences unknown callers)
class AdvancedPrivacyScreen extends StatefulWidget {
  const AdvancedPrivacyScreen({super.key});

  @override
  State<AdvancedPrivacyScreen> createState() => _AdvancedPrivacyScreenState();
}

class _AdvancedPrivacyScreenState extends State<AdvancedPrivacyScreen> {
  final LocalStorageService _storage = Get.find();

  final RxBool _blockUnknown = false.obs;
  final RxBool _protectIp = false.obs;
  final RxBool _disablePreviews = false.obs;
  final RxBool _strict = false.obs;

  @override
  void initState() {
    super.initState();
    _blockUnknown.value = _storage.blockUnknownMessages;
    _protectIp.value = _storage.protectCallIpAddress;
    _disablePreviews.value = _storage.disableLinkPreviews;
    _strict.value = _storage.strictAccountSettings;
  }

  void _syncPrefsToServer() {
    try {
      if (Get.isRegistered<SocketService>()) {
        Get.find<SocketService>().updatePrivacyPrefs();
      }
    } catch (_) {}
  }

  Future<void> _setBlockUnknown(bool v) async {
    await _storage.setBlockUnknownMessages(v);
    _blockUnknown.value = v;
    _syncPrefsToServer();
  }

  Future<void> _setProtectIp(bool v) async {
    await _storage.setProtectCallIpAddress(v);
    _protectIp.value = v;
  }

  Future<void> _setDisablePreviews(bool v) async {
    await _storage.setDisableLinkPreviews(v);
    _disablePreviews.value = v;
  }

  Future<void> _openStrict() async {
    await Get.to(() => const StrictAccountSettingsScreen());
    // Strict toggling writes the subordinate prefs directly — refresh
    // every switch so the screen reflects what Strict changed.
    _blockUnknown.value = _storage.blockUnknownMessages;
    _protectIp.value = _storage.protectCallIpAddress;
    _disablePreviews.value = _storage.disableLinkPreviews;
    _strict.value = _storage.strictAccountSettings;
    _syncPrefsToServer();
  }

  /// Learn-more bottom sheet: title + calm bullet rows + "Got it".
  void _showLearnMore({
    required String title,
    required List<({IconData icon, String heading, String body})> points,
  }) {
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
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: AppSizes.paddingM),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Center(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: AppSizes.fontL,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: AppSizes.paddingL),
              ...points.map(
                (p) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSizes.paddingM),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(p.icon, color: AppColors.primaryDark, size: 22),
                      const SizedBox(width: AppSizes.paddingM),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.heading,
                              style: const TextStyle(
                                fontSize: AppSizes.fontM,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              p.body,
                              style: const TextStyle(
                                fontSize: AppSizes.fontS,
                                color: AppColors.textSecondary,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSizes.paddingS),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.textPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppSizes.radiusM),
                    ),
                  ),
                  onPressed: () => Get.back(),
                  child: const Text('Got it'),
                ),
              ),
            ],
          ),
        ),
      ),
      isScrollControlled: true,
    );
  }

  /// One switch row: title + subtitle with inline green "Learn more" +
  /// switch (optionally locked ON by strict mode).
  Widget _privacySwitch({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
    required VoidCallback onLearnMore,
  }) {
    final locked = onChanged == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSizes.paddingS),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                const SizedBox(height: 4),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$subtitle ',
                        style: const TextStyle(
                          fontSize: AppSizes.fontS,
                          color: AppColors.textSecondary,
                          height: 1.35,
                        ),
                      ),
                      WidgetSpan(
                        alignment: PlaceholderAlignment.baseline,
                        baseline: TextBaseline.alphabetic,
                        child: GestureDetector(
                          onTap: onLearnMore,
                          child: const Text(
                            'Learn more',
                            style: TextStyle(
                              fontSize: AppSizes.fontS,
                              color: AppColors.primaryDark,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (locked) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'Locked on by Strict account settings',
                    style: TextStyle(
                      fontSize: AppSizes.fontXS,
                      color: AppColors.textSecondary,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSizes.paddingS),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: AppColors.primaryDark,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'Advanced',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: AppColors.surface,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: Obx(
        () {
          final strict = _strict.value;
          return ListView(
            padding: const EdgeInsets.all(AppSizes.paddingM),
            children: [
              Container(
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
                  children: [
                    _privacySwitch(
                      title: 'Block unknown account messages',
                      subtitle:
                          'To protect your account and improve device performance, Vant Chat will block messages from unknown accounts if they exceed a certain volume.',
                      value: strict || _blockUnknown.value,
                      onChanged: strict ? null : _setBlockUnknown,
                      onLearnMore: () => _showLearnMore(
                        title: 'About unknown account messages',
                        points: const [
                          (
                            icon: Icons.shield_outlined,
                            heading: 'Rapid bursts are limited',
                            body:
                                'Messages from people you haven\'t connected with are throttled when they arrive in rapid spam-like bursts. Excess messages are quietly blocked — you won\'t be notified.',
                          ),
                          (
                            icon: Icons.people_outline,
                            heading: 'Normal requests still work',
                            body:
                                'Connection requests and a few first messages from new people still reach you as usual. Only high-volume bursts from unknown accounts are affected.',
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: AppColors.divider),
                    _privacySwitch(
                      title: 'Protect IP address in calls',
                      subtitle:
                          'Route calls through Vant servers so the other person can\'t see your IP address or approximate location. Calls stay end-to-end encrypted, though quality may vary slightly.',
                      value: strict || _protectIp.value,
                      onChanged: strict ? null : _setProtectIp,
                      onLearnMore: () => _showLearnMore(
                        title: 'How Call IP Protection Works',
                        points: const [
                          (
                            icon: Icons.vpn_lock_outlined,
                            heading: 'Hides your network address',
                            body:
                                'Your calls connect through Vant\'s relay servers instead of directly to the other person\'s device, keeping your IP address and city private.',
                          ),
                          (
                            icon: Icons.lock_outline,
                            heading: 'Still end-to-end encrypted',
                            body:
                                'Relaying only changes the path of your call — nobody, not even Vant, can listen to or watch your calls.',
                          ),
                          (
                            icon: Icons.person_add_alt_outlined,
                            heading: 'Best when calling new contacts',
                            body:
                                'Leave this Off for the sharpest HD quality with trusted contacts, or turn it On whenever you want extra location privacy.',
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: AppColors.divider),
                    _privacySwitch(
                      title: 'Disable link previews',
                      subtitle:
                          'To help protect your IP address from being inferred by third-party websites, previews for the links you share in chats will no longer be generated.',
                      value: strict || _disablePreviews.value,
                      onChanged: strict ? null : _setDisablePreviews,
                      onLearnMore: () => _showLearnMore(
                        title: 'About link previews',
                        points: const [
                          (
                            icon: Icons.link_off,
                            heading: 'Previews reveal your IP',
                            body:
                                'Creating a rich preview card requires fetching the website\'s metadata, which exposes your IP address to that website\'s servers.',
                          ),
                          (
                            icon: Icons.link,
                            heading: 'Links still work normally',
                            body:
                                'With this on, links are sent as plain clickable URLs. Nothing is fetched and no external requests are made — the link simply opens when tapped.',
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: AppColors.divider),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _openStrict,
                        borderRadius: BorderRadius.circular(AppSizes.radiusS),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSizes.paddingS,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Strict account settings',
                                      style: TextStyle(
                                        fontSize: AppSizes.fontM,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'To help protect your account if you are at high-risk of targeted cyber attacks, certain settings will be locked. Most people do not need this level of protection. This will reduce the quality of your messaging experience and calls.',
                                      style: TextStyle(
                                        fontSize: AppSizes.fontS,
                                        color: AppColors.textSecondary,
                                        height: 1.35,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: AppSizes.paddingS),
                              Text(
                                strict ? 'On' : 'Off',
                                style: TextStyle(
                                  fontSize: AppSizes.fontM,
                                  fontWeight: FontWeight.w600,
                                  color: strict
                                      ? AppColors.primaryDark
                                      : AppColors.textSecondary,
                                ),
                              ),
                              const Icon(
                                Icons.arrow_forward_ios,
                                size: 14,
                                color: AppColors.textSecondary,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
