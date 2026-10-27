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

  group('iOS end-call: no stuck screens', () {
    final controller = 'lib/features/call/call_controller.dart';

    String method(String code, String signature) {
      final start = code.indexOf(signature);
      final rest = code.substring(start);
      final next = rest.indexOf('\n  ///', 1);
      final end = next > 0 ? next : rest.length;
      return rest.substring(0, end);
    }

    test('_resetCallState schedules the guarded route-dismissal watchdog', () {
      final body = method(source(controller), 'void _resetCallState()');
      expect(
        body,
        contains('_scheduleCallRouteDismissal'),
        reason: 'every end path (decline, remote end, local end, timeout, '
            'CallKit end) funnels through _resetCallState — the watchdog '
            'must live there so no call route can stay up',
      );
    });

    test('route-dismissal watchdog uses guarded pop + /chat-list fallback', () {
      final body =
          method(source(controller), 'void _scheduleCallRouteDismissal');
      expect(body, contains("startsWith('/call/')"));
      expect(body, contains('navigator.canPop()'));
      expect(body, contains("'/chat-list'"));
      expect(
        body,
        contains('_latestIncomingCallData != null'),
        reason: 'a new call ringing inside the delay must not be dismissed',
      );
    });

    test('CallKit end requires attribution: match current or ringing call',
        () {
      final body = method(source(controller), 'void _handleCallKitEnd');
      expect(
        body,
        contains('callId != currentCallId.value && callId != latestCallId'),
        reason: 'a CallKit end must match the active call or the ringing '
            'call — a foreign/unresolvable id must be ignored',
      );
      expect(body, contains('callId == null || callId.isEmpty'));
      expect(body, contains('_isRecentlyEnded(callId)'));
      expect(body, contains('endCall()'));
    });

    test('late CallKit end for a just-ended call cannot kill a new call', () {
      final code = source(controller);
      // _resetCallState records the ended callId so a delayed duplicate
      // CallKit event for call A is ignored even after call B has started.
      final reset = method(code, 'void _resetCallState()');
      expect(reset, contains('_markRecentlyEnded(callId)'));
      // Both event handlers check the recently-ended registry before acting.
      final end = method(code, 'void _handleCallKitEnd');
      final decline = method(code, 'void _handleCallKitDecline');
      expect(end.indexOf('_isRecentlyEnded'), lessThan(end.indexOf('endCall()')));
      expect(decline, contains('_isRecentlyEnded(callId)'));
    });

    test('CallKit decline uses guarded pop + /chat-list and HTTP fallback',
        () {
      final body = method(source(controller), 'void _handleCallKitDecline');
      expect(body, contains('navigator.canPop()'));
      expect(body, contains("Get.offAllNamed('/chat-list')"));
      expect(
        body,
        contains('callId != ringingId && callId != currentCallId.value'),
        reason: 'a decline for a foreign call must be ignored, not applied '
            'to whatever happens to be ringing',
      );
      expect(
        body,
        contains("_terminateCallOverHttp(callId, 'reject')"),
        reason: 'decline must still reach the caller when the socket is down',
      );
    });

    test('CallKit ring timeout is handled and resets call state', () {
      final code = source(controller);
      expect(code, contains('case CallKitEventType.timeout:'));
      final body = method(code, 'void _handleCallKitTimeout');
      expect(body, contains('isInCall'));
      expect(body, contains('_resetCallState()'));
      expect(body, contains('_ringtoneService.stopRingtone()'));
    });
  });
}
