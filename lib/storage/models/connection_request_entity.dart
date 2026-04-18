import 'message_entity.dart';

enum ConnectionRequestStatus {
  pending,
  accepted,
  rejected,
  blocked,
}

class ConnectionRequestEntity {
  final String id;
  final String senderDeviceId;
  final String receiverDeviceId;
  final DateTime timestamp;
  final ConnectionRequestStatus status;
  final String? messageContent; // The actual message that triggered the request
  final MessageType messageType; // Text or image
  final String? senderName; // The actual user name from server

  ConnectionRequestEntity({
    required this.id,
    required this.senderDeviceId,
    required this.receiverDeviceId,
    required this.timestamp,
    required this.status,
    this.messageContent,
    this.messageType = MessageType.text,
    this.senderName,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'senderDeviceId': senderDeviceId,
      'receiverDeviceId': receiverDeviceId,
      'timestamp': timestamp.toIso8601String(),
      'status': status.name,
      'messageContent': messageContent,
      'messageType': messageType.name,
      'senderName': senderName,
    };
  }

  factory ConnectionRequestEntity.fromJson(Map<String, dynamic> json) {
    return ConnectionRequestEntity(
      id: json['id'] as String,
      senderDeviceId: json['senderDeviceId'] as String,
      receiverDeviceId: json['receiverDeviceId'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      status: ConnectionRequestStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => ConnectionRequestStatus.pending,
      ),
      messageContent: json['messageContent'] as String?,
      messageType: MessageType.values.firstWhere(
        (e) => e.name == json['messageType'],
        orElse: () => MessageType.text,
      ),
      senderName: json['senderName'] as String?,
    );
  }

  ConnectionRequestEntity copyWith({
    String? id,
    String? senderDeviceId,
    String? receiverDeviceId,
    DateTime? timestamp,
    ConnectionRequestStatus? status,
    String? messageContent,
    MessageType? messageType,
    String? senderName,
  }) {
    return ConnectionRequestEntity(
      id: id ?? this.id,
      senderDeviceId: senderDeviceId ?? this.senderDeviceId,
      receiverDeviceId: receiverDeviceId ?? this.receiverDeviceId,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      messageContent: messageContent ?? this.messageContent,
      messageType: messageType ?? this.messageType,
      senderName: senderName ?? this.senderName,
    );
  }
}
