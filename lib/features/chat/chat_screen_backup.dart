// import 'dart:convert';
// import 'package:flutter/material.dart';
// import 'package:get/get.dart';
// import 'package:image_picker/image_picker.dart';
// import '../../core/constants/app_colors.dart';
// import '../../core/constants/app_sizes.dart';
// import '../../core/constants/app_strings.dart';
// import 'chat_controller.dart';
// import 'chat_message_bubble.dart';
// import '../../core/widgets/report_bottom_sheet.dart';

// class ChatScreen extends GetView<ChatController> {
//   const ChatScreen({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       backgroundColor: AppColors.background,
//       appBar: AppBar(
//         backgroundColor: AppColors.surface,
//         elevation: 0,
//         leading: IconButton(
//           icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
//           onPressed: () => Get.back(),
//         ),
//         title: Obx(() => Text(
//           controller.displayName.value,
//           style: const TextStyle(
//             color: AppColors.textPrimary,
//             fontSize: 18,
//             fontWeight: FontWeight.w600,
//           ),
//         )),
//         actions: [
//           PopupMenuButton<String>(
//             icon: const Icon(Icons.more_vert, color: AppColors.textPrimary),
//             onSelected: (value) {
//               switch (value) {
//                 case 'edit':
//                   _showEditSheet(context);
//                   break;
//                 case 'delete':
//                   _showDeleteConfirmation(context);
//                   break;
//               }
//             },
//             itemBuilder: (context) => [
//               const PopupMenuItem(
//                 value: 'edit',
//                 child: Row(
//                   children: [
//                     Icon(Icons.edit, size: 20),
//                     SizedBox(width: 12),
//                     Text('Edit Contact'),
//                   ],
//                 ),
//               ),
//               const PopupMenuItem(
//                 value: 'delete',
//                 child: Row(
//                   children: [
//                     Icon(Icons.delete, size: 20, color: Colors.red),
//                     SizedBox(width: 12),
//                     Text('Delete Chat', style: TextStyle(color: Colors.red)),
//                   ],
//                 ),
//               ),
//             ],
//           ),
//         ],
//       ),
//       body: Column(
//         children: [
//           // Messages list
//           Expanded(
//             child: Obx(() {
//               if (controller.messages.isEmpty) {
//                 return const Center(
//                   child: Text(
//                     'No messages yet. Start the conversation!',
//                     style: TextStyle(
//                       color: AppColors.textSecondary,
//                       fontSize: 16,
//                     ),
//                   ),
//                 );
//               }

//               return ListView.builder(
//                 controller: controller.scrollController,
//                 reverse: true,
//                 padding: const EdgeInsets.all(AppSizes.paddingM),
//                 itemCount: controller.messages.length,
//                 itemBuilder: (context, index) {
//                   final message = controller.messages[controller.messages.length - 1 - index];
//                   return ChatMessageBubble(message: message);
//                 },
//               );
//             }),
//           ),

//           // Message input field
//           Container(
//             padding: const EdgeInsets.all(AppSizes.paddingM),
//             decoration: const BoxDecoration(
//               color: AppColors.surface,
//               border: Border(top: BorderSide(color: AppColors.divider)),
//             ),
//             child: SafeArea(
//               child: Row(
//                 children: [
//                   // Image picker button
//                   IconButton(
//                     onPressed: () => _pickImage(context),
//                     icon: const Icon(
//                       Icons.photo_camera_outlined,
//                       color: AppColors.primary,
//                       size: 24,
//                     ),
//                   ),

//                   // Message input field
//                   Expanded(
//                     child: Container(
//                       decoration: BoxDecoration(
//                         color: AppColors.background,
//                         borderRadius: BorderRadius.circular(25),
//                         border: Border.all(color: AppColors.divider),
//                       ),
//                       child: TextField(
//                         controller: controller.messageController,
//                         focusNode: controller.messageFocusNode,
//                         style: const TextStyle(
//                           color: AppColors.textPrimary,
//                           fontSize: 16,
//                         ),
//                         maxLines: null,
//                         textCapitalization: TextCapitalization.sentences,
//                         decoration: const InputDecoration(
//                           hintText: 'Type a message...',
//                           hintStyle: TextStyle(
//                             color: AppColors.textSecondary,
//                             fontSize: 16,
//                           ),
//                           border: InputBorder.none,
//                           contentPadding: EdgeInsets.symmetric(
//                             horizontal: 16,
//                             vertical: 12,
//                           ),
//                         ),
//                       ),
//                     ),
//                   ),

//                   const SizedBox(width: 8),

//                   // Send button
//                   IconButton(
//                     onPressed: controller.sendMessage,
//                     icon: const Icon(
//                       Icons.send,
//                       color: AppColors.primary,
//                       size: 24,
//                     ),
//                   ),
//                 ],
//               ),
//             ),
//           ),
//         ],
//       ),
//     );
//   }

