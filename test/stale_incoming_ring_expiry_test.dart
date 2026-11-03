import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/features/call/call_controller.dart';

String controllerSource() =>
    File('lib/features/call/call_controller.dart').readAsStringSync();

String methodBody(String source, String signature, {int window = 3000}) {
  final start = source.indexOf(signature);
  expect(start, isNonNegative, reason: '$signature must exist');
  final end = (start + window).clamp(0, source.length);
  return source.substring(start, end);
}

void main() {
  group('isIncomingRingExpired — local-clock staleness predicate', () {
    const window = CallController.incomingRingWindowMs;
    const receivedAt = 1000000;

    test('a fresh call still rings at 44 s', () {
      expect(
        CallController.isIncomingRingExpired(
          receivedAtMs: receivedAt,
          nowMs: receivedAt + const Duration(seconds: 44).inMilliseconds,
        ),
        isFalse,
      );
    });

    test('a call held more than 45 s is stale', () {
      expect(
        CallController.isIncomingRingExpired(
          receivedAtMs: receivedAt,
          nowMs: receivedAt + const Duration(seconds: 45).inMilliseconds + 1,
        ),
        isTrue,
      );
    });

    test('exactly at the window boundary still rings (> not >=)', () {
      expect(
        CallController.isIncomingRingExpired(
          receivedAtMs: receivedAt,
          nowMs: receivedAt + window,
        ),
        isFalse,
      );
    });

    test('missing receipt stamp fails open — call keeps ringing', () {
      expect(
        CallController.isIncomingRingExpired(
          receivedAtMs: null,
          nowMs: receivedAt + const Duration(minutes: 10).inMilliseconds,
        ),
        isFalse,
      );
    });

    test('window matches the server ring timeout of 45 s', () {
      expect(window, 45000);
    });
  });

  group('wiring — resume expiry is platform-shared Dart', () {
    test('resumed lifecycle calls the expiry check before reconciler', () {
      final src = controllerSource();
      final resumed = src.indexOf('state == AppLifecycleState.resumed');
      expect(resumed, isNonNegative);
      final block = src.substring(resumed, resumed + 400);
      expect(block, contains('_expireStaleIncomingCall()'));
      expect(
        block.indexOf('_expireStaleIncomingCall()'),
        lessThan(block.indexOf('reconcileNativeCalls()')),
        reason: 'stale presentations must expire before native reconcile',
      );
    });

    test('expiry check uses only the local receipt stamp — never the server '
        'push timestamp vs device clock', () {
      final body = methodBody(controllerSource(), 'void _expireStaleIncomingCall()');
      expect(body, contains("data['receivedAtMs']"));
      expect(body, isNot(contains("data['timestamp']")),
          reason: 'comparing server timestamp to device clock reintroduces '
              'clock-skew dismissal bugs');
      expect(body, isNot(contains('Platform.')),
          reason: 'the expiry path must be shared Dart — identical on '
              'Android and iOS');
    });

    test('every _latestIncomingCallData write site stamps receivedAtMs', () {
      final src = controllerSource();
      // Socket incoming handler, native-incoming handler, and call_resync
      // re-emit must all stamp local receipt time.
      final stampCount = RegExp('receivedAtMs').allMatches(src).length;
      expect(stampCount, greaterThanOrEqualTo(5),
          reason: 'receivedAtMs must be written at all three storage sites '
              'plus the predicate and expiry reader');
    });
  });
}
