import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:pear_messaging/core/constants/app_colors.dart';
import 'package:pear_messaging/core/constants/app_sizes.dart';
import 'package:pear_messaging/core/constants/app_strings.dart';
import 'package:pear_messaging/core/widgets/url_preview_widget.dart';
import 'package:pear_messaging/features/chat/chat_controller.dart';
import 'package:pear_messaging/features/chat/chat_message_bubble.dart';
import 'package:pear_messaging/features/chat/widgets/reply_preview_bar.dart';
import 'package:pear_messaging/features/call/call_controller.dart';
import '../../core/services/feature_flag_service.dart';
import '../../core/services/membership_service.dart';
import '../../routes/app_routes.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import '../../core/services/encryption_service.dart';
import '../../core/services/media_upload_service.dart';
import 'package:social_media_recorder/audio_encoder_type.dart';
import 'package:social_media_recorder/screen/social_media_recorder.dart';
import '../../core/utils/string_utils.dart';
import 'chat_settings_screen.dart';
import '../groups/group_settings_screen.dart';

class ChatScreen extends GetView<ChatController> {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final buildStart = DateTime.now();
    debugPrint(
      '⏱️ ChatScreen build() START: ${buildStart.millisecondsSinceEpoch}',
    );
    debugPrint('🔧 DEBUG: ChatScreen build called');
    debugPrint('🔧 DEBUG: Display name: ${controller.displayName.value}');
    debugPrint('🔧 DEBUG: Conversation ID: ${controller.displayName.value}');
    debugPrint(
      '🔧 DEBUG: Recipient device ID: ${controller.recipientDeviceId}',
    );
    // Check if this is a new conversation that needs username setup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndAutoOpenEditSheet();
    });

    final widget = PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;

        // Check if we can navigate back in the navigation stack
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        } else {
          // No navigation stack - navigate to chat list as fallback
          debugPrint('📱 No navigation stack found, navigating to chat list');
          Get.offAllNamed('/main');
        }
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Obx(
                () => Text(
                  controller.isGroup
                      ? controller.displayName.value
                      : (controller.displayName.value.isNotEmpty &&
                              controller.recipientDeviceId !=
                                  controller.displayName.value)
                          ? controller.displayName.value
                          : StringUtils.generateFriendlyName(
                              controller.recipientDeviceId,
                            ),
                  style: const TextStyle(
                    fontSize: AppSizes.fontM,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  ),
                ),
              ),
              Obx(
                () => controller.isGroup
                    ? Text(
                        controller.groupMemberCount.value > 0
                            ? '${controller.groupMemberCount.value} members'
                            : 'Group',
                        style: const TextStyle(
                          fontSize: AppSizes.fontS,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey,
                        ),
                      )
                    : Text(
                        controller.recipientStatus.value,
                        style: TextStyle(
                          fontSize: AppSizes.fontS,
                          fontWeight: FontWeight.w600,
                          color: controller.recipientOnline.value ||
                                  (controller.recipientLastSeen.value != null &&
                                      DateTime.now()
                                              .difference(
                                                controller
                                                    .recipientLastSeen.value!,
                                              )
                                              .inHours <
                                          24)
                              ? Colors.green
                              : Colors.grey,
                        ),
                      ),
              ),
            ],
          ),
          centerTitle: false,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.black),
            onPressed: () {
              // Check if we can navigate back in the navigation stack
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              } else {
                // No navigation stack - navigate to chat list as fallback
                debugPrint(
                  '📱 No navigation stack found, navigating to chat list',
                );
                Get.offAllNamed('/main');
              }
            },
          ),
          actions: [
            if (!controller.isGroup)
              IconButton(
                icon: const Icon(Icons.call, color: Colors.black),
                onPressed: () {
                  debugPrint('📞 Call button pressed');
                  _startAudioCall();
                },
                tooltip: 'Audio Call',
              ),
            if (!controller.isGroup &&
                Get.isRegistered<FeatureFlagService>() &&
                Get.find<FeatureFlagService>().videoCalling.value)
              IconButton(
                icon: const Icon(Icons.videocam, color: Colors.black),
                onPressed: () {
                  debugPrint('📞 Video call button pressed');
                  _startVideoCall();
                },
                tooltip: 'Video Call',
              ),
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.black),
              onPressed: () {
                debugPrint('🔧 DEBUG: settings button pressed');
                if (controller.isGroup) {
                  Get.to(() => const GroupSettingsScreen());
                } else {
                  Get.to(() => const ChatSettingsScreen());
                }
              },
              tooltip: controller.isGroup ? 'Group Settings' : 'Chat Settings',
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Obx(() {
                      if (controller.messages.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _buildChatHeader(),
                              const SizedBox(height: 16),
                              const Text(
                                'No messages yet. Start a conversation!',
                                style: TextStyle(color: Colors.black),
                              ),
                            ],
                          ),
                        );
                      }

                      // Build the complete items list with headers
                      final itemsList = _buildItemsListWithHeaders();

                      return NotificationListener<ScrollNotification>(
                        onNotification: (scrollInfo) {
                          // Load more messages when scrolled near the top (oldest messages)
                          // With reverse:true, maxScrollExtent = top (oldest)
                          if (scrollInfo.metrics.pixels >=
                              scrollInfo.metrics.maxScrollExtent - 200) {
                            controller.loadMoreMessages();
                          }
                          return false;
                        },
                        child: ListView.builder(
                          controller: controller.scrollController,
                          reverse: true,
                          padding: const EdgeInsets.all(AppSizes.paddingM),
                          itemCount: itemsList.length + 1,
                          itemBuilder: (context, index) {
                            // With reverse=true: index 0 = bottom (newest)
                            // Last index = top (header)
                            if (index == itemsList.length) {
                              return Column(
                                children: [
                                  _buildChatHeader(),
                                  // Show loading indicator when loading more
                                  Obx(
                                    () => controller.isLoadingMore.value
                                        ? const Padding(
                                            padding: EdgeInsets.all(8.0),
                                            child: Center(
                                              child: SizedBox(
                                                width: 24,
                                                height: 24,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                ),
                                              ),
                                            ),
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                                ],
                              );
                            }

                            final item = itemsList[index];
                            if (item['isHeader'] == true) {
                              return _buildDateHeader(item['text'] as String);
                            }

                            final messageIndex = item['messageIndex'] as int;
                            final message = controller.messages[messageIndex];
                            return ChatMessageBubble(
                              key: ValueKey(
                                'msg_${message.id}_${message.timestamp.millisecondsSinceEpoch}',
                              ),
                              message: message,
                              isGroup: controller.isGroup,
                            );
                          },
                        ),
                      );
                    }),
                  ),
                  Positioned(
                    bottom: 10,
                    right: 10,
                    child: Obx(() {
                      // Show floating button when not at bottom (scrolled up to read old messages)
                      // Note: With reverse: true, 0.0 = bottom (newest), maxScrollExtent = top (oldest)
                      final scrollPos = controller.scrollPosition.value;

                      // Show button when scrolled away from bottom (newest messages)
                      // With reverse: true, bottom is 0.0, so we check if we're not near 0
                      final isScrolledUp = scrollPos > 50.0;

                      return isScrolledUp
                          ? FloatingActionButton(
                              mini: true,
                              backgroundColor: AppColors.surface,
                              child: const Icon(
                                Icons.keyboard_double_arrow_down,
                                color: Colors.black,
                                size: 20,
                              ),
                              onPressed: () {
                                controller.scrollToBottom();
                              },
                            )
                          : const SizedBox.shrink(); // Hide when at bottom
                    }),
                  ),
                ],
              ),
            ),
            Obx(() {
              // Check if user is blocked by recipient
              if (controller.hasBlockedMe.value) {
                // Recipient blocked the current user
                return Container(
                  padding: const EdgeInsets.all(AppSizes.paddingM),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    border: Border(top: BorderSide(color: Colors.red.shade200)),
                  ),
                  child: SafeArea(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.block, color: Colors.red.shade400, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          "You can't reply to this conversation.",
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              // Check if current user has blocked the recipient
              if (controller.isBlockedByMe.value) {
                // Current user blocked the recipient
                return Container(
                  padding: const EdgeInsets.all(AppSizes.paddingM),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    border: Border(
                      top: BorderSide(color: Colors.orange.shade200),
                    ),
                  ),
                  child: SafeArea(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.block,
                          color: Colors.orange.shade400,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            "You have blocked this user. Unblock to send messages.",
                            style: TextStyle(
                              color: Colors.orange.shade700,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () {
                            controller.unblockUser();
                          },
                          icon: Icon(
                            Icons.lock_open,
                            color: Colors.orange.shade600,
                            size: 20,
                          ),
                          tooltip: 'Unblock User',
                        ),
                      ],
                    ),
                  ),
                );
              }

              // Normal input field
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // URL Preview (shown while typing)
                  Obx(() {
                    if (controller.currentUrlPreview.value != null) {
                      return Container(
                        margin: const EdgeInsets.only(
                          left: AppSizes.paddingM,
                          right: AppSizes.paddingM,
                          bottom: AppSizes.paddingS,
                        ),
                        child: UrlPreviewWidget(
                          preview: controller.currentUrlPreview.value!,
                          isMe: true,
                        ),
                      );
                    }

                    // Loading state
                    if (controller.isPreviewLoading.value) {
                      return Container(
                        margin: const EdgeInsets.only(
                          left: AppSizes.paddingM,
                          right: AppSizes.paddingM,
                          bottom: AppSizes.paddingS,
                        ),
                        height: 100,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: const Center(child: CircularProgressIndicator()),
                      );
                    }

                    return const SizedBox.shrink();
                  }),

                  // Input field container
                  Container(
                    padding: const EdgeInsets.all(AppSizes.paddingM),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.shadow,
                          blurRadius: 4,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
                    child: SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Reply preview bar
                          Obx(() {
                            if (controller.isReplying &&
                                controller.replyToMessage.value != null) {
                              return ReplyPreviewBar(
                                replyTo: controller.replyToMessage.value!,
                                onCancel: controller.cancelReply,
                                onTap: () {
                                  controller.scrollToMessage(
                                    controller.replyToMessage.value!.messageId,
                                  );
                                },
                              );
                            }
                            return const SizedBox.shrink();
                          }),

                          // Message input / recording area
                          _buildMessageInput(context),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }),
          ],
        ),
      ),
    );
    final buildEnd = DateTime.now();
    debugPrint(
      '⏱️ ChatScreen build() END: ${buildEnd.millisecondsSinceEpoch} (${buildEnd.difference(buildStart).inMicroseconds}μs)',
    );
    return widget;
  }

  void _showAttachmentOptions(BuildContext context) {
    // Check membership before showing attachment options
    if (Get.isRegistered<MembershipService>()) {
      final membershipService = Get.find<MembershipService>();
      if (!membershipService.canShareMedia) {
        Get.toNamed(AppRoutes.stripeSubscription);
        return;
      }
    }

    final ImagePicker imagePicker = ImagePicker();

    Get.bottomSheet(
      SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // First row of options
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildAttachmentOption(
                    icon: Icons.insert_drive_file,
                    label: 'Document',
                    color: const Color(0xFF7F66FF),
                    onTap: () async {
                      Get.back();
                      await _pickAndSendDocument();
                    },
                  ),
                  _buildAttachmentOption(
                    icon: Icons.camera_alt,
                    label: 'Camera',
                    color: const Color(0xFFFF2E74),
                    onTap: () async {
                      Get.back();
                      await _pickAndSendImage(imagePicker, ImageSource.camera);
                    },
                  ),
                  _buildAttachmentOption(
                    icon: Icons.photo,
                    label: 'Gallery',
                    color: const Color(0xFFC861F9),
                    onTap: () async {
                      Get.back();
                      await _pickAndSendImage(imagePicker, ImageSource.gallery);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
      isScrollControlled: true,
    );
  }

  Widget _buildAttachmentOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[700],
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// File extensions that are already compressed — gzip won't help and just
  /// wastes CPU time, slowing down the send.
  static const Set<String> _preCompressedExtensions = {
    'pdf',
    'zip',
    'rar',
    '7z',
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'mp4',
    'mp3',
    'mov',
    'avi',
    'mkv',
    'docx',
    'xlsx',
    'pptx',
    'apk',
  };

  /// Pick a document/file and send it through the media upload pipeline.
  Future<void> _pickAndSendDocument() async {
    String? pendingMsgId;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final fileName = file.name;
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null || bytes.isEmpty) {
        Get.snackbar(
          'Error',
          'Could not read the selected file.',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.shade100,
          colorText: Colors.red.shade800,
        );
        return;
      }

      final fileSize = bytes.length;
      final rawBytes = Uint8List.fromList(bytes);

      // Hard limit: 10 MB
      if (fileSize > 10 * 1024 * 1024) {
        Get.snackbar(
          'File Too Large',
          'Please select a file smaller than 10 MB.',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.shade100,
          colorText: Colors.red.shade800,
        );
        return;
      }

      // Create a pending file message with metadata; cache raw bytes locally
      // so the sender can preview/open it instantly without re-downloading.
      pendingMsgId = await controller.createPendingFileMessage(
        fileName: fileName,
        fileSize: fileSize,
        localBytes: rawBytes,
      );
      if (pendingMsgId == null) return;

      // If file > 5 MB and not already a compressed format, try gzip
      // (off the main thread so the UI stays responsive).
      final ext =
          fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
      bool isCompressed = false;
      Uint8List dataToSend = rawBytes;
      if (fileSize > 5 * 1024 * 1024 &&
          !_preCompressedExtensions.contains(ext)) {
        debugPrint(
            '📦 Document > 5 MB ($fileSize bytes), trying gzip compression...');
        final compressedBytes = await compute(_gzipIfBeneficial, rawBytes);
        if (compressedBytes != null) {
          dataToSend = compressedBytes;
          isCompressed = true;
          debugPrint('📦 Compressed: $fileSize -> ${dataToSend.length} bytes');
        } else {
          debugPrint('📦 Compression not beneficial, using original');
        }
      }

      // Encrypt off the main thread to avoid UI jank on large files.
      final encryptedBlob = await compute(_encryptFileBlob, dataToSend);

      final token = await MediaUploadService.uploadImage(
        encryptedBlob,
        onProgress: (progress) {
          controller.uploadProgressMap[pendingMsgId]?.value = progress;
        },
      );

      await controller.finalizeFileMessage(
        messageId: pendingMsgId,
        token: token,
        fileName: fileName,
        fileSize: fileSize,
        isCompressed: isCompressed,
      );
      debugPrint(
          '✅ Document sent via media server, token=$token, name=$fileName');
    } catch (e) {
      debugPrint('❌ Error sending document: $e');
      if (pendingMsgId != null) {
        controller.uploadProgressMap.remove(pendingMsgId);
        controller.messages.removeWhere((msg) => msg.id == pendingMsgId);
      }

      String errorMessage = 'Failed to send file. Please try again.';
      if (e.toString().contains('413') ||
          e.toString().toLowerCase().contains('too large')) {
        errorMessage =
            'File is too large for the server. Please choose a smaller file.';
      } else if (e.toString().contains('timeout')) {
        errorMessage =
            'Upload timed out. Please check your connection and try again.';
      } else if (e.toString().contains('Network')) {
        errorMessage = 'Network error. Please check your internet connection.';
      }

      Get.snackbar(
        'Upload Failed',
        errorMessage,
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
        duration: const Duration(seconds: 4),
      );
    }
  }

  void _checkAndAutoOpenEditSheet() {
    debugPrint('🔧 DEBUG: Checking if auto-open edit sheet is needed');
    debugPrint('🔧 DEBUG: Display name: "${controller.displayName.value}"');
    debugPrint('🔧 DEBUG: Messages count: ${controller.messages.length}');

    // Check conditions for auto-opening edit sheet:
    // 1. Display name starts with "@user" (not saved in local storage)
    // 2. This is a new conversation (first message only or no messages yet)
    // 3. User just started the conversation

    final displayName = controller.displayName.value.trim();
    final isDefaultUsername =
        displayName.startsWith('@user') || displayName == 'Unknown';
    final isNewConversation = controller.messages.length <= 1; // 0 or 1 message

    debugPrint('🔧 DEBUG: isDefaultUsername: $isDefaultUsername');
    debugPrint('🔧 DEBUG: isNewConversation: $isNewConversation');

    if (isDefaultUsername && isNewConversation) {
      debugPrint(
        '🔧 DEBUG: Auto-opening edit sheet for new conversation with default username',
      );

      // Add a small delay to ensure the UI is fully rendered
      Future.delayed(const Duration(milliseconds: 500), () {
        if (Get.context != null) {
          _showEditSheet(Get.context!);
        }
      });
    } else {
      debugPrint('🔧 DEBUG: Not auto-opening edit sheet - conditions not met');
    }
  }

  void _showEditSheet(BuildContext context) {
    // Add debug logging to track when this is called
    debugPrint('🔧 DEBUG: _showEditSheet called');
    debugPrint(
      '🔧 DEBUG: Current display name: ${controller.displayName.value}',
    );
    debugPrint('🔧 DEBUG: Stack trace: ${StackTrace.current}');

    // Check if this might be an automatic call for new connections
    final stackTrace = StackTrace.current;
    final stackTraceString = stackTrace.toString();

    // If this is called automatically during initialization from build/onInit, prevent it
    // But allow it if called from _checkAndAutoOpenEditSheet (which has a delay)
    if (controller.displayName.value == 'Unknown' &&
        (stackTraceString.contains('onInit') ||
            stackTraceString.contains('build') ||
            stackTraceString.contains('initState')) &&
        !stackTraceString.contains('_checkAndAutoOpenEditSheet')) {
      debugPrint(
        '🔧 DEBUG: Preventing automatic edit sheet opening during initialization',
      );
      return;
    }

    final nameController = TextEditingController(
      text: controller.displayName.value,
    );

    Get.bottomSheet(
      SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.all(AppSizes.paddingL),
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
                    child: Text(
                      'Edit Contact',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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
                    borderSide: const BorderSide(
                      color: AppColors.primary,
                      width: 2,
                    ),
                  ),
                ),
                // Auto-select all text when field gets focus
                onTap: () {
                  nameController.selection = TextSelection(
                    baseOffset: 0,
                    extentOffset: nameController.text.length,
                  );
                },
                onSubmitted: (value) {
                  final newName = value.trim();
                  if (newName.isNotEmpty) {
                    controller.updateDisplayName(newName);
                    Get.back();
                  }
                },
              ),
              const SizedBox(height: AppSizes.paddingL),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    // Unfocus the keyboard first
                    FocusScope.of(context).unfocus();

                    final newName = nameController.text.trim();
                    debugPrint("object 2");
                    if (newName.isNotEmpty) {
                      debugPrint("object 1");
                      controller.updateDisplayName(newName);
                      debugPrint("object 3");

                      // Try multiple ways to close the sheet
                      debugPrint("object 4 - attempting to close sheet");

                      // Method 1: Try Get.back()
                      try {
                        Get.back();
                        debugPrint("object 4a - Get.back() called");
                      } catch (e) {
                        debugPrint("object 4a - Get.back() failed: $e");
                      }

                      // Method 2: Try Navigator.pop() as fallback
                      try {
                        if (Navigator.canPop(context)) {
                          Navigator.pop(context);
                          debugPrint("object 4b - Navigator.pop() called");
                        }
                      } catch (e) {
                        debugPrint("object 4b - Navigator.pop() failed: $e");
                      }
                    } else {
                      // Show error if name is empty
                      Get.snackbar(
                        'Error',
                        'Please enter a name',
                        snackPosition: SnackPosition.BOTTOM,
                        backgroundColor: Colors.red.shade100,
                        colorText: Colors.red.shade800,
                      );
                    }
                  },
                  child: const Text('Save'),
                ),
              ),
              const SizedBox(
                height: AppSizes.paddingS,
              ), // Add some padding at bottom
            ],
          ),
        ),
      ),
      isScrollControlled:
          true, // Allow sheet to be scrollable and handle keyboard
    );
  }

  Future<void> _pickAndSendImage(ImagePicker picker, ImageSource source) async {
    String? pendingMsgId;
    try {
      // Request permission before picking image (required for Samsung gallery)
      if (source == ImageSource.gallery) {
        debugPrint('📸 Checking gallery permission for source: $source');
        final permissionStatus = await _requestGalleryPermission();
        if (permissionStatus != PermissionStatus.granted) {
          debugPrint('❌ Gallery permission denied: $permissionStatus');
          Get.snackbar(
            'Permission Required',
            'Please allow access to photos to send images.',
            snackPosition: SnackPosition.BOTTOM,
            backgroundColor: Colors.red.shade100,
            colorText: Colors.red.shade800,
          );
          return;
        }
        debugPrint('✅ Gallery permission granted');
      }

      debugPrint('📸 Picking image from source: $source');
      XFile? pickedFile;
      if (source == ImageSource.gallery) {
        // Use file_picker only for gallery for better Samsung compatibility
        pickedFile = await _pickImageWithFilePicker();
      } else {
        // For camera, use image_picker
        pickedFile = await picker.pickImage(source: source);
      }
      if (pickedFile == null) {
        debugPrint('⚠️ No image selected from picker');
        return;
      }

      debugPrint('📸 Image picked: ${pickedFile.path}');

      // Validate file exists and is readable
      final file = File(pickedFile.path);
      final exists = await file.exists();
      debugPrint('📸 File exists: $exists, path: ${pickedFile.path}');
      if (!exists) {
        debugPrint('❌ Picked file does not exist at path: ${pickedFile.path}');
        Get.snackbar(
          'Error',
          'Could not access selected image. Please try again.',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.shade100,
          colorText: Colors.red.shade800,
        );
        return;
      }

      // Step 1: Compress (runs natively — won't block UI)
      final compressedBytes = await _compressImageBytes(pickedFile.path);
      if (compressedBytes.isEmpty) {
        Get.snackbar(
          'Error',
          'Failed to process image',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.shade100,
          colorText: Colors.red.shade800,
        );
        return;
      }

      // Step 2: Add bubble immediately so user sees it with upload progress
      pendingMsgId = await controller.createPendingImageMessage(
        compressedBytes,
      );
      if (pendingMsgId == null) return;

      // Step 3: Encrypt + upload; progress goes directly into the bubble overlay
      final base64Image = base64Encode(compressedBytes);
      final encryptedBlob = EncryptionService.encryptMessage(base64Image);

      final token = await MediaUploadService.uploadImage(
        encryptedBlob,
        onProgress: (progress) {
          controller.uploadProgressMap[pendingMsgId]?.value = progress;
        },
      );

      // Step 4: Finalize bubble content + send token via socket
      await controller.finalizeImageMessage(pendingMsgId, token);
      debugPrint('✅ Image sent via media server, token=$token');
    } catch (e) {
      debugPrint('❌ Error sending image: $e');
      // Remove the pending bubble on failure
      if (pendingMsgId != null) {
        controller.uploadProgressMap.remove(pendingMsgId);
        controller.messages.removeWhere((msg) => msg.id == pendingMsgId);
      }

      String errorMessage = 'Failed to send image. Please try again.';
      if (e.toString().contains('timeout')) {
        errorMessage =
            'Upload timed out. Please check your connection and try again.';
      } else if (e.toString().contains('Network')) {
        errorMessage = 'Network error. Please check your internet connection.';
      } else if (e.toString().contains('1MB')) {
        errorMessage = 'Image too large. Please choose a smaller image.';
      } else if (e.toString().contains('permission') ||
          e.toString().contains('Permission')) {
        errorMessage = 'Permission denied. Please allow access to photos.';
      }

      Get.snackbar(
        'Upload Failed',
        errorMessage,
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
        duration: const Duration(seconds: 4),
      );
    }
  }

  /// Request appropriate gallery permission based on Android version
  Future<PermissionStatus> _requestGalleryPermission() async {
    try {
      // Android 13+ (API 33+) uses READ_MEDIA_IMAGES
      if (Platform.isAndroid) {
        final mediaImages = await Permission.photos.request();
        debugPrint('📸 Permission.photos status: $mediaImages');
        if (mediaImages.isGranted) return mediaImages;

        // Fallback for older Android versions
        final storage = await Permission.storage.request();
        debugPrint('📸 Permission.storage status: $storage');
        if (storage.isGranted) return storage;

        // Last resort: try media library
        final media = await Permission.mediaLibrary.request();
        debugPrint('📸 Permission.mediaLibrary status: $media');
        return media;
      }
      return PermissionStatus.granted;
    } catch (e) {
      debugPrint('❌ Error requesting gallery permission: $e');
      return PermissionStatus.denied;
    }
  }

  /// Image picker using file_picker for better Samsung compatibility
  Future<XFile?> _pickImageWithFilePicker() async {
    try {
      debugPrint('📸 Opening file_picker for image selection');
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        debugPrint('⚠️ file_picker returned null');
        return null;
      }
      final file = result.files.first;
      final path = file.path;
      if (path != null) {
        debugPrint('📸 file_picker selected: $path');
        return XFile(path);
      }
      // Fallback: save bytes to temp file if path is unavailable
      if (file.bytes != null) {
        final tempDir = await Directory.systemTemp.createTemp('vant_chat_');
        final tempFile = File(
            '${tempDir.path}/picked_image_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await tempFile.writeAsBytes(file.bytes!);
        debugPrint('📸 file_picker saved bytes to temp file: ${tempFile.path}');
        return XFile(tempFile.path);
      }
      debugPrint('⚠️ file_picker returned null path and no bytes');
      return null;
    } catch (e) {
      debugPrint('❌ file_picker error: $e');
      return null;
    }
  }

  /// Format date like WhatsApp: Today, Yesterday, day names for last week, then full dates
  String _formatDateHeader(DateTime messageDate) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(
      messageDate.year,
      messageDate.month,
      messageDate.day,
    );

    final difference = today.difference(messageDay).inDays;

    if (difference == 0) {
      return 'Today';
    } else if (difference == 1) {
      return 'Yesterday';
    } else if (difference > 1 && difference <= 7) {
      // Show day name for messages within the last week
      final dayNames = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      return dayNames[messageDay.weekday - 1];
    } else {
      // Show full date for older messages
      return '${messageDay.day}/${messageDay.month}/${messageDay.year}';
    }
  }

  /// Build date header widget
  Widget _buildDateHeader(String dateText) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(12.0),
          ),
          child: Text(
            dateText,
            style: TextStyle(
              fontSize: 12.0,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  /// Build the complete items list with headers in correct order for reverse=true
  List<Map<String, dynamic>> _buildItemsListWithHeaders() {
    final items = <Map<String, dynamic>>[];
    String? lastDateHeader;

    // Build in natural order (oldest to newest)
    for (int messageIndex = 0;
        messageIndex < controller.messages.length;
        messageIndex++) {
      final message = controller.messages[messageIndex];
      final dateHeader = _formatDateHeader(message.timestamp);

      // Add header before first message of each date group
      if (dateHeader != lastDateHeader) {
        items.add({'isHeader': true, 'text': dateHeader});
        lastDateHeader = dateHeader;
      }

      items.add({'isHeader': false, 'messageIndex': messageIndex});
    }

    // Reverse so that with ListView reverse=true, newest is at bottom
    // and date headers appear above their date group
    return items.reversed.toList();
  }

  Widget _buildChatHeader() {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          controller.isGroup
              ? '🔒 Messages and photos in this group are end-to-end encrypted. Only members of this group can read or share them.'
              : '🔒 Messages and photos in this chat are end-to-end encrypted and peer-to-peer, with no servers in between. Only the people in this chat can read or share them. We are physically incapable of complying with data requests from third parties or government agencies. Our answer to every request is simple: The data does not exist.',
          style: TextStyle(
            fontSize: 12,
            color: Colors.black,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// Start an audio call
  void _startAudioCall() {
    try {
      // Check membership before starting call
      if (Get.isRegistered<MembershipService>()) {
        final membershipService = Get.find<MembershipService>();
        if (!membershipService.canMakeCalls) {
          Get.toNamed(AppRoutes.stripeSubscription);
          return;
        }
      }

      // Get CallController
      if (!Get.isRegistered<CallController>()) {
        Get.put(CallController());
      }

      final callController = Get.find<CallController>();

      // Start call
      callController.startCall(controller.recipientDeviceId);

      // Navigate to outgoing call screen
      Get.toNamed('/call/outgoing', arguments: controller.recipientDeviceId);
    } catch (e) {
      debugPrint('❌ Failed to start audio call: $e');
      Get.snackbar(
        'Error',
        'Failed to start call',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  Future<void> _startVideoCall() async {
    try {
      if (Get.isRegistered<MembershipService>()) {
        final membershipService = Get.find<MembershipService>();
        if (!membershipService.canMakeCalls) {
          Get.toNamed(AppRoutes.stripeSubscription);
          return;
        }
      }

      if (!Get.isRegistered<CallController>()) {
        Get.put(CallController());
      }

      final callController = Get.find<CallController>();
      final success = await callController.startCall(
        controller.recipientDeviceId,
        isVideo: true,
      );
      if (success) Get.toNamed(callController.activeCallRoute);
    } catch (e) {
      debugPrint('❌ Failed to start video call: $e');
      Get.snackbar(
        'Error',
        'Failed to start video call',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  /// Build the WhatsApp-style message input with the attachment and mic
  /// buttons on the right. The attachment button hides while typing or
  /// recording.
  Widget _buildMessageInput(BuildContext context) {
    return _MessageInput(
      controller: controller,
      onAttachmentTap: () => _showAttachmentOptions(context),
      onAudioRecorded: _sendAudioRecording,
    );
  }

  /// Sends a voice recording produced by [SocialMediaRecorder] through the
  /// existing encrypted media upload pipeline.
  Future<void> _sendAudioRecording(File soundFile, String time) async {
    var durationMs = 0;
    try {
      final parts = time.split(':');
      if (parts.length == 2) {
        final minutes = int.tryParse(parts[0]) ?? 0;
        final seconds = int.tryParse(parts[1]) ?? 0;
        durationMs = ((minutes * 60) + seconds) * 1000;
      }
    } catch (_) {}

    String? pendingMsgId;
    try {
      final bytes = await soundFile.readAsBytes();
      if (bytes.isEmpty) return;

      // Placeholder waveform data until a real waveform is wired in.
      const waveform = '0.4,0.4,0.4,0.4,0.4';

      pendingMsgId = await controller.createPendingAudioMessage(
        duration: durationMs,
        waveformData: waveform,
        localBytes: bytes,
      );
      if (pendingMsgId == null) {
        await soundFile.delete();
        return;
      }

      final base64Audio = base64Encode(bytes);
      final encryptedBlob = EncryptionService.encryptMessage(base64Audio);

      final token = await MediaUploadService.uploadImage(
        encryptedBlob,
        onProgress: (progress) {
          controller.uploadProgressMap[pendingMsgId]?.value = progress;
        },
      );

      await controller.finalizeAudioMessage(
        messageId: pendingMsgId,
        token: token,
        duration: durationMs,
        waveformData: waveform,
      );
      debugPrint('✅ Audio sent via media server, token=$token');
    } catch (e) {
      debugPrint('❌ Error sending audio: $e');
      if (pendingMsgId != null) {
        controller.uploadProgressMap.remove(pendingMsgId);
        controller.messages.removeWhere((msg) => msg.id == pendingMsgId);
      }
      Get.snackbar(
        'Upload Failed',
        'Failed to send voice message. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
        duration: const Duration(seconds: 4),
      );
    } finally {
      if (await soundFile.exists()) {
        await soundFile.delete();
      }
    }
  }
}


/// Gzip-compresses [bytes] if doing so actually reduces the size.
/// Runs in a background isolate via [compute] to avoid blocking the UI
/// thread for large files.
Uint8List? _gzipIfBeneficial(Uint8List bytes) {
  final compressed = GZipCodec().encode(bytes);
  return compressed.length < bytes.length
      ? Uint8List.fromList(compressed)
      : null;
}

/// Base64-encodes and XOR-encrypts [bytes] for upload.
/// Runs in a background isolate via [compute] so encrypting large files
/// doesn't jank the UI thread.
String _encryptFileBlob(Uint8List bytes) {
  final base64Data = base64Encode(bytes);
  return EncryptionService.encryptMessage(base64Data);
}

/// Compresses image at [filePath] targeting ≤ 150 KB binary output (reduced from 250KB).
/// Must run on the main isolate — FlutterImageCompress uses platform channels.
Future<Uint8List> _compressImageBytes(String filePath) async {
  try {
    debugPrint('🔧 Starting image compression for: $filePath');

    // More aggressive quality reduction: stop as soon as we hit the 150 KB target
    for (final quality in [80, 65, 50, 35, 20, 10]) {
      final compressed = await FlutterImageCompress.compressWithFile(
        filePath,
        quality: quality,
        minWidth: 800, // Reduced from 1024
        minHeight: 800, // Reduced from 1024
      );
      if (compressed != null) {
        debugPrint(
          '🔧 Compression quality $quality: ${compressed.length} bytes',
        );
        if (compressed.length <= 150 * 1024) {
          debugPrint(
            '✅ Image compressed to ${compressed.length} bytes (≤150KB)',
          );
          return compressed;
        }
      }
    }

    // Last-resort: shrink dimensions aggressively
    final result = await FlutterImageCompress.compressWithFile(
      filePath,
      quality: 8, // Very aggressive
      minWidth: 400, // Much smaller
      minHeight: 400, // Much smaller
    );

    if (result != null) {
      debugPrint('⚠️ Final compression: ${result.length} bytes');
    } else {
      debugPrint('❌ Compression failed completely');
    }

      return result ?? Uint8List(0);
  } catch (e) {
    debugPrint('❌ Compression error: $e');
    return Uint8List(0);
  }
}

/// WhatsApp-style input row: text field on the left, attachment + mic buttons
/// on the right. Attachment hides while typing or recording; send appears
/// when there is text.
class _MessageInput extends StatefulWidget {
  final ChatController controller;
  final VoidCallback onAttachmentTap;
  final void Function(File soundFile, String time) onAudioRecorded;

  const _MessageInput({
    required this.controller,
    required this.onAttachmentTap,
    required this.onAudioRecorded,
  });

  @override
  State<_MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<_MessageInput> {
  bool _isRecording = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        TextField(
          controller: widget.controller.messageController,
          focusNode: widget.controller.messageFocusNode,
          onChanged: widget.controller.onTyping,
          maxLines: 7,
          minLines: 1,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          enableInteractiveSelection: true,
          selectionControls: MaterialTextSelectionControls(),
          decoration: InputDecoration(
            hintText: AppStrings.typeMessage,
            filled: true,
            fillColor: AppColors.background,
            contentPadding: const EdgeInsets.only(
              left: AppSizes.paddingM,
              right: 108,
              top: AppSizes.paddingS,
              bottom: AppSizes.paddingS,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(
                AppSizes.radiusCircular,
              ),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: Center(
            child: Obx(() {
              if (widget.controller.hasText.value) {
                return CircleAvatar(
                  backgroundColor: AppColors.primary,
                  child: IconButton(
                    icon: const Icon(
                      Icons.send,
                      color: AppColors.textLight,
                    ),
                    onPressed: widget.controller.sendMessage,
                  ),
                );
              }

              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_isRecording)
                    GestureDetector(
                      onTap: widget.onAttachmentTap,
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: AppColors.warning,
                        child: const Icon(
                          Icons.attach_file,
                          color: AppColors.surfaceDark,
                          size: 20,
                        ),
                      ),
                    ),
                  if (!_isRecording) const SizedBox(width: 4),
                  SocialMediaRecorder(
                    initRecordPackageWidth: 48,
                    fullRecordPackageHeight: 48,
                    radius: BorderRadius.circular(24),
                    recordIcon: Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.mic,
                        color: AppColors.textLight,
                        size: 20,
                      ),
                    ),
                    recordIconBackGroundColor: AppColors.primary,
                    startRecording: () => setState(() => _isRecording = true),
                    stopRecording: (_) => setState(() => _isRecording = false),
                    sendRequestFunction: (soundFile, time) {
                      setState(() => _isRecording = false);
                      widget.onAudioRecorded(soundFile, time);
                    },
                    onPermissionDenied: () async {
                      final status = await Permission.microphone.status;
                      if (status.isPermanentlyDenied) {
                        Get.snackbar(
                          'Microphone Permission',
                          'Please enable microphone access in app settings.',
                          snackPosition: SnackPosition.BOTTOM,
                          backgroundColor: Colors.red.shade100,
                          colorText: Colors.red.shade800,
                          mainButton: TextButton(
                            onPressed: openAppSettings,
                            child: const Text('Settings'),
                          ),
                        );
                      } else {
                        Get.snackbar(
                          'Permission Required',
                          'Microphone permission is needed to record voice messages.',
                          snackPosition: SnackPosition.BOTTOM,
                          backgroundColor: Colors.red.shade100,
                          colorText: Colors.red.shade800,
                        );
                      }
                    },
                    encode: AudioEncoderType.AAC,
                    slideToCancelText: ' Slide to cancel',
                    cancelText: 'Cancel',
                  ),
                ],
              );
            }),
          ),
        ),
      ],
    );
  }
}