//   void _pickImage(BuildContext context) {
//     showModalBottomSheet(
//       context: context,
//       builder: (BuildContext context) {
//         return SafeArea(
//           child: Wrap(
//             children: [
//               ListTile(
//                 leading: const Icon(Icons.photo_library),
//                 title: const Text('Photo Library'),
//                 onTap: () {
//                   Navigator.of(context).pop();
//                   _pickAndSendImage(ImagePicker(), ImageSource.gallery);
//                 },
//               ),
//               ListTile(
//                 leading: const Icon(Icons.photo_camera),
//                 title: const Text('Camera'),
//                 onTap: () {
//                   Navigator.of(context).pop();
//                   _pickAndSendImage(ImagePicker(), ImageSource.camera);
//                 },
//               ),
//             ],
//           ),
//         );
//       },
//     );
//   }

//   void _showEditSheet(BuildContext context) {
//     final nameController = TextEditingController(
//       text: controller.displayName.value,
//     );

//     Get.bottomSheet(
//       Container(
//         decoration: const BoxDecoration(
//           color: Colors.white,
//           borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
//         ),
//         padding: const EdgeInsets.all(AppSizes.paddingL),
//         child: Column(
//           mainAxisSize: MainAxisSize.min,
//           children: [
//             Row(
//               children: [
//                 IconButton(
//                   onPressed: () => Get.back(),
//                   icon: const Icon(Icons.close),
//                 ),
//                 const SizedBox(width: AppSizes.paddingM),
//                 const Expanded(
//                   child: Text('Edit Contact', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
//                 ),
//               ],
//             ),
//             const SizedBox(height: AppSizes.paddingL),
//             TextField(
//               controller: nameController,
//               decoration: const InputDecoration(
//                 labelText: 'Contact Name',
//                 border: OutlineInputBorder(),
//               ),
//             ),
//             const SizedBox(height: AppSizes.paddingL),
//             SizedBox(
//               width: double.infinity,
//               child: ElevatedButton(
//                 onPressed: () {
//                   final newName = nameController.text.trim();
//                   if (newName.isNotEmpty) {
//                     controller.updateDisplayName(newName);
//                     Get.back();
//                   }
//                 },
//                 child: const Text('Save'),
//               ),
//             ),
//           ],
//         ),
//       ),
//     );
//   }

//   void _showDeleteConfirmation(BuildContext context) {
//     Get.dialog(
//       AlertDialog(
//         title: const Text('Delete Chat'),
//         content: const Text('Are you sure you want to delete this chat? This action cannot be undone.'),
//         actions: [
//           TextButton(
//             onPressed: () => Get.back(),
//             child: const Text('Cancel'),
//           ),
//           TextButton(
//             onPressed: () {
//               Get.back();
//               controller.deleteChat();
//             },
//             style: TextButton.styleFrom(foregroundColor: Colors.red),
//             child: const Text('Delete'),
//           ),
//         ],
//       ),
//     );
//   }

//   Future<void> _pickAndSendImage(ImagePicker picker, ImageSource source) async {
//     try {
//       final XFile? pickedFile = await picker.pickImage(
//         source: source,
//         maxWidth: 2048,
//         maxHeight: 2048,
//         imageQuality: 90,
//       );

//       if (pickedFile == null) return;

//       // Show processing indicator
//       Get.snackbar(
//         'Processing',
//         'Compressing and sending image...',
//         snackPosition: SnackPosition.BOTTOM,
//         showProgressIndicator: true,
//         isDismissible: false,
//         duration: const Duration(seconds: 30),
//       );

//       // Read image bytes
//       final imageBytes = await File(pickedFile.path).readAsBytes();

//       // Convert to base64
//       final imageBase64 = base64Encode(imageBytes);

//       // Send via socket
//       final success = await controller.sendImageMessage(imageBase64);

//       Get.closeCurrentSnackbar();

