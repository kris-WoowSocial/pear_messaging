import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
        'String _friendlyRejectionReason',
      );

      expect(handler, contains("reason == 'peer_update_required'"));
      expect(handler, contains('wasOutgoingVideo'));
      expect(handler, contains('_showPeerUpdateRequiredFallback(rejectedPeer)'));
      expect(
        handler.indexOf('_showPeerUpdateRequiredFallback(rejectedPeer)'),
        greaterThan(handler.indexOf("reason == 'peer_update_required'")),
      );
    });

    test('voice fallback redials through the legacy voice path', () {
      final controller = source('lib/features/call/call_controller.dart');
      final fallback = section(
        controller,
        'void _showPeerUpdateRequiredFallback(String peerDeviceId)',
        '/// Handle call terminated from socket',
      );

      expect(fallback, contains('Get.defaultDialog'));
      expect(fallback, contains('Call as voice'));
      expect(fallback, contains('startCall(peerDeviceId, isVideo: false)'));
    });

    test('rejection reasons are surfaced as friendly text', () {
      final controller = source('lib/features/call/call_controller.dart');
      final mapper = section(
        controller,
        'String _friendlyRejectionReason(String? reason)',
        'void _showPeerUpdateRequiredFallback',
      );

      expect(mapper, contains("case 'peer_update_required':"));
      expect(
        mapper,
        contains('The other device needs an app update to support this call.'),
      );
      expect(mapper, contains("case 'encryption_required':"));
      expect(
        mapper,
        contains(
          'This call requires end-to-end encryption support on both devices.',
        ),
      );
    });
  });
}
