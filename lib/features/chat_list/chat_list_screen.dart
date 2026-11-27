import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/services/api_service.dart';
import 'package:get/get.dart';
import 'package:android_intent_plus/android_intent.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_strings.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/services/socket_service.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/services/user_profile_cache.dart';
import '../../core/services/call_history_service.dart';
import '../../core/services/profile_avatar_service.dart';
import '../../widgets/vant_avatar.dart';
import '../call/call_controller.dart';
import '../../core/utils/device_utils.dart';
import '../../core/widgets/empty_state.dart';
import '../../routes/app_routes.dart';
import 'chat_list_controller.dart';
import 'chat_list_item.dart';
import '../invite/invite_fallback_sheet.dart';
import 'connection_request_item.dart';

class ChatListScreen extends GetView<ChatListController> {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final socketService = Get.find<SocketService>();
    final storageService = Get.find<LocalStorageService>();

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => Get.toNamed(AppRoutes.createGroup),
        backgroundColor: AppColors.chatAction,
        tooltip: 'New Group',
        child: const Icon(
          Icons.group_add,
          color: Colors.white,
        ),
      ),
      body: Column(
        children: [
          // White header card: paints behind the status bar, rounded
          // bottom corners with a divider line on the bottom edge.
          Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(
                bottom: Radius.circular(20),
              ),
              border: Border(
                bottom: BorderSide(color: AppColors.divider),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Self Destruct — top-left corner
                      Positioned(
                        left: 0,
                        top: 0,
                        child: GestureDetector(
                          onTap: () => _showSelfDestructSheet(context),
                          child: Container(
                            height: 55,
                            width: 60,
                            decoration: BoxDecoration(
                              color: AppColors.error,
                              border: Border.all(
                                color: AppColors.textPrimary,
                                width: 1,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Center(
                              child: Text(
                                'Self\nDestruct\n1 Click',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Avatar + name centered
                      Center(
                        child: Column(
                          children: [
                            // Green ring = live socket-connection indicator
                            Obx(
                              () => Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: socketService.isConnected.value
                                        ? Colors.green
                                        : Colors.grey,
                                    width: 2,
                                  ),
                                ),
                                child: VantAvatar(
                                  userId: storageService.deviceId,
                                  name: controller.userDisplayName,
                                  avatarUrl:
                                      Get.isRegistered<UserProfileCache>()
                                          ? Get.find<UserProfileCache>()
                                              .myAvatarUrl
                                              .value
                                          : '',
                                  size: 55,
                                  borderRadius: 30,
                                  showEditBadge: true,
                                  onTap: () =>
                                      Get.isRegistered<ProfileAvatarService>()
                                          ? Get.find<ProfileAvatarService>()
                                              .showAvatarOptions()
                                          : Get.toNamed(AppRoutes.profile),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            _buildNameRow(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(
                  height: 1,
                  thickness: 1,
                  color: AppColors.divider,
                ),
                // Title row: brand left, encryption label centered, settings right
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      left: 16,
                      child: const Text(
                        'Vant Chat',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lock,
                          color: Colors.black,
                          size: 14,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'End-to-end encrypted',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        icon: const Icon(
                          Icons.settings,
                          color: AppColors.textPrimary,
                        ),
                        onPressed: () => Get.toNamed(AppRoutes.profile),
                      ),
                    ),
                  ],
                ),
              ],
              ),
            ),
          ),

          // Combined list of connection requests and chats
          Expanded(
            child: Obx(() {
              final hasChats = controller.filteredChats.isNotEmpty;
              final hasConnectionRequests =
                  controller.pendingConnectionRequests.isNotEmpty;
              final showLockedRow = controller.hasLockedChats;
              // Search only exists once the user actually has chats —
              // keys off the unfiltered list so it can't vanish mid-query.
              final showSearch = controller.chats.isNotEmpty;
              final hasItems = hasChats ||
                  hasConnectionRequests ||
                  showLockedRow ||
                  showSearch;

              if (!hasItems) {
                return EmptyState(
                  title: AppStrings.noChats,
                  subtitle: AppStrings.startChatting,
                  icon: Icons.chat_bubble_outline,
                  // iOS only: recovery for invite installs that didn't arrive
                  // via a universal link (iOS has no deferred deep-link
                  // mechanism). Android uses the Play Install Referrer and
                  // needs no manual entry point.
                  action: Platform.isIOS
                      ? TextButton.icon(
                          onPressed: InviteFallbackSheet.show,
                          icon: const Icon(Icons.card_giftcard),
                          label: const Text('Have an invite?'),
                        )
                      : null,
                );
              }

              debugPrint(
                '🔍 DEBUG: Building chat list - Requests: ${controller.pendingConnectionRequests.length}, Chats: ${controller.filteredChats.length}',
              );

              return ListView.builder(
                // The header card already consumed the status-bar inset —
                // without this the list re-applies it as a green gap.
                padding: EdgeInsets.zero,
                itemCount: (showSearch ? 1 : 0) +
                    (showLockedRow ? 1 : 0) +
                    controller.pendingConnectionRequests.length +
                    controller.filteredChats.length,
                itemBuilder: (context, index) {
                  // Search is list item 0 — scrolls up with the chats.
                  if (showSearch) {
                    if (index == 0) return _buildSearchBar();
                    index -= 1;
                  }
                  // "Locked chats" entry row pinned above everything else
                  if (showLockedRow) {
                    if (index == 0) {
                      return _buildLockedChatsRow();
                    }
                    index -= 1;
                  }
                  // First show connection requests, then chats
                  if (index < controller.pendingConnectionRequests.length) {
                    // Show connection request item
                    final request = controller.pendingConnectionRequests[index];
                    debugPrint(
                      '🔍 DEBUG: Rendering connection request item - ID: ${request.id}, Sender: ${request.senderDeviceId}',
                    );
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
    );
  }

  /// Search field — lives on the green background as the first list item
  /// so it scrolls away with the chats instead of staying pinned.
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.all(AppSizes.paddingM),
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
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  /// Centered display name with inline pencil edit (toggles a TextField
  /// with save/cancel icons while editing).
  Widget _buildNameRow() {
    return Obx(() {
      if (controller.isEditingName.value) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 180,
              child: TextField(
                controller: controller.userNameController,
                autofocus: true,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 4,horizontal: 10),
                ),
                onSubmitted: (_) => controller.saveUserName(),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.check, color: Colors.green, size: 20),
              onPressed: () => controller.saveUserName(),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 20),
              onPressed: controller.cancelEditingName,
            ),
          ],
        );
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              controller.userDisplayName,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: controller.startEditingName,
            borderRadius: BorderRadius.circular(12),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(
                Icons.edit,
                size: 16,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      );
    });
  }

  /// "Locked chats" row pinned at the top of the list — biometric gate
  /// into LockedChatsScreen. Rendered only when at least one chat is locked.
  Widget _buildLockedChatsRow() {
    return Column(
      children: [
        InkWell(
          onTap: controller.openLockedChats,
          child: Container(
            height: AppSizes.chatItemHeight,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSizes.paddingM,
              vertical: AppSizes.paddingS,
            ),
            child: Row(
              children: [
                Container(
                  width: AppSizes.avatarSize,
                  height: AppSizes.avatarSize,
                  decoration: const BoxDecoration(
                    color: AppColors.senderBubble,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.lock,
                    color: AppColors.textPrimary,
                    size: AppSizes.fontXL,
                  ),
                ),
                const SizedBox(width: AppSizes.paddingM),
                const Expanded(
                  child: Text(
                    'Locked chats',
                    style: TextStyle(
                      fontSize: AppSizes.fontL,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  color: AppColors.textPrimary,
                ),
              ],
            ),
          ),
        ),
        const Divider(
          height: 1,
          indent:
              AppSizes.paddingM + AppSizes.avatarSize + AppSizes.paddingM,
          color: AppColors.divider,
        ),
      ],
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

      if (Get.isRegistered<SocketService>()) {
        Get.find<SocketService>().disconnect();
      }
      if (Get.isRegistered<CallController>()) {
        Get.find<CallController>().endCall();
      }
      if (Get.isRegistered<CallHistoryService>()) {
        await Get.find<CallHistoryService>().clearAll();
      }

      // 1. Unregister FCM token from server so no more notifications are sent
      try {
        final prefs = await SharedPreferences.getInstance();
        final deviceId = prefs.getString('device_id');
        if (deviceId != null && deviceId.isNotEmpty) {
          await ApiService.to.unregisterDevice(deviceId);
          debugPrint(
            '✅ FCM token unregistered from server for device: $deviceId',
          );
        }
      } catch (e) {
        debugPrint('❌ Failed to delete the old identity from the server: $e');
        rethrow;
      }

      // 2. Clear ALL Hive boxes (chats, messages, connection_requests, call_history, image_cache)
      debugPrint('🗑️ Clearing all Hive boxes...');
      final hiveBoxNames = [
        'chats',
        'messages',
        'connection_requests',
        'call_history',
        'image_cache',
        'peer_identities',
      ];
      for (final boxName in hiveBoxNames) {
        try {
          if (Hive.isBoxOpen(boxName)) {
            await Hive.box(boxName).clear();
          } else {
            final box = await Hive.openBox(boxName);
            await box.clear();
          }
          debugPrint('✅ $boxName box cleared');
        } catch (e) {
          debugPrint('⚠️ Failed to clear $boxName box: $e');
        }
      }

      // 3. Delete encrypted image files from disk
      debugPrint('🗑️ Deleting encrypted images from disk...');
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final secureImagesDir = Directory('${appDir.path}/secure_images');
        if (await secureImagesDir.exists()) {
          await secureImagesDir.delete(recursive: true);
          debugPrint('✅ Secure images directory deleted');
        }
      } catch (e) {
        debugPrint('⚠️ Failed to delete secure images: $e');
      }

      // 4. Delete all encryption keys from Flutter Secure Storage.
      // Every keychain service the app uses must be wiped — iOS scopes
      // deleteAll() to accountName, so each store is cleared explicitly:
      // identity keys (X25519/Ed25519/ML-KEM-768), peer-pin cipher key,
      // ratchet sessions, group sender keys, and the media-encryption
      // master key. Missing one would leave keys behind after "wipe".
      debugPrint('🗑️ Clearing Flutter Secure Storage...');
      const secureStores = [
        FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(accountName: 'PearMessagingSecureKey'),
        ),
        FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(accountName: 'VantIdentityKeys'),
        ),
        FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(accountName: 'VantPeerIdentityKeys'),
        ),
        FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(accountName: 'VantRatchetStore'),
        ),
        FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(accountName: 'VantGroupKeyStore'),
        ),
      ];
      for (final store in secureStores) {
        try {
          await store.deleteAll();
        } catch (e) {
          debugPrint('⚠️ Failed to clear a secure store: $e');
        }
      }
      debugPrint('✅ Flutter Secure Storage cleared');

      // 4b. Decrypted media temp files (FILE:/AUDIO: downloads) live in the
      // system temp dir — wipe them too.
      try {
        final tempDir = await getTemporaryDirectory();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
          debugPrint('✅ Temp directory wiped');
        }
      } catch (e) {
        debugPrint('⚠️ Failed to wipe temp dir: $e');
      }

      // 5. Close all Hive boxes and delete Hive data from disk
      debugPrint('🗑️ Closing and deleting Hive from disk...');
      try {
        await Hive.close();
        final appDir = await getApplicationDocumentsDirectory();
        final hiveDir = Directory(appDir.path);
        final hiveFiles = hiveDir.listSync().where(
              (f) => f.path.endsWith('.hive') || f.path.endsWith('.lock'),
            );
        for (final file in hiveFiles) {
          try {
            await file.delete();
          } catch (_) {}
        }
        debugPrint('✅ Hive files deleted from disk');
      } catch (e) {
        debugPrint('⚠️ Failed to delete Hive files: $e');
      }

      // 6. Clear all SharedPreferences
      debugPrint('🗑️ Clearing SharedPreferences...');
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      debugPrint('✅ SharedPreferences cleared');

      // 7. Platform-specific finalization
      if (Theme.of(context).platform == TargetPlatform.android) {
        // Generate new device ID so if user cancels uninstall, app starts fresh
        final freshPrefs = await SharedPreferences.getInstance();
        final newDeviceId = DeviceUtils.generateNewDeviceId();
        await freshPrefs.setString('device_id', newDeviceId);
        debugPrint('🆕 New device ID generated for fresh start: $newDeviceId');

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

      if (Theme.of(context).platform == TargetPlatform.iOS) {
        debugPrint('🍎 Setting iOS self-destruct flag...');
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
        snackPosition: SnackPosition.TOP,
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
              color: Colors.red.shade900.withValues(alpha: 0.3),
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
              'This will permanently delete ALL chats, messages, and app data.\n\nYou will get a NEW device identity — your contacts will need to re-add you to reach you again.\n\nThis action cannot be undone and data cannot be recovered.',
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
