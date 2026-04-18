class Validators {
  static bool isValidMessage(String? message) {
    return message != null && message.trim().isNotEmpty;
  }

  static bool isValidChatId(String? chatId) {
    return chatId != null && chatId.isNotEmpty;
  }

  static bool isValidUserId(String? userId) {
    return userId != null && userId.isNotEmpty;
  }

  static String? validateSearchQuery(String? query) {
    if (query == null || query.isEmpty) {
      return null;
    }
    return query.trim();
  }
}
