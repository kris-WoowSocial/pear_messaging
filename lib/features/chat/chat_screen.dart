import 'dart:convert';
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
import '../../core/services/membership_service.dart';
import '../../routes/app_routes.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import '../../core/services/encryption_service.dart';
import '../../core/services/media_upload_service.dart';
import '../../core/utils/string_utils.dart';
import 'chat_settings_screen.dart';

class ChatScreen extends GetView<ChatController> {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final buildStart = DateTime.now();
    debugPrint(
        '⏱️ ChatScreen build() START: ${buildStart.millisecondsSinceEpoch}');
    debugPrint('🔧 DEBUG: ChatScreen build called');
    debugPrint('🔧 DEBUG: Display name: ${controller.displayName.value}');

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
          Get.offAllNamed('/chat-list');
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
                  controller.displayName.value.isNotEmpty
                      ? controller.displayName.value
                      : StringUtils.generateFriendlyName(
                          controller.recipientDeviceId),
                  style: const TextStyle(
                    fontSize: AppSizes.fontM,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  ),
                ),
              ),
              Obx(
                () => Text(
                  controller.recipientStatus.value,
                  style: TextStyle(
                    fontSize: AppSizes.fontS,
                    fontWeight: FontWeight.w600,
                    color: controller.recipientOnline.value ||
                            (controller.recipientLastSeen.value != null &&
                                DateTime.now()
                                        .difference(
                                            controller.recipientLastSeen.value!)
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
                    '📱 No navigation stack found, navigating to chat list');
                Get.offAllNamed('/chat-list');
              }
            },
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.black),
              onPressed: () {
                debugPrint('🔧 DEBUG: settings button pressed');
                Get.to(() => const ChatSettingsScreen());
              },
              tooltip: 'Chat Settings',
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
                                  Obx(() => controller.isLoadingMore.value
                                      ? const Padding(
                                          padding: EdgeInsets.all(8.0),
                                          child: Center(
                                            child: SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink()),
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
                                  'msg_${message.id}_${message.timestamp.millisecondsSinceEpoch}'),
                              message: message,
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
                  )
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
                    border:
                        Border(top: BorderSide(color: Colors.orange.shade200)),
                  ),
                  child: SafeArea(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.block,
                            color: Colors.orange.shade400, size: 20),
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
                          icon: Icon(Icons.lock_open,
                              color: Colors.orange.shade600, size: 20),
                          tooltip: 'Unblock User',
                        ),
                      ],
                    ),
                  ),
                );
              }

              // Normal input field
              return Column(mainAxisSize: MainAxisSize.min, children: [
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
                      child: const Center(
                        child: CircularProgressIndicator(),
                      ),
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
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      // Reply preview bar
                      Obx(() {
                        if (controller.isReplying &&
                            controller.replyToMessage.value != null) {
                          return ReplyPreviewBar(
                            replyTo: controller.replyToMessage.value!,
                            onCancel: controller.cancelReply,
                            onTap: () {
                              controller.scrollToMessage(
                                  controller.replyToMessage.value!.messageId);
                            },
                          );
                        }
                        return const SizedBox.shrink();
                      }),

                      // Message input row
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: controller.messageController,
                              focusNode: controller.messageFocusNode,
                              onChanged: controller.onTyping,
                              maxLines: 7,
                              minLines: 1,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              decoration: InputDecoration(
                                hintText: AppStrings.typeMessage,
                                filled: true,
                                fillColor: AppColors.background,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: AppSizes.paddingM,
                                  vertical: AppSizes.paddingS,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(
                                    AppSizes.radiusCircular,
                                  ),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSizes.paddingS),
                          // Attachment button
                          CircleAvatar(
                            backgroundColor: AppColors.warning,
                            child: IconButton(
                              icon: const Icon(
                                Icons.attach_file,
                                color: AppColors.surfaceDark,
                              ),
                              onPressed: () => _showAttachmentOptions(context),
                            ),
                          ),
                          const SizedBox(width: AppSizes.paddingS),

                          CircleAvatar(
                            backgroundColor: AppColors.primary,
                            child: IconButton(
                              icon: const Icon(
                                Icons.send,
                                color: AppColors.textLight,
                              ),
                              onPressed: controller.sendMessage,
                            ),
                          ),
                        ],
                      ),
                    ]),
                  ),
                )
              ]);
            }),
          ],
        ),
      ),
    );
    final buildEnd = DateTime.now();
    debugPrint(
        '⏱️ ChatScreen build() END: ${buildEnd.millisecondsSinceEpoch} (${buildEnd.difference(buildStart).inMicroseconds}μs)');
    return widget;
  }

  // void _showPopupMenu(BuildContext context) {
  //   final RenderBox overlay =
  //       Overlay.of(context).context.findRenderObject() as RenderBox;
  //   final RenderBox button = context.findRenderObject() as RenderBox;
  //   final Offset position =
  //       button.localToGlobal(Offset.zero, ancestor: overlay);

  //   showMenu<String>(
  //     context: context,
  //     position: RelativeRect.fromLTRB(
  //       position.dx,
  //       position.dy + button.size.height,
  //       overlay.size.width - 10,
  //       overlay.size.height - position.dy - button.size.height,
  //     ),
  //     items: [
  //       const PopupMenuItem(
  //         value: 'edit_user_name',
  //         child: Row(
  //           children: [
  //             Icon(Icons.edit_outlined, color: Colors.black, size: 20),
  //             SizedBox(width: 8),
  //             Text('Edit This User Name'),
  //           ],
  //         ),
  //       ),
  //       const PopupMenuDivider(),
  //       PopupMenuItem(
  //         value: 'block_user',
  //         child: Obx(
  //           () => Row(
  //             children: [
  //               Icon(
  //                 controller.isBlockedByMe.value
  //                     ? Icons.lock_open
  //                     : Icons.block,
  //                 color: controller.isBlockedByMe.value
  //                     ? Colors.green
  //                     : Colors.orange,
  //                 size: 20,
  //               ),
  //               const SizedBox(width: 8),
  //               Text(
  //                 controller.isBlockedByMe.value
  //                     ? 'Unblock User'
  //                     : 'Block User',
  //               ),
  //             ],
  //           ),
  //         ),
  //       ),
  //       const PopupMenuDivider(),
  //       const PopupMenuItem(
  //         value: 'report_user',
  //         child: Row(
  //           children: [
  //             Icon(Icons.flag_outlined, color: Colors.red, size: 20),
  //             SizedBox(width: 8),
  //             Text('Report User'),
  //           ],
  //         ),
  //       ),
  //       const PopupMenuDivider(),
  //       const PopupMenuItem(
  //         value: 'delete_chat',
  //         child: Row(
  //           children: [
  //             Icon(Icons.delete_outlined, color: Colors.red, size: 20),
  //             SizedBox(width: 8),
  //             Text('Delete Chat'),
  //           ],
  //         ),
  //       ),
  //       const PopupMenuDivider(),
  //       const PopupMenuItem(
  //         value: 'clear_chat',
  //         child: Row(
  //           children: [
  //             Icon(Icons.cleaning_services_outlined,
  //                 color: Colors.red, size: 20),
  //             SizedBox(width: 8),
  //             Text('Clear Chat'),
  //           ],
  //         ),
  //       ),
  //     ],
  //   ).then((value) {
  //     if (value != null) {
  //       _handlePopupMenuSelection(value);
  //     }
  //   });
  // }

  // void _handlePopupMenuSelection(String value) {
  //   debugPrint('🔧 DEBUG: _handlePopupMenuSelection called with value: $value');

  //   if (value == 'report_user') {
  //     ReportBottomSheet.show(
  //       targetType: 'user',
  //       targetId: controller.recipientDeviceId,
  //     );
  //   } else if (value == "delete_chat") {
  //     _showDeleteConfirmation(Get.context!);
  //   } else if (value == "clear_chat") {
  //     _showClearChatDialog(Get.context!);
  //   } else if (value == 'block_user') {
  //     if (controller.isBlockedByMe.value) {
  //       controller.unblockUser();
  //     } else {
  //       _showBlockConfirmation();
  //     }
  //   } else if (value == 'edit_user_name') {
  //     debugPrint('🔧 DEBUG: edit_user_name selected, calling _showEditSheet');
  //     _showEditSheet(Get.context!);
  //   } else if (value == 'send_100_messages') {
  //     _send100TestMessages();
  //   }
  // }

  // void _send100TestMessages() async {
  //   debugPrint('🐛 DEBUG: Sending 100 test messages...');

  //   final now = DateTime.now();
  //   final messages = [
  //     'Hello! How are you today?',
  //     'This is a test message',
  //     'Testing the chat performance',
  //     'How does this look?',
  //     'Another test message',
  //     'Checking the date headers',
  //     'This should work well',
  //     'Test message number',
  //     'Chat is working fine',
  //     'Performance test message',
  //     'Another day, another message',
  //     'Testing scrolling performance',
  //     'This is a longer message to see how it looks in the chat interface with more text content',
  //     'Short message',
  //     'Medium length test message here',
  //     'Testing date formatting',
  //     'Message with some numbers: 12345',
  //     'How about some emojis? 😊👍',
  //     'Testing the chat bubble layout',
  //     'Final test message for today',
  //   ];

  //   for (int i = 0; i < 100; i++) {
  //     // Create messages with different dates to test headers
  //     DateTime messageTime;
  //     String messageText;

  //     if (i < 20) {
  //       // Today's messages
  //       messageTime = now.subtract(Duration(minutes: (20 - i) * 30));
  //       messageText = '${messages[i % messages.length]} (Today)';
  //     } else if (i < 40) {
  //       // Yesterday's messages
  //       messageTime = now.subtract(Duration(days: 1, hours: (40 - i)));
  //       messageText = '${messages[i % messages.length]} (Yesterday)';
  //     } else if (i < 60) {
  //       // Messages from this week
  //       messageTime = now.subtract(Duration(days: (60 - i) ~/ 2));
  //       messageText =
  //           '${messages[i % messages.length]} (${now.subtract(Duration(days: (60 - i) ~/ 2)).weekday})';
  //     } else {
  //       // Older messages with full dates
  //       messageTime = now.subtract(Duration(days: (100 - i)));
  //       messageText =
  //           '${messages[i % messages.length]} (${(100 - i)} days ago)';
  //     }

  //     // Add small delay between messages to simulate real usage
  //     await Future.delayed(Duration(milliseconds: 10));

  //     // Create message entity
  //     final messageEntity = MessageEntity(
  //       id: 'test_msg_${DateTime.now().millisecondsSinceEpoch}_$i',
  //       chatId: controller.chatId,
  //       senderId: controller.myDeviceId,
  //       receiverId: controller.recipientDeviceId,
  //       content: messageText,
  //       timestamp: messageTime,
  //       status: MessageStatus.delivered,
  //       isMe: true,
  //       type: MessageType.text,
  //     );

  //     // Save to storage
  //     await controller.saveTestMessage(messageEntity);

  //     // Add to UI
  //     final chatMessage = ChatMessageModel.fromEntity(messageEntity);
  //     controller.messages
  //         .insert(0, chatMessage); // Insert at beginning for newest first
  //   }

  //   debugPrint('🐛 DEBUG: Sent 100 test messages successfully!');

  //   // Show success message
  //   Get.snackbar(
  //     'Test Complete',
  //     'Sent 100 messages with different dates',
  //     snackPosition: SnackPosition.BOTTOM,
  //     backgroundColor: Colors.blue.shade100,
  //     colorText: Colors.blue.shade800,
  //   );
  // }

  void _showAttachmentOptions(BuildContext context) {
    // Check membership before showing attachment options
    if (Get.isRegistered<MembershipService>()) {
      final membershipService = Get.find<MembershipService>();
      if (!membershipService.canShareMedia) {
        Get.toNamed(AppRoutes.membership);
        return;
      }
    }

    final ImagePicker imagePicker = ImagePicker();

    Get.bottomSheet(
      Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Text(
              'Send Photo',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Camera option
                _buildAttachmentOption(
                  icon: Icons.camera_alt,
                  label: 'Camera',
                  color: Colors.blue,
                  onTap: () async {
                    Get.back();
                    await _pickAndSendImage(imagePicker, ImageSource.camera);
                  },
                ),
                // Gallery option
                _buildAttachmentOption(
                  icon: Icons.photo_library,
                  label: 'Gallery',
                  color: Colors.green,
                  onTap: () async {
                    Get.back();
                    await _pickAndSendImage(imagePicker, ImageSource.gallery);
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
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
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[700])),
        ],
      ),
    );
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
          '🔧 DEBUG: Auto-opening edit sheet for new conversation with default username');

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
        '🔧 DEBUG: Current display name: ${controller.displayName.value}');
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
          '🔧 DEBUG: Preventing automatic edit sheet opening during initialization');
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
                    child: Text('Edit Contact',
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
                  height: AppSizes.paddingS), // Add some padding at bottom
            ],
          ),
        ),
      ),
      isScrollControlled:
          true, // Allow sheet to be scrollable and handle keyboard
    );
  }

  // void _showDeleteConfirmation(BuildContext context) {
  //   Get.dialog(
  //     AlertDialog(
  //       title: const Text('Delete Chat'),
  //       content: const Text(
  //           'Are you sure you want to delete this chat? This action cannot be undone.'),
  //       actions: [
  //         TextButton(
  //           onPressed: () => Get.back(),
  //           child: const Text('Cancel'),
  //         ),
  //         TextButton(
  //           onPressed: () {
  //             Get.back();
  //             controller.deleteChat();
  //           },
  //           style: TextButton.styleFrom(foregroundColor: Colors.red),
  //           child: const Text('Delete'),
  //         ),
  //       ],
  //     ),
  //   );
  // }

  // void _showBlockConfirmation() {
  //   Get.dialog(
  //     Dialog(
  //       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
  //       child: Container(
  //         padding: const EdgeInsets.all(24),
  //         decoration: BoxDecoration(
  //           borderRadius: BorderRadius.circular(20),
  //           color: Colors.white,
  //         ),
  //         child: Column(
  //           mainAxisSize: MainAxisSize.min,
  //           children: [
  //             Container(
  //               width: 70,
  //               height: 70,
  //               decoration: BoxDecoration(
  //                 color: Colors.orange.shade100,
  //                 shape: BoxShape.circle,
  //               ),
  //               child: Icon(
  //                 Icons.block,
  //                 size: 36,
  //                 color: Colors.orange.shade700,
  //               ),
  //             ),
  //             const SizedBox(height: 20),
  //             Text(
  //               'Block User',
  //               style: Get.textTheme.headlineSmall?.copyWith(
  //                 fontWeight: FontWeight.bold,
  //                 color: Colors.grey.shade800,
  //               ),
  //             ),
  //             const SizedBox(height: 12),
  //             Text(
  //               'Blocked users will no longer be able to send you messages. You can unblock them anytime.',
  //               style: Get.textTheme.bodyMedium?.copyWith(
  //                 color: Colors.grey.shade600,
  //                 height: 1.4,
  //               ),
  //               textAlign: TextAlign.center,
  //             ),
  //             const SizedBox(height: 24),
  //             Row(
  //               children: [
  //                 Expanded(
  //                   child: OutlinedButton(
  //                     onPressed: () => Get.back(),
  //                     style: OutlinedButton.styleFrom(
  //                       padding: const EdgeInsets.symmetric(vertical: 12),
  //                       shape: RoundedRectangleBorder(
  //                         borderRadius: BorderRadius.circular(10),
  //                       ),
  //                     ),
  //                     child: const Text('Cancel'),
  //                   ),
  //                 ),
  //                 const SizedBox(width: 12),
  //                 Expanded(
  //                   child: ElevatedButton(
  //                     onPressed: () {
  //                       Get.back();
  //                       controller.blockUser();
  //                     },
  //                     style: ElevatedButton.styleFrom(
  //                       backgroundColor: Colors.orange.shade600,
  //                       foregroundColor: Colors.white,
  //                       padding: const EdgeInsets.symmetric(vertical: 12),
  //                       shape: RoundedRectangleBorder(
  //                         borderRadius: BorderRadius.circular(10),
  //                       ),
  //                     ),
  //                     child: const Text('Block'),
  //                   ),
  //                 ),
  //               ],
  //             ),
  //           ],
  //         ),
  //       ),
  //     ),
  //   );
  // }

  // void _showClearChatDialog(BuildContext context) {
  //   Get.dialog(
  //     Dialog(
  //       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
  //       child: Container(
  //         padding: const EdgeInsets.all(24),
  //         decoration: BoxDecoration(
  //           borderRadius: BorderRadius.circular(20),
  //           color: Colors.white,
  //         ),
  //         child: Column(
  //           mainAxisSize: MainAxisSize.min,
  //           children: [
  //             Container(
  //               width: 70,
  //               height: 70,
  //               decoration: BoxDecoration(
  //                 color: Colors.orange.shade100,
  //                 shape: BoxShape.circle,
  //               ),
  //               child: Icon(
  //                 Icons.clear_all,
  //                 size: 36,
  //                 color: Colors.orange.shade700,
  //               ),
  //             ),
  //             const SizedBox(height: 20),
  //             Text(
  //               'Clear All Messages',
  //               style: Get.textTheme.headlineSmall?.copyWith(
  //                 fontWeight: FontWeight.bold,
  //                 color: Colors.grey.shade800,
  //               ),
  //             ),
  //             const SizedBox(height: 12),
  //             Text(
  //               'This will permanently delete all messages in this chat. This action cannot be undone.',
  //               style: Get.textTheme.bodyMedium?.copyWith(
  //                 color: Colors.grey.shade600,
  //                 height: 1.4,
  //               ),
  //               textAlign: TextAlign.center,
  //             ),
  //             const SizedBox(height: 24),
  //             Row(
  //               children: [
  //                 Expanded(
  //                   child: OutlinedButton(
  //                     onPressed: () => Get.back(),
  //                     style: OutlinedButton.styleFrom(
  //                       padding: const EdgeInsets.symmetric(vertical: 12),
  //                       shape: RoundedRectangleBorder(
  //                         borderRadius: BorderRadius.circular(10),
  //                       ),
  //                     ),
  //                     child: const Text('Cancel'),
  //                   ),
  //                 ),
  //                 const SizedBox(width: 12),
  //                 Expanded(
  //                   child: ElevatedButton(
  //                     onPressed: () => _clearChatMessages(),
  //                     style: ElevatedButton.styleFrom(
  //                       backgroundColor: Colors.orange.shade600,
  //                       foregroundColor: Colors.white,
  //                       padding: const EdgeInsets.symmetric(vertical: 12),
  //                       shape: RoundedRectangleBorder(
  //                         borderRadius: BorderRadius.circular(10),
  //                       ),
  //                     ),
  //                     child: const Text('Clear All'),
  //                   ),
  //                 ),
  //               ],
  //             ),
  //           ],
  //         ),
  //       ),
  //     ),
  //   );
  // }

  // void _clearChatMessages() async {
  //   // Show progress animation
  //   Get.back(); // Close dialog

  //   // Show loading dialog with progress
  //   Get.dialog(
  //     Dialog(
  //       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
  //       child: Container(
  //         padding: const EdgeInsets.all(24),
  //         decoration: BoxDecoration(
  //           borderRadius: BorderRadius.circular(20),
  //           color: Colors.white,
  //         ),
  //         child: Column(
  //           mainAxisSize: MainAxisSize.min,
  //           children: [
  //             const CircularProgressIndicator(
  //               valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
  //             ),
  //             const SizedBox(height: 20),
  //             Text(
  //               'Clearing messages...',
  //               style: Get.textTheme.bodyLarge?.copyWith(
  //                 fontWeight: FontWeight.w500,
  //               ),
  //             ),
  //           ],
  //         ),
  //       ),
  //     ),
  //     barrierDismissible: false,
  //   );

  //   // Simulate progress delay for better UX
  //   await Future.delayed(const Duration(milliseconds: 1500));

  //   // Clear messages through controller
  //   await controller.clearChatMessages();

  //   // Close loading dialog
  //   Get.back();

  //   // Show success message
  //   Get.snackbar(
  //     'Success',
  //     'All messages have been cleared',
  //     snackPosition: SnackPosition.BOTTOM,
  //     backgroundColor: Colors.green.shade100,
  //     colorText: Colors.green.shade800,
  //   );
  // }

  Future<void> _pickAndSendImage(ImagePicker picker, ImageSource source) async {
    String? pendingMsgId;
    try {
      final XFile? pickedFile = await picker.pickImage(source: source);
      if (pickedFile == null) return;

      // Step 1: Compress (runs natively — won't block UI)
      final compressedBytes = await _compressImageBytes(pickedFile.path);
      if (compressedBytes.isEmpty) {
        Get.snackbar('Error', 'Failed to process image',
            snackPosition: SnackPosition.BOTTOM,
            backgroundColor: Colors.red.shade100,
            colorText: Colors.red.shade800);
        return;
      }

      // Step 2: Add bubble immediately so user sees it with upload progress
      pendingMsgId =
          await controller.createPendingImageMessage(compressedBytes);
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

  /// Format date like WhatsApp: Today, Yesterday, day names for last week, then full dates
  String _formatDateHeader(DateTime messageDate) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay =
        DateTime(messageDate.year, messageDate.month, messageDate.day);

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
        'Sunday'
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
          '🔒 Messages and photos in this chat are end-to-end encrypted and peer-to-peer, with no servers in between. Only the people in this chat can read or share them. We are physically incapable of complying with data requests from third parties or government agencies. Our answer to every request is simple: The data does not exist.',
          style: TextStyle(
            fontSize: 12,
            color: Colors.black,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
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
            '🔧 Compression quality $quality: ${compressed.length} bytes');
        if (compressed.length <= 150 * 1024) {
          debugPrint(
              '✅ Image compressed to ${compressed.length} bytes (≤150KB)');
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
