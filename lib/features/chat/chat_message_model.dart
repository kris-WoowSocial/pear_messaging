import '../../storage/models/message_entity.dart';
import '../../storage/models/reply_to_entity.dart';

class ChatMessageModel {
  final String id;
  final String content;
  final bool isMe;
  final DateTime timestamp;
  final MessageStatus status;
  final MessageType type;
  final String? mediaToken;
  final DateTime? mediaExpiryTimestamp;
  final ReplyToEntity? replyTo;

  ChatMessageModel({
    required this.id,
    required this.content,
    required this.isMe,
    required this.timestamp,
    required this.status,
    this.type = MessageType.text,
    this.mediaToken,
    this.mediaExpiryTimestamp,
    this.replyTo,
  });

  /// Check if message is an image
  bool get isImage => type == MessageType.image;

  /// Check if media has expired
  bool get isMediaExpired {
    if (mediaExpiryTimestamp == null) return false;
    return DateTime.now().isAfter(mediaExpiryTimestamp!);
  }

  /// Check if this message is a reply
  bool get isReply => replyTo != null;

  factory ChatMessageModel.fromEntity(MessageEntity entity) {
    return ChatMessageModel(
      id: entity.id,
      content: entity.content,
      isMe: entity.isMe,
      timestamp: entity.timestamp,
      status: entity.status,
      type: entity.type,
      mediaToken: entity.mediaToken,
      mediaExpiryTimestamp: entity.mediaExpiryTimestamp,
      replyTo: entity.replyTo,
    );
  }
}
