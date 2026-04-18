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
  });

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
          ? ReplyToEntity.fromJson(json['replyTo'] as Map<String, dynamic>)
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
