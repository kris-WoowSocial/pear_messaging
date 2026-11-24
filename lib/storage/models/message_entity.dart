// import 'package:hive/hive.dart';

// TODO: Run 'flutter pub run build_runner build' to generate adapters
// part 'message_entity.g.dart';
import 'reply_to_entity.dart';

// @HiveType(typeId: 1)
class MessageEntity {
  // @HiveField(0)
  final String id;

  // @HiveField(1)
  final String chatId;

  // @HiveField(2)
  final String senderId;

  // @HiveField(3)
  final String receiverId;

  // @HiveField(4)
  final String content;

  // @HiveField(5)
  final DateTime timestamp;

  // @HiveField(6)
  final MessageStatus status;

  // @HiveField(7)
  final bool isMe;

  // @HiveField(8)
  final MessageType type;

  // @HiveField(9)
  final String? mediaToken;

  // @HiveField(10)
  final DateTime? mediaExpiryTimestamp;

  // @HiveField(11)
  final ReplyToEntity? replyTo;

  // Group chat fields
  final String? senderName;
  final int? totalMembers;
  final int? deliveredCount;
  final int? readCount;

  // File message fields
  final String? fileName;
  final int? fileSize;
  final bool? isCompressed;

  // Audio message fields
  final int? audioDuration;
  final String? waveformData;

  /// Emoji reactions — reacterDeviceId -> emoji char.
  /// Local-only metadata; syncs via the `message_reaction` socket event.
  final Map<String, String> reactions;

  /// Disappearing-message expiry — unix epoch ms, null = never expires.
  /// Stamped at save time from the chat's `disappearingAfterSeconds`.
  final int? expiresAt;

  // View-once media fields
  /// True when the sender marked this media as view-once ("1" badge).
  final bool isViewOnce;

  /// Set once the recipient has opened (and purged) a view-once item.
  final bool isViewOnceOpened;

  /// Delete-for-everyone tombstone — content/media/reply are stripped at
  /// write time; the bubble renders "… deleted this message" instead.
  final bool isDeletedForEveryone;
  final DateTime? deletedAt;

  /// Edited-message marker — renders the muted "Edited" label next to the
  /// timestamp. `editedAt` is the sender-stamped edit time.
  final bool isEdited;
  final DateTime? editedAt;

  MessageEntity({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.receiverId,
    required this.content,
    required this.timestamp,
    required this.status,
    required this.isMe,
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
    this.reactions = const {},
    this.expiresAt,
    this.isViewOnce = false,
    this.isViewOnceOpened = false,
    this.isDeletedForEveryone = false,
    this.deletedAt,
    this.isEdited = false,
    this.editedAt,
  });