//       if (success) {
//         Get.snackbar(
//           'Sent',
//           'Image sent successfully',
//           snackPosition: SnackPosition.BOTTOM,
//           backgroundColor: Colors.green.shade100,
//           colorText: Colors.green.shade800,
//         );
//       } else {
//         Get.snackbar(
//           'Failed',
//           'Failed to send image',
//           snackPosition: SnackPosition.BOTTOM,
//           backgroundColor: Colors.red.shade100,
//           colorText: Colors.red.shade800,
//         );
//       }
//     } catch (e) {
//       Get.closeCurrentSnackbar();
//       Get.snackbar(
//         'Error',
//         'Failed to process image: $e',
//         snackPosition: SnackPosition.BOTTOM,
//         backgroundColor: Colors.red.shade100,
//         colorText: Colors.red.shade800,
//       );
//     }
//   }
// }
//         ),
//         padding: const EdgeInsets.all(AppSizes.paddingL),
//         child: Column(
//           mainAxisSize: MainAxisSize.min,
//           crossAxisAlignment: CrossAxisAlignment.start,
//           children: [
//             Align(
//               alignment: Alignment.center,
//               child: Container(
//                 width: 50,
//                 height: 5,
//                 margin: EdgeInsets.only(bottom: AppSizes.paddingXL),
//                 decoration: BoxDecoration(
//                   color: AppColors.messageText,
//                   borderRadius: BorderRadius.circular(5),
//                 ),
//               ),
//             ),
//             // Name field
//             TextField(
//               controller: nameController,
//               decoration: InputDecoration(
//                 labelText: 'Contact Name',
//                 labelStyle: TextStyle(color: AppColors.textPrimary),
//                 border: OutlineInputBorder(),
//                 disabledBorder: OutlineInputBorder(),
//                 enabledBorder: OutlineInputBorder(),
//                 focusedBorder: OutlineInputBorder(),
//                 errorBorder: OutlineInputBorder(),
//                 focusedErrorBorder: OutlineInputBorder(),
//                 prefixIcon: const Icon(Icons.person),
//                 prefixIconColor: AppColors.textPrimary,
//                 contentPadding: const EdgeInsets.symmetric(
//                   vertical: AppSizes.paddingM,
//                   horizontal: AppSizes.paddingL,
//                 ),
//                 suffixIcon: Icon(Icons.edit),
//                 suffixIconColor: AppColors.textPrimary,
//               ),
//             ),
//             const SizedBox(height: AppSizes.paddingXL),

//             // Action buttons
//             Row(
//               children: [
//                 Expanded(
//                   child: ElevatedButton.icon(
//                     onPressed: () {
//                       final newName = nameController.text.trim();
//                       if (newName.isNotEmpty) {
//                         controller.updateContactName(newName);
//                       }
//                       Get.back();
//                     },
//                     icon: const Icon(Icons.save),
//                     label: const Text('Save'),
//                     style: ElevatedButton.styleFrom(
//                       backgroundColor: AppColors.primary,
//                       foregroundColor: Colors.white,
//                       padding: const EdgeInsets.symmetric(vertical: 12),
//                     ),
//                   ),
//                 ),
//                 const SizedBox(width: AppSizes.paddingM),
//                 Expanded(
//                   child: ElevatedButton.icon(
//                     onPressed: () {
//                       Get.back();
//                       controller.showDeleteConfirmation();
//                     },
//                     icon: const Icon(Icons.delete),
//                     label: const Text('Delete Chat'),
//                     style: ElevatedButton.styleFrom(
//                       backgroundColor: AppColors.error,
//                       foregroundColor: Colors.white,
//                       padding: const EdgeInsets.symmetric(vertical: 12),
//                     ),
//                   ),
//                 ),
//               ],
//             ),
//             const SizedBox(height: AppSizes.paddingM),
//           ],
//         ),
//       ),
//       isScrollControlled: true,
//     );
//   }

//   void _showBlockConfirmation() {
//     Get.dialog(
//       Dialog(
//         shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
//         child: Container(
//           padding: const EdgeInsets.all(24),
//           decoration: BoxDecoration(
//             borderRadius: BorderRadius.circular(20),
//             color: Colors.white,
//           ),
//           child: Column(
//             mainAxisSize: MainAxisSize.min,
//             children: [
//               Container(
//                 width: 70,
//                 height: 70,
//                 decoration: BoxDecoration(
//                   color: Colors.orange.shade100,
//                   shape: BoxShape.circle,
//                 ),
//                 child: Icon(
//                   Icons.block,
//                   size: 36,
//                   color: Colors.orange.shade700,
//                 ),
//               ),
//               const SizedBox(height: 20),
//               Text(
//                 'Block User',
//                 style: Get.textTheme.headlineSmall?.copyWith(
//                   fontWeight: FontWeight.bold,
//                   color: Colors.grey.shade800,
//                 ),
//               ),
//               const SizedBox(height: 12),
//               Text(
//                 'Blocked users will no longer be able to send you messages. You can unblock them anytime.',
//                 style: Get.textTheme.bodyMedium?.copyWith(
//                   color: Colors.grey.shade600,
//                   height: 1.4,
//                 ),
//                 textAlign: TextAlign.center,
//               ),
//               const SizedBox(height: 24),
//               Row(
//                 children: [
//                   Expanded(
//                     child: OutlinedButton(
//                       onPressed: () => Get.back(),
//                       style: OutlinedButton.styleFrom(
//                         padding: const EdgeInsets.symmetric(vertical: 12),
//                         side: BorderSide(color: Colors.grey.shade300),
//                         shape: RoundedRectangleBorder(
//                           borderRadius: BorderRadius.circular(10),
//                         ),
//                       ),
//                       child: Text(
//                         'Cancel',
//                         style: TextStyle(
//                           color: Colors.grey.shade700,
//                           fontWeight: FontWeight.w600,
//                         ),
//                       ),
//                     ),
//                   ),
//                   const SizedBox(width: 12),
//                   Expanded(
//                     child: ElevatedButton(
//                       onPressed: () {
//                         Get.back();
//                         controller.blockUser();
//                         Get.snackbar(
//                           'User Blocked',
//                           'You have blocked this user',
//                           snackPosition: SnackPosition.BOTTOM,
//                           backgroundColor: Colors.orange.shade100,
//                           colorText: Colors.orange.shade800,
//                           icon: Icon(
//                             Icons.block,
//                             color: Colors.orange.shade600,
//                           ),
//                           duration: const Duration(seconds: 2),
//                         );
//                       },
//                       style: ElevatedButton.styleFrom(
//                         backgroundColor: Colors.orange.shade700,
//                         foregroundColor: Colors.white,
//                         padding: const EdgeInsets.symmetric(vertical: 12),
//                         shape: RoundedRectangleBorder(
//                           borderRadius: BorderRadius.circular(10),
//                         ),
//                       ),
//                       child: const Text(
//                         'Block',
//                         style: TextStyle(fontWeight: FontWeight.w600),
//                       ),
//                     ),
//                   ),
//                 ],
//               ),
//             ],
//           ),
//         ),
//       ),
//       barrierDismissible: true,
//     );
//   }

