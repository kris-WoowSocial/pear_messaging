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
  final String? senderName;
  final int? totalMembers;
  final int? deliveredCount;
  final int? readCount;
  final String? fileName;
  final int? fileSize;
  final bool? isCompressed;
  final int? audioDuration;
  final String? waveformData;

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
    this.senderName,
    this.totalMembers,
    this.deliveredCount,
    this.readCount,
    this.fileName,
    this.fileSize,
    this.isCompressed,
    this.audioDuration,
    this.waveformData,
  });

  /// Check if message is an image
  bool get isImage => type == MessageType.image;

  /// Check if message is a file/document
  bool get isFile => type == MessageType.file;

  /// Check if message is an audio/voice message
  bool get isAudio => type == MessageType.audio;

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
      senderName: entity.senderName,
      totalMembers: entity.totalMembers,
      deliveredCount: entity.deliveredCount,
      readCount: entity.readCount,
      fileName: entity.fileName,
      fileSize: entity.fileSize,
      isCompressed: entity.isCompressed,
      audioDuration: entity.audioDuration,
      waveformData: entity.waveformData,
    );
  }
}