  bool get isExpired =>
      expiresAt != null && DateTime.now().millisecondsSinceEpoch > expiresAt!;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'chatId': chatId,
      'senderId': senderId,
      'receiverId': receiverId,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'status': status.toString().split('.').last,
      'isMe': isMe,
      'type': type.toString().split('.').last,
      'mediaToken': mediaToken,
      'mediaExpiryTimestamp': mediaExpiryTimestamp?.toIso8601String(),
      'replyTo': replyTo?.toJson(),
      'senderName': senderName,
      'totalMembers': totalMembers,
      'deliveredCount': deliveredCount,
      'readCount': readCount,
      'fileName': fileName,
      'fileSize': fileSize,
      'isCompressed': isCompressed,
      'audioDuration': audioDuration,
      'waveformData': waveformData,
      'reactions': reactions,
      'expiresAt': expiresAt,
      'isViewOnce': isViewOnce,
      'isViewOnceOpened': isViewOnceOpened,
      'isDeletedForEveryone': isDeletedForEveryone,
      'deletedAt': deletedAt?.toIso8601String(),
      'isEdited': isEdited,
      'editedAt': editedAt?.toIso8601String(),
    };
  }

  factory MessageEntity.fromJson(Map<String, dynamic> json) {
    return MessageEntity(
      id: json['id'] as String,
      chatId: json['chatId'] as String,
      senderId: json['senderId'] as String,
      receiverId: json['receiverId'] as String,
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      status: MessageStatus.values.firstWhere(
        (e) => e.toString().split('.').last == json['status'],
        orElse: () => MessageStatus.sending,
      ),
      isMe: json['isMe'] as bool? ?? false,
      type: MessageType.values.firstWhere(
        (e) => e.toString().split('.').last == json['type'],
        orElse: () => MessageType.text,
      ),
      mediaToken: json['mediaToken'] as String?,
      mediaExpiryTimestamp: json['mediaExpiryTimestamp'] != null
          ? DateTime.parse(json['mediaExpiryTimestamp'] as String)
          : null,
      replyTo: json['replyTo'] != null
          ? ReplyToEntity.fromJson(
              Map<String, dynamic>.from(json['replyTo'] as Map))
          : null,
      senderName: json['senderName'] as String?,
      totalMembers: json['totalMembers'] as int?,
      deliveredCount: json['deliveredCount'] as int?,
      readCount: json['readCount'] as int?,
      fileName: json['fileName'] as String?,
      fileSize: json['fileSize'] as int?,
      isCompressed: json['isCompressed'] as bool?,
      audioDuration: json['audioDuration'] as int?,
      waveformData: json['waveformData'] as String?,
      reactions: json['reactions'] is Map
          ? Map<String, String>.from(json['reactions'] as Map)
          : const {},
      expiresAt: json['expiresAt'] as int?,
      isViewOnce: json['isViewOnce'] as bool? ?? false,
      isViewOnceOpened: json['isViewOnceOpened'] as bool? ?? false,
      isDeletedForEveryone: json['isDeletedForEveryone'] as bool? ?? false,
      deletedAt: json['deletedAt'] != null
          ? DateTime.tryParse(json['deletedAt'] as String)
          : null,
      isEdited: json['isEdited'] as bool? ?? false,
      editedAt: json['editedAt'] != null
          ? DateTime.tryParse(json['editedAt'] as String)
          : null,
    );
  }

  MessageEntity copyWith({
    String? id,
    String? chatId,
    String? senderId,
    String? receiverId,
    String? content,
    DateTime? timestamp,
    MessageStatus? status,
    bool? isMe,
    MessageType? type,
    String? mediaToken,
    DateTime? mediaExpiryTimestamp,
    ReplyToEntity? replyTo,
    String? senderName,
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
    return MessageEntity(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      isMe: isMe ?? this.isMe,
      type: type ?? this.type,
      mediaToken: mediaToken ?? this.mediaToken,
      mediaExpiryTimestamp: mediaExpiryTimestamp ?? this.mediaExpiryTimestamp,
      replyTo: replyTo ?? this.replyTo,
      senderName: senderName ?? this.senderName,
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

  /// Delete-for-everyone tombstone: identity + timing survive, every piece
  /// of content (text, media, reply, file/audio metadata, reactions) is
  /// stripped so nothing sensitive persists in the box or in memory.
  MessageEntity toTombstone({DateTime? deletedAt}) {
    return MessageEntity(
      id: id,
      chatId: chatId,
      senderId: senderId,
      receiverId: receiverId,
      content: '',
      timestamp: timestamp,
      status: status,
      type: type,
      isMe: isMe,
      isDeletedForEveryone: true,
      deletedAt: deletedAt ?? DateTime.now().toUtc(),
    );
  }
}

// @HiveType(typeId: 3)
enum MessageType {
  // @HiveField(0)
  text,

  // @HiveField(1)
  image,

  // @HiveField(2)
  system,

  // @HiveField(3)
  file,

  // @HiveField(4)
  audio,

  // @HiveField(5)
  call,
}

// @HiveType(typeId: 2)
enum MessageStatus {
  // @HiveField(0)
  sending,

  // @HiveField(1)
  sent,

  // @HiveField(2)
  delivered,

  // @HiveField(3)
  read,

  // @HiveField(4)
  failed,
}