//   void _showPopupMenu(BuildContext context) {
//     final RenderBox overlay =
//         Overlay.of(context).context.findRenderObject() as RenderBox;
//     final RenderBox button = context.findRenderObject() as RenderBox;
//     final Offset position =
//         button.localToGlobal(Offset.zero, ancestor: overlay);

//     showMenu<String>(
//       context: context,
//       position: RelativeRect.fromLTRB(
//         position.dx,
//         position.dy + button.size.height,
//         overlay.size.width - 10,
//         overlay.size.height - position.dy - button.size.height,
//       ),
//       items: [
//         const PopupMenuItem(
//           value: 'edit_user_name',
//           child: Row(
//             children: [
//               Icon(Icons.edit_outlined, color: Colors.black, size: 20),
//               SizedBox(width: 8),
//               Text('Edit This User Name'),
//             ],
//           ),
//         ),
//         PopupMenuDivider(),
//         PopupMenuItem(
//           value: 'block_user',
//           child: Obx(
//             () => Row(
//               children: [
//                 Icon(
//                   controller.isBlockedByMe.value
//                       ? Icons.lock_open
//                       : Icons.block,
//                   color: controller.isBlockedByMe.value
//                       ? Colors.green
//                       : Colors.orange,
//                   size: 20,
//                 ),
//                 const SizedBox(width: 8),
//                 Text(
//                   controller.isBlockedByMe.value
//                       ? 'Unblock User'
//                       : 'Block User',
//                 ),
//               ],
//             ),
//           ),
//         ),
//         PopupMenuDivider(),
//         const PopupMenuItem(
//           value: 'report_user',
//           child: Row(
//             children: [
//               Icon(Icons.flag_outlined, color: Colors.red, size: 20),
//               SizedBox(width: 8),
//               Text('Report User'),
//             ],
//           ),
//         ),
//         PopupMenuDivider(),
//         const PopupMenuItem(
//           value: 'clear_chat',
//           child: Row(
//             children: [
//               Icon(Icons.cleaning_services_outlined,
//                   color: Colors.red, size: 20),
//               SizedBox(width: 8),
//               Text('Clear Chat'),
//             ],
//           ),
//         ),
//       ],
//     ).then((value) {
//       if (value != null) {
//         _handlePopupMenuSelection(value);
//       }
//     });
//   }

//   void _handlePopupMenuSelection(String value) {
//     if (value == 'report_user') {
//       ReportBottomSheet.show(
//         targetType: 'user',
//         targetId: controller.recipientDeviceId,
//       );
//     } else if (value == "clear_chat") {
//       _showClearChatDialog(Get.context!);
//     } else if (value == 'block_user') {
//       if (controller.isBlockedByMe.value) {
//         controller.unblockUser();
//       } else {
//         _showBlockConfirmation();
//       }
//     } else if (value == 'edit_user_name') {
//       _showEditSheet(Get.context!);
//     }
//   }

