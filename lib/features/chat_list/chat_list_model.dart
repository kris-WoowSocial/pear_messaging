class ChatListModel {
  final String id;
  final String userName;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final int unreadCount;
  final String avatarLetter;
  final bool isReply;
  final String? replyContent;
  final bool isGroup;

  /// Hidden from the main list; reachable only via the biometric-gated
  /// "Locked chats" row.
  final bool isLocked;

  ChatListModel({
    required this.id,
    required this.userName,
    this.lastMessage,
    this.lastMessageTime,
    this.unreadCount = 0,
    this.isReply = false,
    this.replyContent,
    this.isGroup = false,
    this.isLocked = false,
  }) : avatarLetter = userName.isNotEmpty ? userName[0].toUpperCase() : 'U';
}
