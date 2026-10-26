import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String source(String path) => File(path).readAsStringSync();

void main() {
  group('call screens close reactively when callState becomes ended/idle', () {
    final screens = [
      'lib/features/call/active_call_screen.dart',
      'lib/features/call/outgoing_call_screen.dart',
      'lib/features/call/incoming_call_screen.dart',
      'lib/features/call/video_call_screen.dart',
    ];

    for (final path in screens) {
      test('$path watches callState and pops its own route', () {
        final code = source(path);
        expect(
          code,
          contains('ever(_controller.callState, _onCallStateChanged)'),
          reason: 'screen must install a reactive callState worker',
        );
        expect(
          code,
          contains('state == CallState.ended || state == CallState.idle'),
          reason: 'worker must react to ended/idle',
        );
        expect(
          code,
          contains('navigator.popUntil'),
          reason: 'screen must pop its own call route',
        );
        expect(
          code,
          contains('navigator.canPop()'),
          reason:
              'screen must guard the pop — when the call route is the root '
              'it falls back to /chat-list instead of an empty stack',
        );
        expect(
          code,
          contains("route.settings.name != routeName"),
          reason: 'popUntil must target the call route, not whatever is on top',
        );
      });
    }

    test('end-call buttons do not pop arbitrarily (no Get.back after endCall)', () {
      final active = source('lib/features/call/active_call_screen.dart');
      final outgoing = source('lib/features/call/outgoing_call_screen.dart');
      final video = source('lib/features/call/video_call_screen.dart');

      // After tapping end call, the screen should rely on the reactive worker.
      expect(active, isNot(contains('controller.endCall();\n        Get.back();')));
      expect(outgoing, isNot(contains('controller.endCall();\n        Get.back();')));
      expect(video, isNot(contains('_controller.endCall();\n                            Get.back();')));
    });
  });

  group('socket reconnect during a call asks the server for status', () {
    test('SocketService emits call_status event', () {
      final socketService = source('lib/core/services/socket_service.dart');
      final method = socketService.substring(
        socketService.indexOf('void requestCallStatus'),
        socketService.indexOf('/// Request call resync'),
      );
      expect(method, contains("emit('call_status'"));
      expect(method, contains("{'callId': callId}"));
    });

    test('CallController requests call status on reconnect when in a call', () {
      final controller = source('lib/features/call/call_controller.dart');
      final listener = controller.substring(
        controller.indexOf('ever(_socketService.isRegistered'),
        controller.indexOf('});\n\n    _setupCallKitListener'),
      );
      expect(listener, contains('requestCallStatus'));
      expect(listener, contains('currentCallId.value.isNotEmpty && isInCall'));
    });

    test('CallController handles call_status_response with exists=false', () {
      final controller = source('lib/features/call/call_controller.dart');
      final handler = controller.substring(
        controller.indexOf('void _handleCallStatusResponse'),
        controller.indexOf('/// Start call duration update timer'),
      );
      expect(handler, contains("data['exists'] == true"));
      expect(handler, contains('_resetCallState'));
      expect(handler, contains('_showFriendlyCallMessage'));
    });
  });

  group('peer connection watchdog', () {
    test('WebRTC service has a named 20-second connection-lost watchdog', () {
      final webrtc = source('lib/core/services/webrtc_call_service.dart');
      expect(
        webrtc,
        contains('static const _connectionLostWatchdogSeconds = 20'),
      );
      expect(webrtc, contains('_startConnectionLostWatchdog'));
    });

    test('watchdog ends the call with connection_lost reason', () {
      final webrtc = source('lib/core/services/webrtc_call_service.dart');
      final watchdog = webrtc.substring(
        webrtc.indexOf('_startConnectionLostWatchdog'),
        webrtc.indexOf('/// Internal cleanup'),
      );
      expect(
        watchdog,
        contains("onCallStateChange?.call('ended', reason: 'connection_lost')"),
      );
    });

    test('watchdog is cancelled when the connection recovers', () {
      final webrtc = source('lib/core/services/webrtc_call_service.dart');
      final connectedCase = webrtc.substring(
        webrtc.indexOf("case RTCPeerConnectionState.RTCPeerConnectionStateConnected:"),
        webrtc.indexOf("case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:"),
      );
      expect(connectedCase, contains('_connectionLostWatchdog?.cancel'));
    });
  });
}
