import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pear_messaging/core/services/branch_service.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_strings.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/services/socket_service.dart';
import '../../core/widgets/empty_state.dart';
import '../../routes/app_routes.dart';
import 'chat_list_controller.dart';
import 'chat_list_item.dart';
import 'connection_request_item.dart';

class ChatListScreen extends GetView<ChatListController> {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final socketService = Get.find<SocketService>();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        toolbarHeight: 50,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12, top: 6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/icons/app_icon.png',
              width: 44,
              height: 44,
              fit: BoxFit.cover,
            ),
          ),
        ),
        title: Transform.translate(
          offset: const Offset(-20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: 10),
              const Text(
                'Vant Chats',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 5),
              const Text(
                'Serverless. Private. Direct. Encrypted.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.person_outline,
              color: AppColors.textPrimary,
            ),
            onPressed: () => Get.toNamed(AppRoutes.profile),
          ),
        ],
      ),
      body: Column(
        children: [
          // Current user row with connection indicator
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(10),
                bottomRight: Radius.circular(10),
              ),
            ),
            child: Column(
              children: [
                SizedBox(height: 10),
                Container(
                  height: 1,
                  color: Colors.grey,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      // Avatar with green connection dot
                      Obx(
                        () => Stack(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: AppColors.senderBubble,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Center(
                                child: Text(
                                  controller.userDisplayName.isNotEmpty
                                      ? controller.userDisplayName[0]
                                          .toUpperCase()
                                      : 'U',
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            // Green dot for socket connection
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Obx(
                                () => Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: socketService.isConnected.value
                                        ? Colors.green
                                        : Colors.grey,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: AppColors.surface,
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      // User name - editable inline
                      Expanded(
                        child: Obx(
                          () => controller.isEditingName.value
                              ? TextField(
                                  controller: controller.userNameController,
                                  autofocus: true,
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    contentPadding:
                                        EdgeInsets.symmetric(vertical: 8),
                                    border: UnderlineInputBorder(),
                                    focusedBorder: UnderlineInputBorder(
                                      borderSide: BorderSide(
                                        color: AppColors.textPrimary,
                                      ),
                                    ),
                                  ),
                                  onSubmitted: (_) => controller.saveUserName(),
                                )
                              : Text(
                                  controller.userDisplayName,
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                        ),
                      ),
                      // Edit/Save icon
                      Obx(
                        () => controller.isEditingName.value
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(
                                      Icons.check,
                                      color: Colors.green,
                                      size: 22,
                                    ),
                                    onPressed: () => controller.saveUserName(),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.close,
                                      color: Colors.red,
                                      size: 22,
                                    ),
                                    onPressed: () =>
                                        controller.cancelEditingName(),
                                  ),
                                ],
                              )
                            : Column(
                                children: [
                                  IconButton(
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      color: AppColors.textPrimary,
                                      size: 22,
                                    ),
                                    onPressed: () =>
                                        controller.startEditingName(),
                                  ),
                                  const Text(
                                    'Edit your name',
                                    style: TextStyle(
                                      color: AppColors.textPrimary,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 10),
              ],
            ),
          ),

          // Search bar
          Container(
            padding: const EdgeInsets.all(AppSizes.paddingM),
            color: AppColors.primary,
            child: TextField(
              controller: controller.searchController,
              onChanged: controller.searchChats,
              decoration: InputDecoration(
                hintText: AppStrings.searchChats,
                prefixIcon: const Icon(
                  Icons.search,
                  color: AppColors.textPrimary,
                ),
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppSizes.radiusM),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // Combined list of connection requests and chats
          Expanded(
            child: Obx(() {
              final hasChats = controller.filteredChats.isNotEmpty;
              final hasConnectionRequests =
                  controller.pendingConnectionRequests.isNotEmpty;
              final hasItems = hasChats || hasConnectionRequests;

              if (!hasItems) {
                return EmptyState(
                  title: AppStrings.noChats,
                  subtitle: AppStrings.startChatting,
                  icon: Icons.chat_bubble_outline,
                );
              }

              print(
                '🔍 DEBUG: Building chat list - Requests: ${controller.pendingConnectionRequests.length}, Chats: ${controller.filteredChats.length}',
              );

              return ListView.builder(
                itemCount: controller.pendingConnectionRequests.length +
                    controller.filteredChats.length,
                itemBuilder: (context, index) {
                  // First show connection requests, then chats
                  if (index < controller.pendingConnectionRequests.length) {
                    // Show connection request item
                    final request = controller.pendingConnectionRequests[index];
                    print(
                        '🔍 DEBUG: Rendering connection request item - ID: ${request.id}, Sender: ${request.senderDeviceId}');
                    return ConnectionRequestItem(request: request);
                  } else {
                    // Show chat item
                    final chatIndex =
                        index - controller.pendingConnectionRequests.length;
                    final chat = controller.filteredChats[chatIndex];

                    return Column(
                      children: [
                        ChatListItem(
                          chat: chat,
                          onTap: () => controller.openChat(chat),
                        ),
                        // Regular divider between chats
                        if (chatIndex < controller.filteredChats.length - 1)
                          const Divider(
                            height: 1,
                            indent: AppSizes.paddingM +
                                AppSizes.avatarSize +
                                AppSizes.paddingM,
                            color: AppColors.divider,
                          ),
                      ],
                    );
                  }
                },
              );
            }),
          ),
        ],
      ),
      floatingActionButton: InkWell(
        onTap: () => shareApp(),
        child: Container(
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              color: AppColors.primary,
              boxShadow: [
                BoxShadow(
                  spreadRadius: 0.7,
                  offset: Offset(3, 2),
                  blurRadius: 7,
                  blurStyle: BlurStyle.solid,
                  color: AppColors.primaryDark,
                ),
              ]),
          padding: EdgeInsets.all(10),
          child: Wrap(
            children: [
              const Icon(
                Icons.share,
                color: Colors.black,
                size: 24,
              ),
              SizedBox(width: 7),
              Text(
                "Invite Friends",
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  void shareApp() async {
    try {
      // Get or initialize Branch service
      BranchService branchService;
      try {
        branchService = Get.find<BranchService>();
      } catch (e) {
        // Branch service not initialized, create one
        branchService = BranchService();
        Get.put(branchService);
        await branchService.init();
      }

      // Share the app
      await branchService.shareApp();
    } catch (e) {
      print('❌ Error sharing app: $e');
      Get.snackbar(
        'Share Failed',
        'Unable to share the app. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }
}
