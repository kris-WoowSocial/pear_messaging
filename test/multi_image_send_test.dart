import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String source(String path) => File(path).readAsStringSync();

void main() {
  final controller = source('lib/features/chat/chat_controller.dart');
  final screen = source('lib/features/chat/chat_screen.dart');

  group('multi-image sequential send', () {
    test('picker is multi-image with limit 5 and a code-side cap', () {
      expect(screen, contains('pickMultiImage(limit: _maxImagesPerSend)'));
      expect(screen, contains('_maxImagesPerSend = 5'));
      expect(
        screen,
        contains('picked.take(_maxImagesPerSend)'),
        reason: 'defensive cap even if the picker returns more',
      );
      expect(screen, contains('images at a time'));
    });

    test('uploads run sequentially — awaited inside the loop', () {
      final fn = controller.substring(
        controller.indexOf('sendImagesSequentially'),
        controller.indexOf('return results;'),
      );
      expect(fn, contains('images.take(maxPerBatch)'));
      // sequential: an await inside the for body, no Future.wait/parallelism
      expect(fn, contains('await uploadPendingImage(messageId)'));
      expect(fn, isNot(contains('Future.wait')));
      expect(fn, isNot(contains('unawaited')));
      // bubble per image, in order, before its upload starts
      expect(fn.indexOf('createPendingImageMessage'),
          lessThan(fn.indexOf('uploadPendingImage')));
    });

    test('a failed upload marks only that bubble failed — others continue', () {
      final fn = controller.substring(
        controller.indexOf('Future<bool> uploadPendingImage'),
        controller.indexOf('sendImagesSequentially'),
      );
      expect(fn, contains('MessageStatus.failed'));
      expect(
        fn,
        isNot(contains('removeWhere')),
        reason: 'failure must leave the bubble in place for tap-to-retry',
      );
      // the loop must not bail on a failed item
      final loop = controller.substring(
        controller.indexOf('sendImagesSequentially'),
        controller.indexOf('return results;'),
      );
      expect(loop, isNot(contains('break')));
      expect(loop, isNot(contains('return results')));
    });

    test('retry routes a pending image back through the upload pipeline', () {
      final retry = controller.substring(
        controller.indexOf('Future<void> retrySendMessage'),
        controller.indexOf('/// Update message status'),
      );
      expect(retry, contains("content == 'MEDIA:pending'"));
      expect(retry, contains('uploadPendingImage(messageId)'));
    });

    test('a removed queued item cannot be uploaded', () {
      final fn = controller.substring(
        controller.indexOf('Future<bool> uploadPendingImage'),
        controller.indexOf('/// Multi-image send'),
      );
      expect(
        fn,
        contains('indexWhere((msg) => msg.id == messageId) == -1'),
        reason: 'if the bubble was deleted before upload, the upload no-ops',
      );
    });
  });
}
