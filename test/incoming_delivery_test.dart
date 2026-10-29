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
}