//   void _showClearChatDialog(BuildContext context) {
//     Get.dialog(
//       Dialog(
//         shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
//         child: Container(
//           padding: const EdgeInsets.all(24),
//           decoration: BoxDecoration(
//             borderRadius: BorderRadius.circular(20),
//             gradient: LinearGradient(
//               begin: Alignment.topLeft,
//               end: Alignment.bottomRight,
//               colors: [Colors.white, Colors.grey.shade50],
//             ),
//           ),
//           child: Column(
//             mainAxisSize: MainAxisSize.min,
//             children: [
//               // Icon with animation effect
//               Container(
//                 width: 80,
//                 height: 80,
//                 decoration: BoxDecoration(
//                   color: Colors.orange.shade100,
//                   shape: BoxShape.circle,
//                 ),
//                 child: Icon(
//                   Icons.cleaning_services_rounded,
//                   size: 40,
//                   color: Colors.orange.shade600,
//                 ),
//               ),
//               const SizedBox(height: 20),

//               // Title
//               Text(
//                 'Clear Chat Messages',
//                 style: Get.textTheme.headlineSmall?.copyWith(
//                   fontWeight: FontWeight.bold,
//                   color: Colors.grey.shade800,
//                 ),
//                 textAlign: TextAlign.center,
//               ),
//               const SizedBox(height: 12),

//               // Description
//               Text(
//                 'This will permanently delete all messages in this conversation. The chat will remain in your list but all message history will be lost.',
//                 style: Get.textTheme.bodyMedium?.copyWith(
//                   color: Colors.grey.shade600,
//                   height: 1.4,
//                 ),
//                 textAlign: TextAlign.center,
//               ),
//               const SizedBox(height: 24),

//               // Progress indicator (static for visual appeal)
//               Container(
//                 width: double.infinity,
//                 height: 4,
//                 decoration: BoxDecoration(
//                   color: Colors.grey.shade200,
//                   borderRadius: BorderRadius.circular(2),
//                 ),
//                 child: FractionallySizedBox(
//                   alignment: Alignment.centerLeft,
//                   widthFactor: 0.0,
//                   child: Container(
//                     decoration: BoxDecoration(
//                       color: AppColors.primary,
//                       borderRadius: BorderRadius.circular(2),
//                     ),
//                   ),
//                 ),
//               ),
//               const SizedBox(height: 24),

//               // Action buttons
//               Row(
//                 children: [
//                   Expanded(
//                     child: OutlinedButton(
//                       onPressed: () => Get.back(),
//                       style: OutlinedButton.styleFrom(
//                         padding: const EdgeInsets.symmetric(vertical: 12),
//                         side: BorderSide(color: Colors.grey.shade300),
//                         shape: RoundedRectangleBorder(
//                           borderRadius: BorderRadius.circular(10),
//                         ),
//                       ),
//                       child: Text(
//                         'Cancel',
//                         style: TextStyle(
//                           color: Colors.grey.shade700,
//                           fontWeight: FontWeight.w600,
//                         ),
//                       ),
//                     ),
//                   ),
//                   const SizedBox(width: 12),
//                   Expanded(
//                     child: ElevatedButton(
//                       onPressed: () => _clearChatMessages(),
//                       style: ElevatedButton.styleFrom(
//                         backgroundColor: Colors.orange.shade600,
//                         foregroundColor: Colors.white,
//                         padding: const EdgeInsets.symmetric(vertical: 12),
//                         shape: RoundedRectangleBorder(
//                           borderRadius: BorderRadius.circular(10),
//                         ),
//                         elevation: 2,
//                       ),
//                       child: const Text(
//                         'Clear Messages',
//                         style: TextStyle(fontWeight: FontWeight.w600),
//                       ),
//                     ),
//                   ),
//                 ],
//               ),
//             ],
//           ),
//         ),
//       ),
//       barrierDismissible: true,
//     );
//   }

//   void _clearChatMessages() async {
//     // Show progress animation
//     Get.back(); // Close dialog

//     // Show loading dialog with progress
//     Get.dialog(
//       Dialog(
//         shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
//         child: Container(
//           padding: const EdgeInsets.all(24),
//           decoration: BoxDecoration(
//             borderRadius: BorderRadius.circular(20),
//             color: Colors.white,
//           ),
//           child: Column(
//             mainAxisSize: MainAxisSize.min,
//             children: [
//               const CircularProgressIndicator(
//                 valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
//               ),
//               const SizedBox(height: 20),
//               Text(
//                 'Clearing messages...',
//                 style: Get.textTheme.bodyLarge?.copyWith(
//                   fontWeight: FontWeight.w500,
//                 ),
//               ),
//             ],
//           ),
//         ),
//       ),
//       barrierDismissible: false,
//     );

//     // Simulate progress delay for better UX
//     await Future.delayed(const Duration(milliseconds: 1500));

//     // Clear messages through controller
//     await controller.clearChatMessages();

//     // Close loading dialog
//     Get.back();

