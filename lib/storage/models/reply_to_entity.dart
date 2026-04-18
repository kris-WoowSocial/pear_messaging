import '../../storage/models/message_entity.dart';

class ReplyToEntity {
  final String messageId;
  final String content;
  final String senderName;
  final String senderId; // Added to identify the original sender
  final MessageType type;
  final String? mediaThumbnail; // For image replies

  ReplyToEntity({
    required this.messageId,
    required this.content,
    required this.senderName,
    required this.senderId,
    required this.type,
    this.mediaThumbnail,
  });

  /// Create from JSON (for socket responses)
  factory ReplyToEntity.fromJson(Map<String, dynamic> json) {
    return ReplyToEntity(
      messageId: json['messageId'] as String,
      content: json['content'] as String,
      senderName: json['senderName'] as String,
      senderId: json['senderId'] as String? ??
          '', // Default to empty string for backward compatibility
      type: MessageType.values.firstWhere(
        (e) => e.toString() == 'MessageType.${json['type']}',
        orElse: () => MessageType.text,
      ),
      mediaThumbnail: json['mediaThumbnail'] as String?,
    );
  }

  /// Convert to JSON (for socket requests)
  Map<String, dynamic> toJson() {
    return {
      'messageId': messageId,
      'content': content,
      'senderName': senderName,
      'senderId': senderId,
      'type': type.toString().split('.').last,
      if (mediaThumbnail != null) 'mediaThumbnail': mediaThumbnail,
    };
  }

  /// Create a copy with updated fields
  ReplyToEntity copyWith({
    String? messageId,
    String? content,
    String? senderName,
    String? senderId,
    MessageType? type,
    String? mediaThumbnail,
  }) {
    return ReplyToEntity(
      messageId: messageId ?? this.messageId,
      content: content ?? this.content,
      senderName: senderName ?? this.senderName,
      senderId: senderId ?? this.senderId,
      type: type ?? this.type,
      mediaThumbnail: mediaThumbnail ?? this.mediaThumbnail,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ReplyToEntity &&
        other.messageId == messageId &&
        other.content == content &&
        other.senderName == senderName &&
        other.senderId == senderId &&
        other.type == type &&
        other.mediaThumbnail == mediaThumbnail;
  }

  @override
  int get hashCode {
    return messageId.hashCode ^
        content.hashCode ^
        senderName.hashCode ^
        senderId.hashCode ^
        type.hashCode ^
        mediaThumbnail.hashCode;
  }

  @override
  String toString() {
    return 'ReplyToEntity(messageId: $messageId, content: $content, senderName: $senderName, senderId: $senderId, type: $type, mediaThumbnail: $mediaThumbnail)';
  }
}
