import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards against the cross-chat preview/unread leak: a message from sender
/// A was persisted onto chat B's ChatEntity (wrong preview + stuck unread
/// badge) because `_handleIncomingMessage` reused a list index captured
/// before `await` gaps — `chats` re-sorts during the gap, so
/// `chats[staleIndex]` resolved to a different chat.
void main() {
  late String chatListController;
  late String chatController;
  late String fcmService;
  late String storageService;

  setUpAll(() {
    chatListController =
        File('lib/features/chat_list/chat_list_controller.dart')
            .readAsStringSync();
    chatController =
        File('lib/features/chat/chat_controller.dart').readAsStringSync();
    fcmService = File('lib/core/services/fcm_service.dart').readAsStringSync();
    storageService =
        File('lib/core/services/local_storage_service.dart').readAsStringSync();
  });

  group('incoming message entity update is keyed strictly by senderId', () {
    late String handler;

    setUpAll(() {
      final start =
          chatListController.indexOf('Future<void> _handleIncomingMessage');
      final end =
          chatListController.indexOf('Future<void> _handleGroup', start);
      handler = chatListController.substring(start, end);
    });

    test('no list indexing with the pre-await stale index', () {
      // The regression: `chats[existingChatIndex]` was read AFTER awaits.
      expect(handler, isNot(contains('chats[existingChatIndex]')));
      expect(handler, isNot(contains('chats.removeAt(existingChatIndex)')));
    });

    test('target chat is re-resolved by id after the awaits', () {
      expect(handler, contains('_storageService.getChat(senderId)'));
      expect(
          handler, contains('chats.indexWhere((chat) => chat.id == senderId)'));
      expect(handler,
          contains('chats.removeWhere((chat) => chat.id == senderId)'));
    });

    test('persisted entity and list model are forced to senderId', () {
      // The saved ChatEntity must be a copyWith of the stored entity (or a
      // fresh entity with id: senderId) — never a list element's id.
      expect(
        handler,
        contains('ChatEntity(id: senderId, userName: displayName)'),
      );
      expect(
          handler, contains('id: senderId,\n        userName: displayName,'));
    });
  });

  group('opening a chat clears phantom unread badges', () {
    late String markRead;

    setUpAll(() {
      final start =
          chatController.indexOf('Future<void> _markMessagesAsRead()');
      final end = chatController.indexOf('_setupSocketListeners()', start);
      markRead = chatController.substring(start, end);
    });

    test('unreadCount reset is not gated on unread messages existing', () {
      // Phantom badge fix: the reset must run even when the chat holds zero
      // unread messages, guarded only by the entity's stored unreadCount.
      final reset = markRead.indexOf('copyWith(unreadCount: 0)');
      final gate = markRead.indexOf('chat.unreadCount != 0');
      expect(gate, greaterThanOrEqualTo(0));
      expect(reset, greaterThan(gate));
      expect(markRead, contains('clearedUnreadBadge'));
      expect(markRead,
          contains('unreadMessages.isNotEmpty || clearedUnreadBadge'));
    });
  });

  group('startup reconciliation repairs stored previews', () {
    test('controller reconciles entities against real message history', () {
      expect(
          chatListController, contains('unawaited(_reconcileChatPreviews())'));
      final start =
          chatListController.indexOf('Future<void> _reconcileChatPreviews()');
      final end = chatListController.indexOf(
          'static String _previewTextForMessage', start);
      final reconcile = chatListController.substring(start, end);
      expect(reconcile, contains('getChatMessages(chat.id)'));
      expect(reconcile, contains('chat.unreadCount != actualUnread'));
      expect(reconcile, contains('unreadCount: actualUnread'));
    });
  });

  group('storage and FCM writes stay strictly keyed', () {
    test('saveMessage only updates the entity for message.chatId', () {
      final start = storageService.indexOf('Future<void> saveMessage');
      final end = storageService.indexOf('setMessageReactions', start);
      final saveMessage = storageService.substring(start, end);
      expect(saveMessage, contains('getChat(message.chatId)'));
      expect(saveMessage, isNot(contains('firstWhere')));
    });

    test('FCM handlers derive 1:1 chatId from the sender, never recipient', () {
      // Background handler
      expect(
          fcmService,
          contains(
              'isGroup ? (message.data[\'groupId\']?.toString() ?? senderId) : senderId'));
      // Foreground unread update looks up strictly by that chatId
      expect(fcmService, contains('_storageService.getChat(chatId)'));
    });
  });
}
