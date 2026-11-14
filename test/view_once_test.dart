import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/features/chat/chat_message_model.dart';
import 'package:pear_messaging/storage/models/message_entity.dart';

String source(String path) => File(path).readAsStringSync();

MessageEntity _entity({
  bool isViewOnce = false,
  bool isViewOnceOpened = false,
  bool isMe = false,
}) {
  return MessageEntity(
    id: 'm1',
    chatId: 'c1',
    senderId: 'sender',
    receiverId: 'receiver',
    content: 'MEDIA:tok123',
    timestamp: DateTime(2026, 1, 1),
    status: MessageStatus.delivered,
    isMe: isMe,
    type: MessageType.image,
    isViewOnce: isViewOnce,
    isViewOnceOpened: isViewOnceOpened,
  );
}

void main() {
  group('MessageEntity view-once serialization', () {
    test('toJson/fromJson round-trips view-once fields', () {
      final e = _entity(isViewOnce: true, isViewOnceOpened: true);
      final back = MessageEntity.fromJson(e.toJson());
      expect(back.isViewOnce, isTrue);
      expect(back.isViewOnceOpened, isTrue);
    });

    test('legacy rows without the fields default to false (backward compat)',
        () {
      final json = _entity().toJson()
        ..remove('isViewOnce')
        ..remove('isViewOnceOpened');
      final back = MessageEntity.fromJson(json);
      expect(back.isViewOnce, isFalse);
      expect(back.isViewOnceOpened, isFalse);
    });

    test('copyWith overrides and preserves view-once flags', () {
      final e = _entity(isViewOnce: true);
      expect(e.copyWith(isViewOnceOpened: true).isViewOnce, isTrue);
      expect(e.copyWith(isViewOnceOpened: true).isViewOnceOpened, isTrue);
      // A copy that doesn't touch the flag must keep it (the status-update
      // bug class: fields silently dropped on rebuild).
      expect(e.copyWith(status: MessageStatus.read).isViewOnce, isTrue);
    });
  });

  group('ChatMessageModel view-once state', () {
    test('fromEntity carries both flags', () {
      final m = ChatMessageModel.fromEntity(
        _entity(isViewOnce: true, isViewOnceOpened: true),
      );
      expect(m.isViewOnce, isTrue);
      expect(m.isViewOnceOpened, isTrue);
    });

    test('isViewOncePending is true only before opening', () {
      expect(
        ChatMessageModel.fromEntity(_entity(isViewOnce: true))
            .isViewOncePending,
        isTrue,
      );
      expect(
        ChatMessageModel.fromEntity(
          _entity(isViewOnce: true, isViewOnceOpened: true),
        ).isViewOncePending,
        isFalse,
      );
      expect(
        ChatMessageModel.fromEntity(_entity()).isViewOncePending,
        isFalse,
      );
    });
  });

  group('bubble rendering contract', () {
    final bubble = source('lib/features/chat/chat_message_bubble.dart');

    test('image content routes to the view-once tile', () {
      expect(bubble, contains('_buildViewOnceContent()'));
      expect(
        bubble,
        contains('widget.message.isViewOnce\n              ? _buildViewOnceContent()'),
      );
    });

    test('media is never pre-fetched for view-once messages', () {
      expect(
        bubble,
        contains(
          'if (widget.message.isViewOnce) return; // never pre-fetch view-once media',
        ),
      );
      // Both preload entry points are gated
      expect(
        bubble,
        contains('if (widget.message.isViewOnce) return;'),
      );
    });

    test('tile tap is enabled only for the recipient before opening', () {
      expect(
        bubble,
        contains(
          'final canOpen = !widget.message.isMe && !opened;',
        ),
      );
      expect(bubble, contains("opened ? 'Opened' : 'Photo'"));
    });
  });

  group('send pipeline contract', () {
    final screen = source('lib/features/chat/chat_screen.dart');
    final controller = source('lib/features/chat/chat_controller.dart');
    final upload = source('lib/core/services/media_upload_service.dart');
    final socket = source('lib/core/services/socket_service.dart');

    test('preview sheet exposes the "1" view-once toggle', () {
      expect(screen, contains('_showImageSendPreview'));
      expect(screen, contains('isViewOnce.value = !isViewOnce.value'));
      expect(screen, contains('if (!controller.isGroup)'));
    });

    test('flag threads pending -> upload -> finalize -> socket', () {
      expect(
        screen,
        contains(
          'await controller.createPendingImageMessage(\n        compressedBytes,\n        isViewOnce: isViewOnce,',
        ),
        reason: 'screen passes the toggle into the pending bubble',
      );
      expect(
        controller,
        contains('isViewOnce: isViewOnce,\n    );\n\n    _appendMessage'),
        reason: 'pending entity stores the flag',
      );
      expect(
        upload,
        contains("'isViewOnce': true"),
        reason: 'upload body carries the flag for the S3 metadata tag',
      );
      expect(
        socket,
        contains("if (isViewOnce == true) 'isViewOnce': true"),
        reason: 'send_message payload carries the flag',
      );
    });
  });

  group('receive + open lifecycle contract', () {
    final controller = source('lib/features/chat/chat_controller.dart');
    final socket = source('lib/core/services/socket_service.dart');
    final storage = source('lib/core/services/local_storage_service.dart');
    final fcm = source('lib/core/services/fcm_service.dart');
    final cache = source('lib/core/services/image_cache_service.dart');
    final viewer = source('lib/features/chat/view_once_viewer_screen.dart');
    final manifestMain = source(
      'android/app/src/main/kotlin/com/vant/chat/MainActivity.kt',
    );

    test('incoming socket + FCM paths parse the flag', () {
      expect(
        controller,
        contains("isViewOnce: data['isViewOnce'] == true"),
      );
      // Both FCM MessageEntity constructions carry the flag
      expect(
        "isViewOnce: message.data['isViewOnce']?.toString() == 'true'"
            .allMatches(fcm)
            .length,
        2,
      );
    });

    test('open downloads once, views, then marks opened', () {
      final fn = controller.substring(
        controller.indexOf('Future<void> openViewOncePhoto'),
      );
      expect(fn, contains('MediaUploadService.downloadImage(token)'));
      expect(fn, contains('ViewOnceViewerScreen'));
      // mark happens AFTER the viewer returns (await Get.to) — the earlier
      // markViewOnceAsOpened call is the "already consumed" 410 branch.
      final getToIdx = fn.indexOf('await Get.to(');
      expect(getToIdx, greaterThan(-1));
      expect(fn.indexOf('markViewOnceAsOpened', getToIdx), greaterThan(-1));
    });

    test('markViewOnceAsOpened purges + persists + notifies', () {
      final fn = controller.substring(
        controller.indexOf('Future<void> markViewOnceAsOpened'),
      );
      expect(fn, contains('copyWith(isViewOnceOpened: true)'));
      expect(fn, contains('setMessageViewOnceOpened(messageId)'));
      expect(fn, contains('removeCachedImageById(messageId)'));
      expect(fn, contains('sendViewOnceOpened('));
    });

    test('storage write is box-level (no re-encryption of stored content)',
        () {
      final fn = storage.substring(
        storage.indexOf('Future<bool> setMessageViewOnceOpened'),
      );
      expect(fn, contains("..['isViewOnceOpened'] = true"));
      expect(fn, isNot(contains('encryptText')));
    });

    test('cache purge hits memory and disk', () {
      final fn = cache.substring(
        cache.indexOf('Future<void> removeCachedImageById'),
      );
      expect(fn, contains('_memoryCache.remove(key)'));
      expect(fn, contains('_cacheBox.delete(key)'));
      expect(fn, contains('fillRange'), reason: 'zero the bytes in memory');
    });

    test('socket emits and listens for view_once_opened', () {
      expect(socket, contains("_socket?.emit('view_once_opened'"));
      expect(socket, contains("_socket?.on('view_once_opened'"));
      expect(socket, contains('sendViewOnceOpened'));
    });

    test('viewer uses FLAG_SECURE on Android and zeroes bytes on exit', () {
      expect(viewer, contains("'setSecureFlag'"));
      expect(viewer, contains('fillRange'));
      expect(manifestMain, contains('SECURITY_CHANNEL'));
      expect(manifestMain, contains('FLAG_SECURE'));
    });

    test('incoming opened-notice handler is wired in both controllers', () {
      final list = source('lib/features/chat_list/chat_list_controller.dart');
      expect(list, contains('onViewOnceOpened = _handleViewOnceOpened'));
      expect(controller, contains('onViewOnceOpened = _handleViewOnceOpened'));
      // handler swap restores the previous handler on dispose
      expect(controller, contains('onViewOnceOpened = _previousViewOnceHandler'));
    });
  });
}
