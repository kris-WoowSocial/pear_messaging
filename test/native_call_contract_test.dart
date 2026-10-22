import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String source(String path) => File(path).readAsStringSync();

void main() {
  group('Android Telecom voice-call contract', () {
    test('PhoneAccount is self-managed and exposes SIP call handling', () {
      final manager = source(
        'android/app/src/main/kotlin/com/vant/chat/VantCallManager.kt',
      );

      expect(manager, contains('PhoneAccount.CAPABILITY_SELF_MANAGED'));
      expect(
          manager, contains('PhoneAccount.CAPABILITY_SUPPORTS_VIDEO_CALLING'));
      expect(manager, contains('PhoneAccount.SCHEME_SIP'));
      expect(manager, contains('registerPhoneAccount'));
    });

    test('Telecom connection supports hold without disconnecting the call', () {
      final service = source(
        'android/app/src/main/kotlin/com/vant/chat/VantConnectionService.kt',
      );
      final connection = source(
        'android/app/src/main/kotlin/com/vant/chat/VantConnection.kt',
      );

      expect(service, contains('Connection.CAPABILITY_HOLD'));
      expect(service, contains('Connection.CAPABILITY_SUPPORT_HOLD'));
      expect(connection, contains('override fun onHold()'));
      expect(connection, contains('com.vant.chat.CALL_HELD'));
      expect(connection, contains('override fun onUnhold()'));
      expect(connection, contains('com.vant.chat.CALL_UNHELD'));
      expect(connection, contains('setActive()'));
      // onHold must not destroy the Telecom connection; keep-alive is the core
      // WhatsApp-style behavior when a cellular/VoIP call preempts ours.
      final holdBody = connection
          .split('override fun onHold()')
          .last
          .split('override fun onUnhold()')
          .first;
      expect(holdBody, isNot(contains('destroy()')));
    });

    test('native call-held broadcasts are forwarded to Flutter', () {
      final activity = source(
        'android/app/src/main/kotlin/com/vant/chat/MainActivity.kt',
      );

      expect(activity, contains('"com.vant.chat.CALL_HELD"'));
      expect(activity, contains('"type" to "call_held"'));
      expect(activity, contains('"com.vant.chat.CALL_UNHELD"'));
      expect(activity, contains('"type" to "call_unheld"'));
    });

    test('camera foreground-service type requires runtime camera permission',
        () {
      final service = source(
        'android/app/src/main/kotlin/com/vant/chat/CallForegroundService.kt',
      );

      expect(
        service,
        contains('Manifest.permission.CAMERA'),
      );
      expect(
        service,
        contains('PackageManager.PERMISSION_GRANTED'),
      );
      expect(
        service,
        contains('ongoingIsVideo && hasCameraPermission'),
      );
      expect(
        service,
        contains('FOREGROUND_SERVICE_TYPE_CAMERA'),
      );
      // Voice calls continue to use only microphone/phone-call types.
      expect(
        service,
        contains('FOREGROUND_SERVICE_TYPE_MICROPHONE'),
      );
      expect(
        service,
        contains('FOREGROUND_SERVICE_TYPE_PHONE_CALL'),
      );
    });
  });

  group('encrypted call acceptance contract', () {
    test('incoming encrypted offers do not require a redundant resync', () {
      final screen = source('lib/features/call/incoming_call_screen.dart');
      expect(screen, contains("callData['crypto'] is Map"));
      expect(screen, contains('controller.acceptCall(callData)'));
    });
  });
}
