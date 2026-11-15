import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import 'chat_list_controller.dart';
import 'chat_list_item.dart';
import 'chat_list_model.dart';

/// Biometric-gated view of chats hidden from the main list via Chat Lock.
/// Entry is behind LocalAuthService.authenticate() in
/// ChatListController.openLockedChats(); this screen just renders
/// controller.lockedChats.
class LockedChatsScreen extends GetView<ChatListController> {
  const LockedChatsScreen({super.key});

  void _showUnlockOption(ChatListModel chat) {
    Get.bottomSheet(
      Container(
        color: AppColors.background,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading:
                    const Icon(Icons.lock_open, color: AppColors.textPrimary),
                title: const Text(
                  'Unlock chat',
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                onTap: () {
                  Get.back();
                  controller.unlockChat(chat);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        title: const Text(
          'Locked chats',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: Obx(() {
        final locked = controller.lockedChats;
        if (locked.isEmpty) {
          return const Center(
            child: Text(
              'No locked chats',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: AppSizes.fontL,
              ),
            ),
          );
        }
        return ListView.builder(
          itemCount: locked.length,
          itemBuilder: (context, index) {
            final chat = locked[index];
            return Column(
              children: [
                ChatListItem(
                  chat: chat,
                  onTap: () => controller.openChat(chat),
                  onLongPress: () => _showUnlockOption(chat),
                ),
                if (index < locked.length - 1)
                  const Divider(
                    height: 1,
                    indent: AppSizes.paddingM +
                        AppSizes.avatarSize +
                        AppSizes.paddingM,
                    color: AppColors.divider,
                  ),
              ],
            );
          },
        );
      }),
    );
  }
}
