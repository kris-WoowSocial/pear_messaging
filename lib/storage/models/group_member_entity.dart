// import 'package:hive/hive.dart';

// part 'group_member_entity.g.dart';

// @HiveType(typeId: 4)
class GroupMemberEntity {
  // @HiveField(0)
  final String deviceId;

  // @HiveField(1)
  final String role;

  // @HiveField(2)
  final DateTime? joinedAt;

  GroupMemberEntity({
    required this.deviceId,
    this.role = 'member',
    this.joinedAt,
  });

  bool get isAdmin => role == 'admin';

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'role': role,
      'joinedAt': joinedAt?.toIso8601String(),
    };
  }

  factory GroupMemberEntity.fromJson(Map<String, dynamic> json) {
    return GroupMemberEntity(
      deviceId: json['deviceId'] as String,
      role: json['role'] as String? ?? 'member',
      joinedAt: json['joinedAt'] != null
          ? DateTime.parse(json['joinedAt'] as String)
          : null,
    );
  }

  GroupMemberEntity copyWith({
    String? deviceId,
    String? role,
    DateTime? joinedAt,
  }) {
    return GroupMemberEntity(
      deviceId: deviceId ?? this.deviceId,
      role: role ?? this.role,
      joinedAt: joinedAt ?? this.joinedAt,
    );
  }
}