//     // Show success message
//     Get.snackbar(
//       'Success',
//       'All messages have been cleared',
//       snackPosition: SnackPosition.BOTTOM,
//       backgroundColor: Colors.green.shade100,
//       colorText: Colors.green.shade800,
//       icon: Icon(Icons.check_circle, color: Colors.green.shade600),
//       duration: const Duration(seconds: 2),
//     );
//   }

//   @override
//   Widget build(BuildContext context) {
//     return PopScope(
//       canPop: false,
//       onPopInvoked: (didPop) async {
//         if (didPop) return;

//         // Check if we can navigate back in the navigation stack
//         if (Navigator.of(context).canPop()) {
//           Navigator.of(context).pop();
//         } else {
//           // No navigation stack - navigate to chat list as fallback
//           print('📱 No navigation stack found, navigating to chat list');
//           Get.offAllNamed('/chat-list');
//         }
//       },
//       child: Scaffold(
//         backgroundColor: AppColors.primary,
//         appBar: AppBar(
//           backgroundColor: Colors.white,
//           title: Column(
//             crossAxisAlignment: CrossAxisAlignment.start,
//             children: [
//               Obx(
//                 () => Text(
//                   StringUtils.formatDeviceIdWithName(
//                     controller.recipientDeviceId,
//                     controller.displayName.value,
//                   ),
//                   style: const TextStyle(
//                     fontSize: AppSizes.fontM,
//                     fontWeight: FontWeight.bold,
//                     color: Colors.black,
//                   ),
//                 ),
//               ),
//               Obx(
//                 () => Text(
//                   controller.recipientStatus.value,
//                   style: TextStyle(
//                     fontSize: AppSizes.fontS,
//                     fontWeight: FontWeight.w600,
//                     color: controller.recipientOnline.value ||
//                             (controller.recipientLastSeen.value != null &&
//                                 DateTime.now()
//                                         .difference(
//                                             controller.recipientLastSeen.value!)
//                                         .inHours <
//                                     24)
//                         ? Colors.green
//                         : Colors.grey,
//                   ),
//                 ),
//               ),
//             ],
//           ),
//           centerTitle: false,
//           leading: IconButton(
//             icon: const Icon(Icons.arrow_back, color: Colors.black),
//             onPressed: () {
//               // Check if we can navigate back in the navigation stack
//               if (Navigator.of(context).canPop()) {
//                 Navigator.of(context).pop();
//               } else {
//                 // No navigation stack - navigate to chat list as fallback
//                 print('📱 No navigation stack found, navigating to chat list');
//                 Get.offAllNamed('/chat-list');
//               }
//             },
//           ),
//           actions: [
//             Builder(
//               builder: (context) => IconButton(
//                 icon: const Icon(Icons.more_vert, color: Colors.black),
//                 onPressed: () => _showPopupMenu(context),
//               ),
//             ),
//           ],
//         ),
//         body: Column(
//           children: [
//             // Connection status bar
//             // Obx(() {
//             //   if (!controller.isConnected.value) {
//             //     return Container(
//             //       padding: const EdgeInsets.all(AppSizes.paddingS),
//             //       color: AppColors.warning,
//             //       child: Row(
//             //         mainAxisAlignment: MainAxisAlignment.center,
//             //         children: const [
//             //           Icon(Icons.wifi_off,
//             //               size: AppSizes.iconS, color: AppColors.textLight),
//             //           SizedBox(width: AppSizes.paddingS),
//             //           Text(
//             //             AppStrings.connecting,
//             //             style: TextStyle(color: AppColors.textLight),
//             //           ),
//             //         ],
//             //       ),
//             //     );
//             //   }
//             //   return const SizedBox.shrink();
//             // }),

//             // Messages list
//             Expanded(
//               child: Obx(() {
//                 if (controller.messages.isEmpty) {
//                   return const Center(
//                     child: Text(
//                       'No messages yet. Start a conversation!',
//                       style: TextStyle(color: Colors.black),
//                     ),
//                   );
//                 }

//                 return ListView.builder(
//                   controller: controller.scrollController,
//                   reverse: true,
//                   padding: const EdgeInsets.all(AppSizes.paddingM),
//                   itemCount: controller.messages.length,
//                   itemBuilder: (context, index) {
//                     final message = controller
//                         .messages[controller.messages.length - 1 - index];
//                     return ChatMessageBubble(message: message);
//                   },
//                 );
//               }),
//             ),

//             // Message input field
//             Container(
//               padding: const EdgeInsets.all(AppSizes.paddingM),
//               decoration: const BoxDecoration(
//                 color: AppColors.surface,
//                 border: Border(top: BorderSide(color: AppColors.divider)),
//               ),
//               child: SafeArea(
//                 child: Row(
//                   children: [
//                     // Image picker button
//                     IconButton(
//                       onPressed: _pickImage,
//                       icon: const Icon(
//                         Icons.photo_camera_outlined,
//                         color: AppColors.primary,
//                         size: 24,
//                       ),
//                     ),

