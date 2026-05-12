import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:get/get.dart';
import 'package:android_intent_plus/android_intent.dart';
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
  ChatListScreen({super.key});

  final _shareButtonKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final socketService = Get.find<SocketService>();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        toolbarHeight: 70,
        leadingWidth: 70,
        leading: GestureDetector(
          onTap: () => _showSelfDestructSheet(context),
          child: Container(
            height: 70,
            width: 70,
            margin: EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: AppColors.error,
              border: Border.all(color: AppColors.textPrimary, width: 2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: const Text(
                'Self\nDestruct\n1 Click',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 8),
            const Text(
              'Vant Chat',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              'E2E-PQC Encryption Serverless-Invisible',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 10,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(
              Icons.settings,
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
        key: _shareButtonKey,
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

  void _showSelfDestructSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const _SelfDestructSheet(),
    );
  }

  void shareApp() async {
    try {
      // Calculate share position origin from the button's position
      Rect? sharePositionOrigin;
      if (_shareButtonKey.currentContext != null) {
        final RenderBox renderBox =
            _shareButtonKey.currentContext!.findRenderObject() as RenderBox;
        final Offset offset = renderBox.localToGlobal(Offset.zero);
        sharePositionOrigin = Rect.fromLTWH(
          offset.dx,
          offset.dy,
          renderBox.size.width,
          renderBox.size.height,
        );
      }

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
      await branchService.shareApp(sharePositionOrigin: sharePositionOrigin);
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

class _SelfDestructSheet extends StatefulWidget {
  const _SelfDestructSheet();

  @override
  State<_SelfDestructSheet> createState() => _SelfDestructSheetState();
}

class _SelfDestructSheetState extends State<_SelfDestructSheet> {
  bool _isDeleting = false;

  Future<void> _executeDestruct() async {
    setState(() => _isDeleting = true);
    try {
      debugPrint('🔥 Starting self-destruct sequence...');

      // Unregister FCM token from server so no more notifications are sent
      try {
        final prefs = await SharedPreferences.getInstance();
        final deviceId = prefs.getString('device_id');
        if (deviceId != null && deviceId.isNotEmpty) {
          await http
              .delete(
                Uri.parse(
                    'https://vant.chat/api/membership/unregister-device/$deviceId'),
              )
              .timeout(const Duration(seconds: 5));
          debugPrint(
              '✅ FCM token unregistered from server for device: $deviceId');
        }
      } catch (e) {
        debugPrint('⚠️ Failed to unregister FCM token (continuing wipe): $e');
      }

      // Clear all Hive boxes
      debugPrint('🗑️ Clearing Hive boxes...');
      await Hive.box('chats').clear();
      debugPrint('✅ Chats box cleared');
      await Hive.box('messages').clear();
      debugPrint('✅ Messages box cleared');
      await Hive.box('connection_requests').clear();
      debugPrint('✅ Connection requests box cleared');

      // Clear all SharedPreferences
      debugPrint('🗑️ Clearing SharedPreferences...');
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      debugPrint('✅ SharedPreferences cleared');

      // Trigger app uninstall on Android
      if (Theme.of(context).platform == TargetPlatform.android) {
        debugPrint('📱 Triggering Android uninstall...');
        final intent = AndroidIntent(
          action: 'android.intent.action.DELETE',
          data: 'package:com.vant.chat',
        );
        await intent.launch();
        debugPrint('✅ Uninstall intent launched');

        // Give user time to respond to uninstall dialog
        await Future.delayed(const Duration(seconds: 3));

        // If we're still here, user likely cancelled uninstall
        // Navigate to splash to show fresh state
        Get.offAllNamed(AppRoutes.splash);
      }

      // For iOS, set flag to generate new device ID on next launch and exit app
      if (Theme.of(context).platform == TargetPlatform.iOS) {
        debugPrint('🍎 Setting iOS self-destruct flag...');
        // Need fresh prefs instance since we cleared the previous one
        final freshPrefs = await SharedPreferences.getInstance();
        await freshPrefs.setBool('self_destruct_ios', true);
        debugPrint('✅ iOS self-destruct flag set, exiting app...');
        exit(0);
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Self-destruct failed: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      setState(() => _isDeleting = false);
      Get.snackbar(
        'Error',
        'Failed to wipe data: ${e.toString()}',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
        duration: const Duration(seconds: 5),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.52,
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(28),
          topRight: Radius.circular(28),
        ),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),
          // Red warning icon
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: Colors.red.shade900.withOpacity(0.3),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.red.shade700, width: 2),
            ),
            child: Icon(
              Icons.warning_amber_rounded,
              color: Colors.red.shade400,
              size: 38,
            ),
          ),
          const SizedBox(height: 20),
          // Title
          const Text(
            'Self Destruct',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 10),
          // Warning text
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'This will permanently delete ALL chats, messages, and app data.\n\nThis action cannot be undone and data cannot be recovered.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white60,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ),
          const Spacer(),
          // Buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            child: Row(
              children: [
                // Cancel button
                Expanded(
                  child: TextButton(
                    onPressed:
                        _isDeleting ? null : () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: const BorderSide(color: Colors.white24),
                      ),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Done / Destruct button
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isDeleting ? null : _executeDestruct,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      disabledBackgroundColor: Colors.red.shade900,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                    child: _isDeleting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Destruct',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
