import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/storage/models/message_entity.dart';
import 'package:pear_messaging/storage/models/reply_to_entity.dart';

/// Contract + model tests for "Delete for Everyone" and "Edit Sent
/// Messages" (15-minute window, WhatsApp UX).
void main() {
  late String chatController;
  late String chatListController;
  late String chatBubble;
  late String chatScreen;
  late String socketService;
  late String storageService;
  late String serverHandlers;
  late String serverEvents;

  setUpAll(() {
    chatController =
        File('lib/features/chat/chat_controller.dart').readAsStringSync();
    chatListController =
        File('lib/features/chat_list/chat_list_controller.dart')
            .readAsStringSync();
    chatBubble =
        File('lib/features/chat/chat_message_bubble.dart').readAsStringSync();
    chatScreen =
        File('lib/features/chat/chat_screen.dart').readAsStringSync();
    socketService =
        File('lib/core/services/socket_service.dart').readAsStringSync();
    storageService = File('lib/core/services/local_storage_service.dart')
        .readAsStringSync();
    serverHandlers =
        File('../vant_chatting/server/src/sockets/chat.handlers.js')
            .readAsStringSync();
    serverEvents =
        File('../vant_chatting/server/src/constants/socket_events.js')
            .readAsStringSync();
  });

  group('MessageEntity model', () {
    test('new fields serialize and round-trip', () {
      final now = DateTime.now().toUtc();
      final entity = MessageEntity(
        id: 'm1',
        chatId: 'c1',
        senderId: 's1',
        receiverId: 'r1',
        content: 'hello',
        timestamp: now,
        status: MessageStatus.read,
        isMe: true,
        isDeletedForEveryone: true,
        deletedAt: now,
        isEdited: true,
        editedAt: now,
      );
      final restored = MessageEntity.fromJson(entity.toJson());
      expect(restored.isDeletedForEveryone, isTrue);
      expect(restored.deletedAt, isNotNull);
      expect(restored.isEdited, isTrue);
      expect(restored.editedAt, isNotNull);
    });

    test('backward-compatible defaults for pre-feature stored messages', () {
      final restored = MessageEntity.fromJson({
        'id': 'old1',
        'chatId': 'c1',
        'senderId': 's1',
        'receiverId': 'r1',
        'content': 'legacy',
        'timestamp': DateTime.now().toIso8601String(),
        'status': 'sent',
        'isMe': false,
      });
      expect(restored.isDeletedForEveryone, isFalse);
      expect(restored.deletedAt, isNull);
      expect(restored.isEdited, isFalse);
      expect(restored.editedAt, isNull);
    });

    test('toTombstone strips content, media, reply and reactions', () {
      final entity = MessageEntity(
        id: 'm2',
        chatId: 'c1',
        senderId: 's1',
        receiverId: 'r1',
        content: 'secret text',
        timestamp: DateTime.now(),
        status: MessageStatus.read,
        isMe: true,
        mediaToken: 'tok123',
        replyTo: ReplyToEntity(
          messageId: 'm0',
          content: 'quoted',
          senderId: 's1',
          senderName: 'Me',
          type: MessageType.text,
        ),
        reactions: const {'s1': '👍'},
        fileName: 'doc.pdf',
        audioDuration: 12,
        expiresAt: 999,
        isViewOnce: true,
      );
      final tomb = entity.toTombstone();
      expect(tomb.isDeletedForEveryone, isTrue);
      expect(tomb.deletedAt, isNotNull);
      expect(tomb.content, isEmpty);
      expect(tomb.mediaToken, isNull);
      expect(tomb.replyTo, isNull);
      expect(tomb.reactions, isEmpty);
      expect(tomb.fileName, isNull);
      expect(tomb.audioDuration, isNull);
      expect(tomb.expiresAt, isNull);
      expect(tomb.isViewOnce, isFalse);
      // Identity survives
      expect(tomb.id, entity.id);
      expect(tomb.chatId, entity.chatId);
      expect(tomb.isMe, entity.isMe);
      expect(tomb.timestamp, entity.timestamp);
    });
  });

  group('Delete for Everyone — storage contract', () {
    test('tombstone write clears every content field', () {
      final start = storageService
          .indexOf('Future<void> setMessageDeletedForEveryone');
      final end = storageService.indexOf('Future<void> setMessageEdited');
      final body = storageService.substring(start, end);
      for (final key in [
        'mediaToken',
        'replyTo',
        'fileName',
        'fileSize',
        'audioDuration',
        'waveformData',
        'encryptedAudioData',
        'reactions',
        'expiresAt',
        'isViewOnce',
      ]) {
        expect(body, contains('json[\'$key\']'), reason: '$key not cleared');
      }
      expect(body, contains("json['isDeletedForEveryone'] = true"));
      expect(body, contains("json['content'] = ''"));
    });

    test('local tombstone is applied before the socket emit', () {
      final start =
          chatController.indexOf('deleteMessageForEveryone(String messageId)');
      final end =
          chatController.indexOf('Future<void> deleteMessageForMe', start);
      final body = chatController.substring(start, end);
      // Local write must precede relay (offline devices still tombstone).
      expect(body.indexOf('_applyTombstoneInMemory'),
          lessThan(body.indexOf('sendDeleteMessage(')));
      expect(body, contains('setMessageDeletedForEveryone'));
      expect(body, contains('enqueueControlEvent'));
    });
  });

  group('Edit — eligibility window', () {
    test('canEditMessage gates on own text, non-deleted, < 15 min', () {
      final start = chatController.indexOf('bool canEditMessage');
      final end = chatController.indexOf('void startEdit');
      final body = chatController.substring(start, end);
      expect(body, contains('msg.isMe'));
      expect(body, contains('!msg.isDeletedForEveryone'));
      expect(body, contains('MessageType.text'));
      expect(body, contains('const Duration(minutes: 15)'));
    });

    test('submitEdit preserves messageId and marks isEdited', () {
      final start = chatController.indexOf('void submitEdit()');
      final end =
          chatController.indexOf('Future<void> deleteMessageForEveryone');
      final body = chatController.substring(start, end);
      expect(body, contains('isEdited: true'));
      expect(body, contains('msg.id')); // same id, never a new uuid
      expect(body, isNot(contains('_uuid.v4()')));
      expect(body, contains('enqueueControlEvent'));
    });

    test('receiver ignores edits arriving after a tombstone', () {
      final start = chatController.indexOf('void _handleIncomingEdited');
      final end = chatController.indexOf('_flushControlOutbox', start);
      final body = chatController.substring(start, end);
      expect(body, contains('isDeletedForEveryone'));
    });
  });

  group('Bubble UX contract', () {
    test('tombstone text matches WhatsApp labels', () {
      expect(chatBubble, contains('You deleted this message'));
      expect(chatBubble, contains('This message was deleted'));
      expect(chatBubble, contains('FontStyle.italic'));
      expect(chatBubble, contains('Icons.block'));
    });

    test('menu offers Edit only via canEditMessage and delete variants', () {
      expect(chatBubble, contains('Delete for Everyone'));
      expect(chatBubble, contains('Delete for Me'));
      expect(chatBubble, contains('canEditMessage(widget.message)'));
    });

    test('Edited label rendered beside timestamp, never on tombstones', () {
      expect(chatBubble, contains('Edited'));
      expect(chatBubble, contains('_buildEditedLabel'));
      expect(chatBubble, contains('widget.message.isEdited'));
    });

    test('composer shows an Edit preview bar that suppresses the reply bar',
        () {
      expect(chatScreen, contains('EditPreviewBar('));
      expect(chatScreen,
          contains('controller.editingMessage.value == null'));
      expect(chatScreen, contains('controller.cancelEdit'));
    });
  });

  group('Chat list sync contract', () {
    test('tombstone preview text is derived for both directions', () {
      expect(chatListController, contains('You deleted this message'));
      expect(chatListController, contains('This message was deleted'));
    });

    test('pending replay routes control events before the dedup check', () {
      final start =
          chatListController.indexOf('for (final message in messages)');
      final end = chatListController
          .indexOf('Message already in Hive', start);
      final body = chatListController.substring(start, end);
      expect(body, contains("eventType == 'message_deleted'"));
      expect(body, contains("eventType == 'message_edited'"));
      // Routed BEFORE the exists-check + ack collection
      expect(body.indexOf("eventType == 'message_deleted'"),
          lessThan(body.indexOf('_messageExists')));
    });
  });

  group('Socket layer contract', () {
    test('emits and listens for both events', () {
      expect(socketService, contains("'delete_message'"));
      expect(socketService, contains("'edit_message'"));
      expect(socketService, contains("'message_deleted'"));
      expect(socketService, contains("'message_edited'"));
      expect(socketService, contains('onMessageDeleted'));
      expect(socketService, contains('onMessageEdited'));
    });

    test('controller swaps handlers on entry and restores on dispose', () {
      expect(
          chatController, contains('onMessageDeleted = _handleIncomingDeleted'));
      expect(
          chatController, contains('onMessageEdited = _handleIncomingEdited'));
      expect(chatController,
          contains('onMessageDeleted = _previousMessageDeletedHandler'));
      expect(chatController,
          contains('onMessageEdited = _previousMessageEditedHandler'));
    });

    test('offline control events persist in a Hive outbox and flush', () {
      expect(storageService, contains('control_outbox'));
      expect(storageService, contains('enqueueControlEvent'));
      expect(chatController, contains('_flushControlOutbox'));
    });
  });

  group('Server contract', () {
    test('event constants registered on both sides', () {
      expect(serverEvents, contains('DELETE_MESSAGE: "delete_message"'));
      expect(serverEvents, contains('EDIT_MESSAGE: "edit_message"'));
      expect(serverEvents, contains('MESSAGE_DELETED: "message_deleted"'));
      expect(serverEvents, contains('MESSAGE_EDITED: "message_edited"'));
    });

    test('handlers validate sender, window and queue offline', () {
      expect(serverHandlers, contains('handleDeleteMessage'));
      expect(serverHandlers, contains('handleEditMessage'));
      expect(serverHandlers,
          contains('senderId !== senderDeviceId'));
      expect(serverHandlers, contains('15 * 60 * 1000 + 30 * 1000'));
      expect(serverHandlers, contains('queueControlEvent'));
      expect(serverHandlers,
          contains('connection.getDeviceIdForSocket(socket.id)'));
    });
  });
}
