import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String source(String path) => File(path).readAsStringSync();

/// Bug: after sending a text the attach+mic buttons stayed hidden and the
/// send arrow lingered. hasText was only refreshed inside onChanged; the
/// programmatic messageController.clear() in sendMessage never re-fired it.
void main() {
  group('input-bar buttons derive from the live controller text', () {
    final controller = source('lib/features/chat/chat_controller.dart');

    test('hasText is bound via a TextEditingController listener, not onChanged',
        () {
      expect(
        controller,
        contains('messageController.addListener(_syncHasText)'),
        reason: 'a controller listener fires for clear(), paste, delete and '
            'picker-driven changes — onChanged misses programmatic edits',
      );
    });

    test('_syncHasText reads the actual field text', () {
      expect(
        controller,
        contains(
          'hasText.value = messageController.text.trim().isNotEmpty',
        ),
      );
      // onTyping must delegate to the same derivation, not assign directly
      final onTyping = controller.substring(
        controller.indexOf('void onTyping(String text)'),
        controller.indexOf('/// Handle URL preview'),
      );
      expect(onTyping, contains('_syncHasText()'));
      expect(onTyping, isNot(contains('text.trim().isNotEmpty;')));
    });

    test('sendMessage clear() path is covered by the listener', () {
      final send = controller.substring(
        controller.indexOf('void sendMessage()'),
        controller.indexOf('void onTyping(String text)'),
      );
      expect(send, contains('messageController.clear()'));
    });
  });

  group('mechanism guarantee', () {
    test('TextEditingController.clear() DOES notify listeners', () {
      // This is exactly why the fix works — unlike onChanged, controller
      // listeners fire on clear(), the call that broke the button state.
      final c = TextEditingController(text: 'hello');
      var notified = false;
      c.addListener(() => notified = true);
      c.clear();
      expect(notified, isTrue);
      c.dispose();
    });

    test('clear() leaves text empty so hasText resolves false', () {
      final c = TextEditingController(text: '  typed  ');
      bool? hasText;
      c.addListener(() => hasText = c.text.trim().isNotEmpty);
      c.clear();
      expect(hasText, isFalse);
      c.dispose();
    });
  });
}
