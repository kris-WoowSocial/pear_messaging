// import 'package:hive/hive.dart';
import 'message_entity.dart';
import 'group_member_entity.dart';

// part 'chat_entity.g.dart';

// @HiveType(typeId: 0)
class ChatEntity {
  // @HiveField(0)
  final String id;

  // @HiveField(1)
  final String userName;

  // @HiveField(2)
  final String? lastMessage;

  // @HiveField(3)
  final DateTime? lastMessageTime;

  // @HiveField(4)
  final List<MessageEntity> messages;

  // @HiveField(5)
  final int unreadCount;

  // @HiveField(6)
  final bool isReply;

  // @HiveField(7)
  final String? replyContent;

  // Group chat fields
  final bool isGroup;
  final String? groupName;
  final List<GroupMemberEntity> members;
  final List<String> admins;
  final String? inviteCode;
  final String? avatarUrl;
  final int? maxMembers;

  ChatEntity({
    required this.id,
    required this.userName,
    this.lastMessage,
    this.lastMessageTime,
    List<MessageEntity>? messages,
    this.unreadCount = 0,
    this.isReply = false,
    this.replyContent,
    this.isGroup = false,
    this.groupName,
    List<GroupMemberEntity>? members,
    List<String>? admins,
    this.inviteCode,
    this.avatarUrl,
    this.maxMembers,
  })  : messages = messages ?? [],
        members = members ?? [],
        admins = admins ?? [];

  bool get isGroupChat => isGroup || id.startsWith('g_');

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userName': userName,
      'lastMessage': lastMessage,
      'lastMessageTime': lastMessageTime?.toIso8601String(),
      'messages': messages.map((m) => m.toJson()).toList(),
      'unreadCount': unreadCount,
      'isReply': isReply,
      'replyContent': replyContent,
      'isGroup': isGroup,
      'groupName': groupName,
      'members': members.map((m) => m.toJson()).toList(),
      'admins': admins,
      'inviteCode': inviteCode,
      'avatarUrl': avatarUrl,
      'maxMembers': maxMembers,
    };
  }

  factory ChatEntity.fromJson(Map<String, dynamic> json) {
    return ChatEntity(
      id: json['id'] as String,
      userName: json['userName'] as String,
      lastMessage: json['lastMessage'] as String?,
      lastMessageTime: json['lastMessageTime'] != null
          ? DateTime.parse(json['lastMessageTime'] as String)
          : null,
      messages: (json['messages'] as List<dynamic>?)
              ?.map((m) => MessageEntity.fromJson(m as Map<String, dynamic>))
              .toList() ??
          [],
      unreadCount: json['unreadCount'] as int? ?? 0,
      isReply: json['isReply'] as bool? ?? false,
      replyContent: json['replyContent'] as String?,
      isGroup: json['isGroup'] as bool? ?? false,
      groupName: json['groupName'] as String?,
      members: (json['members'] as List<dynamic>?)
              ?.map(
                  (m) => GroupMemberEntity.fromJson(m as Map<String, dynamic>))
              .toList() ??
          [],
      admins: (json['admins'] as List<dynamic>?)
              ?.map((a) => a as String)
              .toList() ??
          [],
      inviteCode: json['inviteCode'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      maxMembers: json['maxMembers'] as int?,
    );
  }

  ChatEntity copyWith({
    String? id,
    String? userName,
    String? lastMessage,
    DateTime? lastMessageTime,
    List<MessageEntity>? messages,
    int? unreadCount,
    bool? isReply,
    String? replyContent,
    bool clearLastMessage = false,
    bool clearLastMessageTime = false,
    bool? isGroup,
    String? groupName,
    List<GroupMemberEntity>? members,
    List<String>? admins,
    String? inviteCode,
    String? avatarUrl,
    int? maxMembers,
  }) {
    return ChatEntity(
      id: id ?? this.id,
      userName: userName ?? this.userName,
      lastMessage: clearLastMessage ? null : (lastMessage ?? this.lastMessage),
      lastMessageTime: clearLastMessageTime
          ? null
          : (lastMessageTime ?? this.lastMessageTime),
      messages: messages ?? this.messages,
      unreadCount: unreadCount ?? this.unreadCount,
      isReply: isReply ?? this.isReply,
      replyContent: replyContent ?? this.replyContent,
      isGroup: isGroup ?? this.isGroup,
      groupName: groupName ?? this.groupName,
      members: members ?? this.members,
      admins: admins ?? this.admins,
      inviteCode: inviteCode ?? this.inviteCode,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      maxMembers: maxMembers ?? this.maxMembers,
    );
  }
}
