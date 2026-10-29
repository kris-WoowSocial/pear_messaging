import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String source(String path) => File(path).readAsStringSync();

String section(String src, String start, String end) {
  final startIndex = src.indexOf(start);
  final endIndex = src.indexOf(end, startIndex);
  expect(startIndex, greaterThanOrEqualTo(0), reason: 'missing: $start');
  expect(endIndex, greaterThan(startIndex), reason: 'missing: $end');
  return src.substring(startIndex, endIndex);
}

void main() {
  group('caller-side reachability (C1-iii)', () {
    test('initiateCall reports failure instead of a silent drop', () {
      final fn = section(
        source('lib/core/services/socket_service.dart'),
        'bool initiateCall({',
        'static Map<String, dynamic> buildCallInitiatePayload',
      );
      expect(fn, contains('return false;'));
      expect(fn, contains('return true;'));
    });

    test('dial watchdog fails a stuck outgoing call visibly with retry', () {
      final src = source('lib/features/call/call_controller.dart');
      expect(src, contains('Duration(seconds: 20)'));
      expect(src, contains('Timer(_dialWatchdogTimeout, _onDialWatchdogFired)'));
      expect(
        section(src, 'void _onDialWatchdogFired()', "title: 'Could not reach'"),
        contains("callState.value != CallState.dialing"),
      );
      expect(src, contains("actionLabel: 'Retry'"));
      expect(src, contains('_failOutreachUnreachable();'));
      // Watchdog disarmed on every forward-progress or teardown path.
      expect(
        section(src, 'void _handlePeerRinging', 'callState.value = CallState.ringing;'),
        contains('_cancelDialWatchdog();'),
      );
      expect(
        section(src, 'void _resetCallState()', '_resetCryptoState();'),
        contains('_cancelDialWatchdog();'),
      );
    });
  });

  group('VoIP token upload (C1-ii)', () {
    test('Dart registration retries with backoff and sends appVersion', () {
      final fn = section(
        source('lib/core/services/callkit_service.dart'),
        'Future<void> _registerVoipToken(String token',
        '/// Dispose',
      );
      expect(fn, contains('maxAttempts'));
      expect(fn, contains('Future.delayed'));
      expect(fn, contains("'appVersion': appVersion"));
      expect(fn, contains("'appBuild': appBuild"));
      expect(fn, contains('PackageInfo.fromPlatform()'));
    });

    test('cached-token re-register is public and respects the region gate', () {
      final fn = section(
        source('lib/core/services/callkit_service.dart'),
        'Future<void> registerCachedVoipToken() async',
        '/// Show incoming call notification',
      );
      expect(fn, contains('if (!Platform.isIOS) return;'));
      expect(fn, contains('if (!_isCallKitEnabled) return;'));
      expect(fn, contains('getDevicePushTokenVoIP'));
    });

    test('device_id regeneration triggers a token re-upload', () {
      final fn = section(
        source('lib/core/services/local_storage_service.dart'),
        'Future<void> setDeviceId(String id) async',
        '}',
      );
      expect(fn, contains('registerCachedVoipToken'));
    });

    test('native upload retries on missing device_id and POST failure', () {
      final src = source('ios/Runner/AppDelegate.swift');
      final fn = section(
        src,
        'private func registerVoipTokenWithBackend',
        'func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor',
      );
      expect(fn, contains('attempt: Int = 0'));
      expect(fn, contains('attempt + 1'));
      expect(fn, contains('CFBundleShortVersionString'));
      expect(fn, contains('CFBundleVersion'));
      expect(fn, contains('apnsEnvironment'));
    });

    test('token is re-uploaded on every applicationDidBecomeActive', () {
      final fn = section(
        source('ios/Runner/AppDelegate.swift'),
        'override func applicationDidBecomeActive',
        'override func applicationWillResignActive',
      );
      expect(fn, contains('latestVoipToken'));
      expect(fn, contains('registerVoipTokenWithBackend'));
    });
  });

  group('foreground ghost CallKit report (C1-i)', () {
    test('foreground push reports to CallKit, then awaits Dart ack before ending', () {
      final fn = section(
        source('ios/Runner/AppDelegate.swift'),
        'if isAppForeground {',
        'print("📱 PushKit: Showing CallKit UI',
      );
      // Must report BEFORE any end decision — every VoIP push requires
      // reportNewIncomingCall inside the push callback.
      expect(fn, contains('showCallkitIncoming(callData, fromPushKit: true)'));
      expect(
        fn.indexOf('showCallkitIncoming'),
        lessThan(fn.indexOf('endCall(endData)')),
      );
      // The ghost end is gated on a Dart ack: the Flutter incoming screen
      // must confirm it is showing this callId, with a ~1 s deadline.
      expect(fn, contains("invokeMethod(\"confirmIncomingCallScreen\""));
      expect(fn, contains('.now() + 1.0'));
      expect(fn, contains('decideGhostEnd(false)'));
      // The silence marker and endCall live inside the ack-confirmed branch —
      // they may not run before the ack is evaluated.
      final ackBranch = section(fn, 'if confirmed {', '} else {');
      expect(ackBranch, contains('markCallKitEndSilenced'));
      expect(ackBranch, contains('endCall(endData)'));
      // No-ack path: CallKit UI stays, nothing is ended, nothing is sent.
      final noAck = section(fn, '} else {', '}\n      if let controller');
      expect(noAck, isNot(contains('endCall')));
      expect(noAck, isNot(contains('markCallKitEndSilenced')));
      expect(noAck, isNot(contains('respondToCall')));
    });

    test('Dart acks only when the Flutter incoming screen shows that callId', () {
      final src = source('lib/features/call/call_controller.dart');
      // Registry populated before the screen is pushed…
      final show = section(
        src,
        'playIncomingRingtone();\n    _setCallScreenVisible(true);\n    _shownIncomingCallIds.add(incomingCallId);',
        "Get.toNamed('/call/incoming', arguments: data);",
      );
      expect(show, contains('_shownIncomingCallIds.add(incomingCallId)'));
      // …queried by the native handshake with a bounded wait under ~1 s…
      final handler = section(
        src,
        "call.method == 'confirmIncomingCallScreen'",
        "if (call.method == 'onCallAction')",
      );
      expect(handler, contains('_shownIncomingCallIds.contains'));
      expect(handler, contains('Duration(milliseconds: 900)'));
      expect(handler, contains('return true'));
      // …and cleared when call state resets so a stale id cannot ack a
      // future call's handshake.
      expect(
        section(src, 'void _resetCallState()', '_nativeCallHeld = false;'),
        contains('_shownIncomingCallIds.clear()'),
      );
    });

    test('native respondToCall never posts ghost ends to the server', () {
      final src = source('ios/Runner/AppDelegate.swift');
      final respond = section(
        src,
        'private func respondToCall(call: Call, action: String)',
        'x-device-id',
      );
      // Silenced consume happens BEFORE any URL/request is built.
      expect(
        respond.indexOf('consumeSilencedCallEnd'),
        lessThan(respond.indexOf('URLRequest')),
      );
      // One-shot: only the first end for a marked callId is swallowed.
      expect(
        section(src, 'private func consumeSilencedCallEnd',
            '/// Saved contact name'),
        contains('silencedCallKitIds.remove(callId)'),
      );
    });

    test('Dart swallows ghost decline/end only for marked callIds, once', () {
      final src = source('lib/core/services/callkit_service.dart');
      final consume = section(
        src,
        'Future<bool> _consumeSilencedCallKitEvent',
        '/// Handle CallKit events',
      );
      // Marker is removed on consume — a later real end for the SAME callId
      // (e.g. user accepted on the Flutter screen, then CallKit ends it)
      // processes normally; a different callId is never matched.
      expect(consume, contains('ids.remove(serverCallId)'));
      expect(consume, contains('setString'));

      final decline = section(
        src,
        'case Event.actionCallDecline:',
        'CallKitEventType.decline',
      );
      expect(
        decline.indexOf('_consumeSilencedCallKitEvent'),
        lessThan(decline.indexOf('logCallBreadcrumb(CallBreadcrumb.decline)')),
      );
      final end = section(
        src,
        'case Event.actionCallEnded:',
        'CallKitEventType.end',
      );
      expect(
        end.indexOf('_consumeSilencedCallKitEvent'),
        lessThan(end.indexOf('logCallBreadcrumb(CallBreadcrumb.ended)')),
      );
    });

    test('documented edge: lock while ringing in foreground has no CallKit fallback', () {
      // When the phone locks during a foreground ring, the ghost CallKit
      // record is already ended (after the Dart screen ack) — the callee
      // must unlock and answer in-app, or the call times out. Same as the
      // pre-change behavior (foreground pushes were dropped entirely), so
      // no regression; real CallKit only appears when the push arrives
      // while already locked/backgrounded — or when the ack never arrives.
      expect(
        source('ios/Runner/AppDelegate.swift'),
        contains('awaiting Flutter-screen ack'),
      );
    });
  });
}