//                     // Message input field
//                     Expanded(
//                       child: Container(
//                         decoration: BoxDecoration(
//                           color: AppColors.background,
//                           borderRadius: BorderRadius.circular(25),
//                           border: Border.all(color: AppColors.divider),
//                         ),
//                         child: TextField(
//                           controller: controller.messageController,
//                           focusNode: controller.messageFocusNode,
//                           style: const TextStyle(
//                             color: AppColors.textPrimary,
//                             fontSize: 16,
//                           ),
//                           maxLines: null,
//                           textCapitalization: TextCapitalization.sentences,
//                           decoration: const InputDecoration(
//                             hintText: 'Type a message...',
//                             hintStyle: TextStyle(
//                               color: AppColors.textSecondary,
//                               fontSize: 16,
//                             ),
//                             border: InputBorder.none,
//                             contentPadding: EdgeInsets.symmetric(
//                               horizontal: 16,
//                               vertical: 12,
//                             ),
//                           ),
//                         ),
//                       ),
//                     ),

//                     const SizedBox(width: 8),

//                     // Send button
//                     Obx(() => IconButton(
//                       onPressed: controller.isSending.value
//                           ? null
//                           : controller.sendMessage,
//                       icon: controller.isSending.value
//                           ? const SizedBox(
//                               width: 20,
//                               height: 20,
//                               child: CircularProgressIndicator(
//                                 strokeWidth: 2,
//                                 valueColor: AlwaysStoppedAnimation<Color>(
//                                     AppColors.primary),
//                               ),
//                             )
//                           : const Icon(
//                               Icons.send,
//                               color: AppColors.primary,
//                               size: 24,
//                             ),
//                     )),
//                   ],
//                 ),
//               ),
//             ),
//           ],
//         ),
//       ),
//     );
//   }

//   void _pickImage() {
//     showModalBottomSheet(
//       context: context,
//       builder: (BuildContext context) {
//         return SafeArea(
//           child: Wrap(
//             children: [
//               ListTile(
//                 leading: const Icon(Icons.photo_library),
//                 title: const Text('Photo Library'),
//                 onTap: () {
//                   Navigator.of(context).pop();
//                   _pickAndSendImage(ImagePicker(), ImageSource.gallery);
//                 },
//               ),
//               ListTile(
//                 leading: const Icon(Icons.photo_camera),
//                 title: const Text('Camera'),
//                 onTap: () {
//                   Navigator.of(context).pop();
//                   _pickAndSendImage(ImagePicker(), ImageSource.camera);
//                 },
//               ),
//             ],
//           ),
//         );
//       },
//     );
//   }
//                           style: TextStyle(
//                             color: Colors.red.shade700,
//                             fontSize: 13,
//                             fontWeight: FontWeight.w500,
//                           ),
//                         ),
//                       ],
//                     ),
//                   ),
//                 );
//               }

//               // Normal input field
//               return Container(
//                 padding: const EdgeInsets.all(AppSizes.paddingM),
//                 decoration: BoxDecoration(
//                   color: AppColors.surface,
//                   boxShadow: [
//                     BoxShadow(
//                       color: AppColors.shadow,
//                       blurRadius: 4,
//                       offset: const Offset(0, -2),
//                     ),
//                   ],
//                 ),
//                 child: SafeArea(
//                   child: Row(
//                     children: [
//                       Expanded(
//                         child: TextField(
//                           controller: controller.messageController,
//                           focusNode: controller.messageFocusNode,
//                           onChanged: controller.onTyping,
//                           maxLines: 7,
//                           minLines: 1,
//                           keyboardType: TextInputType.multiline,
//                           textInputAction: TextInputAction.newline,
//                           decoration: InputDecoration(
//                             hintText: AppStrings.typeMessage,
//                             filled: true,
//                             fillColor: AppColors.background,
//                             contentPadding: const EdgeInsets.symmetric(
//                               horizontal: AppSizes.paddingM,
//                               vertical: AppSizes.paddingS,
//                             ),
//                             border: OutlineInputBorder(
//                               borderRadius: BorderRadius.circular(
//                                 AppSizes.radiusCircular,
//                               ),
//                               borderSide: BorderSide.none,
//                             ),
//                           ),
//                         ),
//                       ),
//                       const SizedBox(width: AppSizes.paddingS),
//                       // Attachment button
//                       CircleAvatar(
//                         backgroundColor: AppColors.warning,
//                         child: IconButton(
//                           icon: const Icon(
//                             Icons.attach_file,
//                             color: AppColors.surfaceDark,
//                           ),
//                           onPressed: () => _showAttachmentOptions(context),
//                         ),
//                       ),
//                       const SizedBox(width: AppSizes.paddingS),

