import 'package:flutter/material.dart';
import '../../../storage/models/reply_to_entity.dart';
import '../../../storage/models/message_entity.dart';
import '../../../core/constants/app_colors.dart';

class ReplyPreviewBar extends StatelessWidget {
  final ReplyToEntity replyTo;
  final VoidCallback onCancel;
  final VoidCallback? onTap;

  const ReplyPreviewBar({
    super.key,
    required this.replyTo,
    required this.onCancel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.senderBubble,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.primary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Row(
              children: [
                // Reply indicator line
                Container(
                  width: 4,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                SizedBox(width: 12),

                // Reply content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Replying to ${replyTo.senderName}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2),
                      Text(
                        _getReplyContent(),
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),

                // Close button
                GestureDetector(
                  onTap: onCancel,
                  child: Container(
                    padding: EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.grey.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getReplyContent() {
    switch (replyTo.type) {
      case MessageType.image:
        return '📷 Photo';
      case MessageType.system:
        return replyTo.content;
      case MessageType.text:
        return replyTo.content;
      case MessageType.file:
        return '📄 File';
      case MessageType.audio:
        return '🎤 Voice message';
    }
  }
}
