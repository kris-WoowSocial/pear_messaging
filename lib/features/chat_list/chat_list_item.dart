import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/utils/string_utils.dart';
import '../../core/utils/time_utils.dart';
import 'chat_list_model.dart';

class ChatListItem extends StatelessWidget {
  final ChatListModel chat;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const ChatListItem({
    super.key,
    required this.chat,
    required this.onTap,
    this.onLongPress,
  });

  /// Get display message, handling base64 image data and null cases
  String _getDisplayMessage(String? lastMessage) {
    if (lastMessage == null || lastMessage.isEmpty) {
      return 'No messages yet';
    }

    // Check if this looks like base64 image data (starts with /9j/ or data:image or is very long)
    if (lastMessage.startsWith('/9j/') ||
        lastMessage.startsWith('data:image') ||
        lastMessage.startsWith('iVBORw0KGgo') || // PNG base64
        (lastMessage.length > 100 && !lastMessage.contains(' '))) {
      return '📷 Photo';
    }

    return lastMessage;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        height: AppSizes.chatItemHeight,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSizes.paddingM,
          vertical: AppSizes.paddingS,
        ),
        child: Row(
          children: [
            // Avatar
            Container(
              width: AppSizes.avatarSize,
              height: AppSizes.avatarSize,
              decoration: BoxDecoration(
                color: AppColors.senderBubble,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  chat.userName.isNotEmpty
                      ? chat.userName[0].toUpperCase()
                      : StringUtils.generateFriendlyName(chat.id)[0]
                          .toUpperCase(),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: AppSizes.fontXL,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSizes.paddingM),

            // Chat info
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name and time
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          StringUtils.formatDeviceIdWithName(
                              chat.id, chat.userName),
                          style: const TextStyle(
                            fontSize: AppSizes.fontL,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (chat.lastMessageTime != null)
                        Text(
                          TimeUtils.formatChatTime(chat.lastMessageTime!),
                          style: const TextStyle(
                            fontSize: AppSizes.fontS,
                            color: AppColors.textPrimary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),

                  // Last message
                  Row(
                    children: [
                      // Reply indicator
                      if (chat.isReply) ...[
                        Icon(
                          Icons.reply,
                          size: 14,
                          color: AppColors.messageText,
                        ),
                        SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          chat.isReply && chat.replyContent != null
                              ? 'Replied to: ${chat.replyContent!.startsWith("MEDIA:") ? "📷 Photo" : chat.replyContent!.length > 30 ? '${chat.replyContent!.substring(0, 30)}...' : chat.replyContent}'
                              : _getDisplayMessage(chat.lastMessage),
                          style: TextStyle(
                            fontSize: AppSizes.fontM,
                            color: chat.lastMessage != null
                                ? AppColors.textPrimary
                                : AppColors.textPrimary.withOpacity(0.5),
                            fontWeight: chat.isReply
                                ? FontWeight.w500
                                : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (chat.unreadCount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.receiverBubble,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            chat.unreadCount.toString(),
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: AppSizes.fontS,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