//                       CircleAvatar(
//                         backgroundColor: AppColors.primary,
//                         child: IconButton(
//                           icon: const Icon(
//                             Icons.send,
//                             color: AppColors.textLight,
//                           ),
//                           onPressed: controller.sendMessage,
//                         ),
//                       ),
//                     ],
//                   ),
//                 ),
//               );
//             }),
//           ],
//         ),
//       ),
//     );
//   }

//   void _showAttachmentOptions(BuildContext context) {
//     final ImagePicker imagePicker = ImagePicker();

//     Get.bottomSheet(
//       Container(
//         decoration: const BoxDecoration(
//           color: Colors.white,
//           borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
//         ),
//         padding: const EdgeInsets.all(20),
//         child: Column(
//           mainAxisSize: MainAxisSize.min,
//           children: [
//             // Handle bar
//             Container(
//               width: 40,
//               height: 4,
//               margin: const EdgeInsets.only(bottom: 20),
//               decoration: BoxDecoration(
//                 color: Colors.grey[300],
//                 borderRadius: BorderRadius.circular(2),
//               ),
//             ),
//             Text(
//               'Send Photo',
//               style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
//             ),
//             const SizedBox(height: 24),
//             Row(
//               mainAxisAlignment: MainAxisAlignment.spaceEvenly,
//               children: [
//                 // Camera option
//                 _buildAttachmentOption(
//                   icon: Icons.camera_alt,
//                   label: 'Camera',
//                   color: Colors.blue,
//                   onTap: () async {
//                     Get.back();
//                     await _pickAndSendImage(imagePicker, ImageSource.camera);
//                   },
//                 ),
//                 // Gallery option
//                 _buildAttachmentOption(
//                   icon: Icons.photo_library,
//                   label: 'Gallery',
//                   color: Colors.green,
//                   onTap: () async {
//                     Get.back();
//                     await _pickAndSendImage(imagePicker, ImageSource.gallery);
//                   },
//                 ),
//               ],
//             ),
//             const SizedBox(height: 16),
//           ],
//         ),
//       ),
//       isScrollControlled: true,
//     );
//   }

//   Widget _buildAttachmentOption({
//     required IconData icon,
//     required String label,
//     required Color color,
//     required VoidCallback onTap,
//   }) {
//     return GestureDetector(
//       onTap: onTap,
//       child: Column(
//         children: [
//           Container(
//             width: 60,
//             height: 60,
//             decoration: BoxDecoration(
//               color: color.withOpacity(0.1),
//               borderRadius: BorderRadius.circular(30),
//             ),
//             child: Icon(icon, color: color, size: 28),
//           ),
//           const SizedBox(height: 8),
//           Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[700])),
//         ],
//       ),
//     );
//   }

//   Future<void> _pickAndSendImage(ImagePicker picker, ImageSource source) async {
//     try {
//       final XFile? pickedFile = await picker.pickImage(
//         source: source,
//         maxWidth: 2048,
//         maxHeight: 2048,
//         imageQuality: 90,
//       );

//       if (pickedFile == null) return;

//       // Show processing indicator
//       Get.snackbar(
//         'Processing',
//         'Compressing and sending image...',
//         snackPosition: SnackPosition.BOTTOM,
//         showProgressIndicator: true,
//         isDismissible: false,
//         duration: const Duration(seconds: 30),
//       );

//       // Read image bytes
//       final imageBytes = await File(pickedFile.path).readAsBytes();

//       // Compress image
//       final compressedBytes = await ImageCompression.compressImageToSize(
//         imageBytes,
//         targetSizeKB: 500,
//         minQuality: 40,
//       );

//       // Convert to base64
//       final imageBase64 = base64Encode(compressedBytes);

//       // Send via socket
//       final success = await controller.sendImageMessage(imageBase64);

//       Get.closeCurrentSnackbar();

//       if (success) {
//         Get.snackbar(
//           'Sent',
//           'Image sent successfully',
//           snackPosition: SnackPosition.BOTTOM,
//           backgroundColor: Colors.green[100],
//           colorText: Colors.green[800],
//           duration: const Duration(seconds: 2),
//         );
//       } else {
//         Get.snackbar(
//           'Error',
//           'Failed to send image. Please try again.',
//           snackPosition: SnackPosition.BOTTOM,
//           backgroundColor: Colors.red[100],
//           colorText: Colors.red[800],
//         );
//       }
//     } catch (e) {
//       Get.closeCurrentSnackbar();
//       Get.snackbar(
//         'Error',
//         'Failed to process image: $e',
//         snackPosition: SnackPosition.BOTTOM,
//         backgroundColor: Colors.red[100],
//         colorText: Colors.red[800],
//       );
//     }
//   }
// }
