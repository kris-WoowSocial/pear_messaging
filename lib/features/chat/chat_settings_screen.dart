import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pear_messaging/core/widgets/report_bottom_sheet.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/utils/string_utils.dart';
import '../../core/services/feature_flag_service.dart';
import '../../core/services/local_storage_service.dart';
import 'chat_controller.dart';
import 'verify_contact_screen.dart';

class ChatSettingsScreen extends GetView<ChatController> {
  const ChatSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Contact Info',
          style: TextStyle(
            fontSize: AppSizes.fontL,
            fontWeight: FontWeight.bold,
            color: Colors.black,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Get.back(),
        ),
      ),
      body: SingleChildScrollView(
        child: SafeArea(
          child: Column(
            children: [
              // User Profile Section
              _buildProfileSection(),

              const SizedBox(height: 8),

              // Notification Settings
              _buildNotificationSection(),

              const SizedBox(height: 8),

              // Identity verification — only when the remote flag is ON.
              _buildVerifySection(),

              // Privacy & Security
              _buildPrivacySection(),

              const SizedBox(height: 8),

              // Storage & Data
              _buildStorageSection(),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVerifySection() {
    if (!Get.isRegistered<FeatureFlagService>()) return const SizedBox();
    final flags = Get.find<FeatureFlagService>();
    return Obx(() {
      if (!flags.verificationUi.value) return const SizedBox();
      final peerId = controller.recipientDeviceId;
      final storage = Get.find<LocalStorageService>();
      final status = storage.getPeerVerificationStatus(peerId);
      final conflict =
          storage.getPeerConflictBundle(peerId) != null;
      return ListTile(
        leading: Icon(
          conflict ? Icons.warning_amber_rounded : Icons.verified_user_outlined,
          color: conflict ? Colors.red : (status == 'verified' ? Colors.green : Colors.grey),
        ),
        title: Text(
          conflict
              ? 'Identity key changed — verify again'
              : status == 'verified'
                  ? 'Identity key verified'
                  : 'Identity key not verified',
        ),
        subtitle: const Text('Compare safety codes or scan a QR'),
        onTap: () => Get.to(() => VerifyContactScreen(peerId: peerId)),
      );
    });
  }

  Widget _buildProfileSection() {
    return Container(
      color: AppColors.senderBubble,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          // Profile Avatar
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.person,
              size: 50,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 16),

          // Contact Name
          Obx(
            () => GestureDetector(
              onTap: () {
                _showEditNameDialog();
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    StringUtils.formatDeviceIdWithName(
                      controller.recipientDeviceId,
                      controller.displayName.value,
                    ),
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(width: 20),
                  Icon(
                    Icons.edit_outlined,
                    size: 24,
                    color: Colors.black,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),

          // Online Status
          Obx(
            () => Text(
              controller.recipientStatus.value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: controller.recipientOnline.value
                    ? Colors.green
                    : Colors.grey,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildNotificationSection() {
    return Container(
      color: AppColors.senderBubble,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'NOTIFICATIONS',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey[600],
              ),
            ),
          ),
          _buildSettingsTile(
            icon: Icons.notifications_outlined,
            title: 'Mute Notifications',
            subtitle: 'Silence notifications for this chat',
            iconColor: AppColors.info,
            trailing: Obx(
              () => Switch(
                value: controller.isMuted.value,
                onChanged: (value) => controller.toggleMute(),
                activeColor: AppColors.info,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrivacySection() {
    return Container(
      color: AppColors.senderBubble,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'PRIVACY & SECURITY',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey[600],
              ),
            ),
          ),
          // _buildSettingsTile(
          //   icon: Icons.edit_outlined,
          //   title: 'Edit Contact Name',
          //   subtitle: 'Change the display name for this contact',
          //   iconColor: AppColors.messageText,
          //   onTap: () {
          //     _showEditNameDialog();
          //   },
          // ),
          // const Divider(height: 1, indent: 56),
          Obx(
            () => _buildSettingsTile(
              icon: controller.isBlockedByMe.value
                  ? Icons.lock_open
                  : Icons.block_outlined,
              title: controller.isBlockedByMe.value
                  ? 'Unblock Contact'
                  : 'Block Contact',
              subtitle: controller.isBlockedByMe.value
                  ? 'Allow this user to message you again'
                  : 'Block this user from messaging you',
              iconColor:
                  controller.isBlockedByMe.value ? Colors.green : Colors.red,
              onTap: () {
                if (controller.isBlockedByMe.value) {
                  controller.unblockUser();
                } else {
                  _showBlockConfirmation();
                }
              },
            ),
          ),
          const Divider(height: 1, indent: 56),
          _buildSettingsTile(
            icon: Icons.report_outlined,
            title: 'Report Contact',
            subtitle: 'Report spam or abuse',
            iconColor: Colors.orange,
            onTap: () {
              ReportBottomSheet.show(
                  targetType: 'user', targetId: controller.recipientDeviceId);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildStorageSection() {
    return Container(
      color: AppColors.senderBubble,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'STORAGE & DATA',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey[600],
              ),
            ),
          ),
          _buildSettingsTile(
            icon: Icons.delete_sweep_outlined,
            title: 'Clear All Messages',
            subtitle: 'Delete all messages in this chat',
            iconColor: Colors.orange,
            onTap: () {
              controller.showClearChatDialog();
            },
          ),
          const Divider(height: 1, indent: 56),
          _buildSettingsTile(
            icon: Icons.delete_forever_outlined,
            title: 'Delete Chat',
            subtitle: 'Delete this chat permanently',
            iconColor: Colors.red,
            onTap: () {
              Get.back();
              controller.showDeleteConfirmation();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required String title,
    String? subtitle,
    Color? iconColor,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: (iconColor ?? AppColors.primary).withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          color: iconColor ?? AppColors.primary,
          size: 22,
        ),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: Colors.black,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[600],
              ),
            )
          : null,
      trailing: trailing ??
          (onTap != null
              ? Icon(Icons.chevron_right, color: Colors.grey[400])
              : null),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    );
  }

  /// Show edit name dialog
  void _showEditNameDialog() {
    final nameController = TextEditingController(
      text: controller.displayName.value,
    );

    Get.dialog(
      Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: Colors.white,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () => Get.back(),
                    icon: const Icon(Icons.close),
                  ),
                  const SizedBox(width: AppSizes.paddingM),
                  const Expanded(
                    child: Text('Edit Contact Name',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: AppSizes.paddingL),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: 'Contact Name',
                  hintText: 'Enter contact name',
                  hintStyle: TextStyle(color: Colors.grey.shade400),
                  filled: true,
                  fillColor: Colors.grey.shade50,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSizes.paddingM,
                    vertical: AppSizes.paddingM,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: AppColors.primary, width: 2),
                  ),
                ),
                // Auto-select all text when field gets focus
                onTap: () {
                  nameController.selection = TextSelection(
                    baseOffset: 0,
                    extentOffset: nameController.text.length,
                  );
                },
              ),
              const SizedBox(height: AppSizes.paddingL),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    // Unfocus the keyboard first
                    FocusScope.of(Get.context!).unfocus();

                    final newName = nameController.text.trim();
                    if (newName.isNotEmpty) {
                      // Close dialog first
                      Get.back();
                      // Update the name
                      controller.updateDisplayName(newName);
                      // Show success message
                      Get.snackbar(
                        'Success',
                        'Contact name updated',
                        snackPosition: SnackPosition.BOTTOM,
                        backgroundColor: Colors.green.withOpacity(0.8),
                        colorText: Colors.white,
                        duration: const Duration(seconds: 2),
                      );
                    } else {
                      Get.snackbar(
                        'Error',
                        'Please enter a name',
                        snackPosition: SnackPosition.BOTTOM,
                        backgroundColor: Colors.red.withOpacity(0.8),
                        colorText: Colors.white,
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBlockConfirmation() {
    Get.dialog(
      Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: Colors.white,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.block,
                  size: 36,
                  color: Colors.orange.shade700,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Block User',
                style: Get.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade800,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Blocked users will no longer be able to send you messages. You can unblock them anytime.',
                style: Get.textTheme.bodyMedium?.copyWith(
                  color: Colors.grey.shade600,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Get.back(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Get.back();
                        controller.blockUser();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange.shade600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text('Block'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
