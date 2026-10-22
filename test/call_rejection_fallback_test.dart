import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/features/call/call_controller.dart'
    show friendlyCallMessage;

String source(String path) => File(path).readAsStringSync();

String section(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex);
  expect(startIndex, greaterThanOrEqualTo(0));
  expect(endIndex, greaterThan(startIndex));
  return source.substring(startIndex, endIndex);
}

void main() {
  group('peer_update_required UX', () {
    test('rejected video calls offer a voice fallback instead of raw reason', () {
      final controller = source('lib/features/call/call_controller.dart');
      final handler = section(
        controller,
        'void _handleCallRejected(Map<String, dynamic> data)',
        '/// Handle call terminated from socket',
      );

      expect(handler, contains("reason == 'peer_update_required'"));
      expect(handler, contains('wasOutgoingVideo'));
      expect(
        handler,
        contains('offerVoiceFallback: reason == \'peer_update_required\' && wasOutgoingVideo'),
      );
    });

    test('voice fallback redials through the legacy voice path', () {
      final controller = source('lib/features/call/call_controller.dart');
      final handler = section(
        controller,
        'void _handleCallRejected(Map<String, dynamic> data)',
        '/// Handle call terminated from socket',
      );

      expect(handler, contains('startCall(rejectedPeer, isVideo: false)'));
    });

    test('fallback uses a non-blocking banner, not a modal dialog', () {
      final controller = source('lib/features/call/call_controller.dart');
      final handler = section(
        controller,
        'void _handleCallRejected(Map<String, dynamic> data)',
        '/// Handle call terminated from socket',
      );

      expect(handler, isNot(contains('Get.defaultDialog')));
      expect(handler, contains('_showFriendlyCallMessage(message)'));
    });

    test('mapping function exposes Call as voice action for video fallback', () {
      final message = friendlyCallMessage(
        'peer_update_required',
        peerName: 'Alice',
        offerVoiceFallback: true,
        onCallAsVoice: () {},
      );
      expect(message.actionLabel, 'Call as voice');
      expect(message.action, isNotNull);
    });
  });

  group('friendlyCallMessage mapping', () {
    const serverReasons = [
      'peer_update_required',
      'encryption_required',
      'unavailable',
      'offline',
      'busy',
      'declined',
      'rejected',
      'timeout',
      'no_answer',
      'duplicate_session',
      'identity_announce_required',
      'identity_binding_required',
      'identity_conflict',
      'identity_invalid',
      'crypto_failed',
      'resync_timeout',
      'rate_limited',
      'ended',
      'disconnected',
      'connection_lost',
      'expired',
    ];

    for (final reason in serverReasons) {
      test('$reason maps to non-technical text', () {
        final message = friendlyCallMessage(
          reason,
          peerName: 'Alice',
          offerVoiceFallback: reason == 'peer_update_required',
        );
        // The body must not be the raw reason code and must not contain
        // underscores (server codes are snake_case).
        expect(message.body, isNot(equals(reason)));
        expect(message.body, isNot(contains('_')));
        // The title should not be the raw code (allow user-facing words like
        // 'Busy', but reject snake_case).
        expect(message.title, isNot(contains('_')));
      });
    }

    test('unknown reason uses the default text', () {
      final message = friendlyCallMessage(
        'totally_unknown_code',
        peerName: 'Alice',
      );
      expect(
        message.body,
        "Couldn't start the call. Please try again.",
      );
      expect(message.title, 'Call failed');
    });

    test('peer_update_required offers Call as voice only when requested', () {
      final withFallback = friendlyCallMessage(
        'peer_update_required',
        peerName: 'Alice',
        offerVoiceFallback: true,
        onCallAsVoice: () {},
      );
      expect(withFallback.actionLabel, 'Call as voice');
      expect(withFallback.action, isNotNull);

      final withoutFallback = friendlyCallMessage(
        'peer_update_required',
        peerName: 'Alice',
      );
      expect(withoutFallback.actionLabel, isNull);
      expect(withoutFallback.action, isNull);
    });
  });

  group('source hygiene', () {
    test('no raw reason variable is interpolated into user-visible text', () {
      final controller = source('lib/features/call/call_controller.dart');
      final mappingEnd = controller.indexOf('/// Call Controller');
      expect(mappingEnd, greaterThan(0));
      final mappingFunction = controller.substring(0, mappingEnd);
      final rest = controller.substring(mappingEnd);

      // Inside the mapping function, interpolating the reason is expected.
      expect(mappingFunction, isNot(contains(r'$reason')));

      // Outside the mapping function, the reason code must only travel to logs
      // (debugPrint) and server payloads, never into user-visible text.
      final userVisible = rest.replaceAll(
        RegExp(r'debugPrint\([\s\S]*?^\s*\);', multiLine: true),
        '',
      );
      expect(userVisible, isNot(contains(r'$reason')));
    });
  });
}
