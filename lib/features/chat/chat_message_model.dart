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
  final String? senderId;
  final int? totalMembers;
  final int? deliveredCount;
  final int? readCount;
  final String? fileName;
  final int? fileSize;
  final bool? isCompressed;
  final int? audioDuration;
  final String? waveformData;
  final Map<String, String> reactions;
  final int? expiresAt;
  final bool isViewOnce;
  final bool isViewOnceOpened;
  final bool isDeletedForEveryone;
  final DateTime? deletedAt;
  final bool isEdited;
  final DateTime? editedAt;

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
    this.senderId,
    this.totalMembers,
    this.deliveredCount,
    this.readCount,
    this.fileName,
    this.fileSize,
    this.isCompressed,
    this.audioDuration,
    this.waveformData,
    this.reactions = const {},
    this.expiresAt,
    this.isViewOnce = false,
    this.isViewOnceOpened = false,
    this.isDeletedForEveryone = false,
    this.deletedAt,
    this.isEdited = false,
    this.editedAt,
  });

  /// Check if message is an image
  bool get isImage => type == MessageType.image;

  /// Check if message is a file/document
  bool get isFile => type == MessageType.file;

  /// Check if message is an audio/voice message
  bool get isAudio => type == MessageType.audio;

  /// Check if message is a call log card
  bool get isCall => type == MessageType.call;

  /// View-once tile shown to the recipient before opening.
  bool get isViewOncePending => isViewOnce && !isViewOnceOpened;

  /// Disappearing message still counting down
  bool get isExpiring => expiresAt != null;

  /// Check if media has expired
  bool get isMediaExpired {
    if (mediaExpiryTimestamp == null) return false;
    return DateTime.now().isAfter(mediaExpiryTimestamp!);
  }

  /// Check if this message is a reply
  bool get isReply => replyTo != null;

  ChatMessageModel copyWith({
    String? id,
    String? content,
    bool? isMe,
    DateTime? timestamp,
    MessageStatus? status,
    MessageType? type,
    String? mediaToken,
    DateTime? mediaExpiryTimestamp,
    ReplyToEntity? replyTo,
    String? senderName,
    String? senderId,
    int? totalMembers,
    int? deliveredCount,
    int? readCount,
    String? fileName,
    int? fileSize,
    bool? isCompressed,
    int? audioDuration,
    String? waveformData,
    Map<String, String>? reactions,
    int? expiresAt,
    bool? isViewOnce,
    bool? isViewOnceOpened,
    bool? isDeletedForEveryone,
    DateTime? deletedAt,
    bool? isEdited,
    DateTime? editedAt,
  }) {
    return ChatMessageModel(
      id: id ?? this.id,
      content: content ?? this.content,
      isMe: isMe ?? this.isMe,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      type: type ?? this.type,
      mediaToken: mediaToken ?? this.mediaToken,
      mediaExpiryTimestamp: mediaExpiryTimestamp ?? this.mediaExpiryTimestamp,
      replyTo: replyTo ?? this.replyTo,
      senderName: senderName ?? this.senderName,
      senderId: senderId ?? this.senderId,
      totalMembers: totalMembers ?? this.totalMembers,
      deliveredCount: deliveredCount ?? this.deliveredCount,
      readCount: readCount ?? this.readCount,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      isCompressed: isCompressed ?? this.isCompressed,
      audioDuration: audioDuration ?? this.audioDuration,
      waveformData: waveformData ?? this.waveformData,
      reactions: reactions ?? this.reactions,
      expiresAt: expiresAt ?? this.expiresAt,
      isViewOnce: isViewOnce ?? this.isViewOnce,
      isViewOnceOpened: isViewOnceOpened ?? this.isViewOnceOpened,
      isDeletedForEveryone:
          isDeletedForEveryone ?? this.isDeletedForEveryone,
      deletedAt: deletedAt ?? this.deletedAt,
      isEdited: isEdited ?? this.isEdited,
      editedAt: editedAt ?? this.editedAt,
    );
  }

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
      senderId: entity.senderId,
      totalMembers: entity.totalMembers,
      deliveredCount: entity.deliveredCount,
      readCount: entity.readCount,
      fileName: entity.fileName,
      fileSize: entity.fileSize,
      isCompressed: entity.isCompressed,
      audioDuration: entity.audioDuration,
      waveformData: entity.waveformData,
      reactions: entity.reactions,
      expiresAt: entity.expiresAt,
      isViewOnce: entity.isViewOnce,
      isViewOnceOpened: entity.isViewOnceOpened,
      isDeletedForEveryone: entity.isDeletedForEveryone,
      deletedAt: entity.deletedAt,
      isEdited: entity.isEdited,
      editedAt: entity.editedAt,
    );
  }
}
