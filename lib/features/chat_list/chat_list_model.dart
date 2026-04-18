class ChatListModel {
  final String id;
  final String userName;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final int unreadCount;
  final String avatarLetter;
  final bool isReply;
  final String? replyContent;

  ChatListModel({
    required this.id,
    required this.userName,
    this.lastMessage,
    this.lastMessageTime,
    this.unreadCount = 0,
    this.isReply = false,
    this.replyContent,
  }) : avatarLetter = userName.isNotEmpty ? userName[0].toUpperCase() : 'U';
}
