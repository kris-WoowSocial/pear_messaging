import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/services/socket_service.dart';

/// Strict account settings — master switch that locks the Advanced
/// privacy controls ON for high-risk accounts. Enabling forces:
///   • Block unknown account messages     → ON (locked)
///   • Protect IP address in calls        → ON (locked)
///   • Disable link previews              → ON (locked)
///   • Silence unknown callers            → ON
///   • No auto-download from strangers    → ON
/// Turning Strict OFF unlocks the individual switches on the Advanced
/// screen without reverting the values they were left at.
class StrictAccountSettingsScreen extends StatefulWidget {
  const StrictAccountSettingsScreen({super.key});

  @override
  State<StrictAccountSettingsScreen> createState() =>
      _StrictAccountSettingsScreenState();
}

class _StrictAccountSettingsScreenState
    extends State<StrictAccountSettingsScreen> {
  final LocalStorageService _storage = Get.find();
  final RxBool _strict = false.obs;

  @override
  void initState() {
    super.initState();
    _strict.value = _storage.strictAccountSettings;
  }

  Future<void> _setStrict(bool enabled) async {
    await _storage.setStrictAccountSettings(enabled);
    if (enabled) {
      // Force the three Advanced switches ON — they stay locked until
      // Strict is turned back off.
      await _storage.setBlockUnknownMessages(true);
      await _storage.setProtectCallIpAddress(true);
      await _storage.setDisableLinkPreviews(true);
      await _storage.setSilenceUnknownCallers(true);
    }
    _strict.value = enabled;
    try {
      if (Get.isRegistered<SocketService>()) {
        Get.find<SocketService>().updatePrivacyPrefs();
      }
    } catch (_) {}
  }

  Widget _lockedRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppColors.primaryDark),
          const SizedBox(width: AppSizes.paddingM),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: AppSizes.fontM,
                color: AppColors.textPrimary,
                height: 1.3,
              ),
            ),
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
          'Strict account settings',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: AppColors.surface,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSizes.paddingM),
        children: [
          Container(
            padding: const EdgeInsets.all(AppSizes.paddingM),
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
                const Text(
                  'This is an extra layer of protection for people at high risk of sophisticated cyber attacks, like journalists, activists or public figures. Most people don\'t need this level of protection.',
                  style: TextStyle(
                    fontSize: AppSizes.fontS,
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: AppSizes.paddingM),
                Obx(
                  () => Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Enable strict account settings',
                          style: TextStyle(
                            fontSize: AppSizes.fontM,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      Switch(
                        value: _strict.value,
                        onChanged: _setStrict,
                        activeColor: AppColors.primaryDark,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSizes.paddingM),
          Container(
            padding: const EdgeInsets.all(AppSizes.paddingM),
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
                const Text(
                  'While strict account settings are on:',
                  style: TextStyle(
                    fontSize: AppSizes.fontS,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: AppSizes.paddingS),
                _lockedRow(
                  Icons.shield_outlined,
                  'Messages from unknown accounts are blocked if they exceed a certain volume.',
                ),
                _lockedRow(
                  Icons.vpn_lock_outlined,
                  'Calls are routed through Vant servers to hide your IP address. This may slightly reduce call quality.',
                ),
                _lockedRow(
                  Icons.link_off,
                  'Link previews are disabled so websites can\'t infer your IP address.',
                ),
                _lockedRow(
                  Icons.phone_disabled_outlined,
                  'Calls from people you haven\'t connected with are silenced.',
                ),
                _lockedRow(
                  Icons.download_outlined,
                  'Attachments and files from people you haven\'t connected with won\'t download automatically.',
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSizes.paddingM),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSizes.paddingS),
            child: Text(
              'Turning strict account settings off unlocks these settings so you can change them individually again.',
              style: TextStyle(
                fontSize: AppSizes.fontS,
                color: AppColors.textSecondary,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
