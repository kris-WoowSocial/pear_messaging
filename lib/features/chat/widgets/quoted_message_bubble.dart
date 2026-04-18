import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'dart:convert';
import 'dart:typed_data';
import '../../../storage/models/reply_to_entity.dart';
import '../../../storage/models/message_entity.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/services/local_storage_service.dart';

class QuotedMessageBubble extends StatelessWidget {
  final ReplyToEntity replyTo;
  final VoidCallback? onTap;

  const QuotedMessageBubble({
    Key? key,
    required this.replyTo,
    this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Get current user's device ID
    final localStorageService = Get.find<LocalStorageService>();
    final myDeviceId = localStorageService.deviceId ?? '';

    debugPrint('🖼️ QuotedMessageBubble: Building reply bubble');
    debugPrint('🖼️ QuotedMessageBubble: Reply type: ${replyTo.type}');
    debugPrint(
        '🖼️ QuotedMessageBubble: Has mediaThumbnail: ${replyTo.mediaThumbnail != null}');
    if (replyTo.mediaThumbnail != null) {
      debugPrint(
          '🖼️ QuotedMessageBubble: MediaThumbnail length: ${replyTo.mediaThumbnail!.length}');
    }

    // Determine display name for the quoted message sender
    String displaySenderName;
    if (replyTo.senderId.isNotEmpty && replyTo.senderId == myDeviceId) {
      displaySenderName = 'You';
    } else {
      displaySenderName = replyTo.senderName;
    }

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(
            color: AppColors.primary,
            width: 3,
          ),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Reply icon
                Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.reply,
                    size: 14,
                    color: AppColors.primary,
                  ),
                ),
                SizedBox(width: 8),

                // Reply content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        displaySenderName,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2),
                      // Show image thumbnail for image replies, text for others
                      if (replyTo.type == MessageType.image &&
                          replyTo.mediaThumbnail != null &&
                          replyTo.mediaThumbnail!.isNotEmpty)
                        Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                color: Colors.grey.withAlpha(25),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Image.memory(
                                  _decodeBase64Image(replyTo.mediaThumbnail!),
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(4),
                                        color: Colors.grey.withAlpha(25),
                                      ),
                                      child: Icon(
                                        Icons.image,
                                        size: 20,
                                        color: Colors.grey,
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '📷 Photo',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        )
                      else
                        Text(
                          _getReplyContent(),
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
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
    }
  }

  /// Decode base64 string to Uint8List for image display
  Uint8List _decodeBase64Image(String base64String) {
    try {
      debugPrint(
          '🖼️ QuotedMessageBubble: Decoding base64 image (${base64String.length} chars)');
      final result = base64Decode(base64String);
      debugPrint(
          '🖼️ QuotedMessageBubble: Successfully decoded to ${result.length} bytes');
      return result;
    } catch (e) {
      debugPrint('🖼️ QuotedMessageBubble: Failed to decode base64 image: $e');
      return Uint8List(0);
    }
  }
}
