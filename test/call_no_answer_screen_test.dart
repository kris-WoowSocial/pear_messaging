/// Structure + unit tests for the caller-side "No answer" screen
/// (ff_call_no_answer_screen).
///
/// Covers: flag wiring (same pattern as ff_call_ringback), the pure
/// shouldShowCallerNoAnswer decision, marker set/clear sites, route-close
/// guards on every call screen and the dismissal watchdog, the Call again /
/// Cancel affordances, and proof that no new CallState was introduced and
/// the flag-OFF path keeps today's snackbar-and-pop exactly.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/features/call/call_controller.dart';

String _read(String path) => File(path).readAsStringSync();

/// Extracts the body of a function/section between [startMarker] and the first
/// occurrence of [endMarker] after it. Returns empty string if not found.
String _section(String src, String startMarker, String endMarker) {
  final start = src.indexOf(startMarker);
  if (start < 0) return '';
  final end = src.indexOf(endMarker, start);
  if (end < 0) return src.substring(start);
  return src.substring(start, end);
}

void main() {
  final root = Directory.current.path;
  final controllerSrc =
      _read('$root/lib/features/call/call_controller.dart');
  final flagSrc =
      _read('$root/lib/core/services/feature_flag_service.dart');
  final outgoingSrc =
      _read('$root/lib/features/call/outgoing_call_screen.dart');
  final videoSrc = _read('$root/lib/features/call/video_call_screen.dart');
  final activeSrc = _read('$root/lib/features/call/active_call_screen.dart');
  final incomingSrc =
      _read('$root/lib/features/call/incoming_call_screen.dart');

  group('ff_call_no_answer_screen flag wiring', () {
    test('flag constant, ON default, hydrate, apply and cache write exist', () {
      expect(
        flagSrc.contains("kCallNoAnswerScreen = 'ff_call_no_answer_screen'"),
        isTrue,
      );
      expect(flagSrc.contains('callNoAnswerScreen = true.obs'), isTrue);
      expect(flagSrc.contains('kCallNoAnswerScreen: true'), isTrue);
      expect(flagSrc.contains('_rc!.getBool(kCallNoAnswerScreen)'), isTrue);
      expect(
        flagSrc.contains("'ff_cache_\$kCallNoAnswerScreen'"),
        isTrue,
      );
    });
  });

  group('shouldShowCallerNoAnswer (pure decision)', () {
    test('caller + no_answer → show', () {
      expect(
        CallController.shouldShowCallerNoAnswer(
          isCaller: true,
          reason: 'no_answer',
          wasConnected: false,
          callMinimized: false,
          flagOff: false,
        ),
        isTrue,
      );
    });

    test('caller + timeout → show (same "No answer" terminal)', () {
      expect(
        CallController.shouldShowCallerNoAnswer(
          isCaller: true,
          reason: 'timeout',
          wasConnected: false,
          callMinimized: false,
          flagOff: false,
        ),
        isTrue,
      );
    });

    test('callee side never shows', () {
      expect(
        CallController.shouldShowCallerNoAnswer(
          isCaller: false,
          reason: 'no_answer',
          wasConnected: false,
          callMinimized: false,
          flagOff: false,
        ),
        isFalse,
      );
    });

    test('non-no-answer reasons never show', () {
      for (final reason in [
        'rejected',
        'declined',
        'busy',
        'ended',
        'expired',
        'duplicate_session',
        'crypto_failed',
        null,
      ]) {
        expect(
          CallController.shouldShowCallerNoAnswer(
            isCaller: true,
            reason: reason,
            wasConnected: false,
            callMinimized: false,
            flagOff: false,
          ),
          isFalse,
          reason: 'reason=$reason must not show the no-answer screen',
        );
      }
    });

    test('a connected call that ended never shows', () {
      expect(
        CallController.shouldShowCallerNoAnswer(
          isCaller: true,
          reason: 'no_answer',
          wasConnected: true,
          callMinimized: false,
          flagOff: false,
        ),
        isFalse,
      );
    });

    test('a minimized call screen keeps the snackbar path', () {
      expect(
        CallController.shouldShowCallerNoAnswer(
          isCaller: true,
          reason: 'no_answer',
          wasConnected: false,
          callMinimized: true,
          flagOff: false,
        ),
        isFalse,
      );
    });

    test('flag OFF keeps today\'s behavior', () {
      expect(
        CallController.shouldShowCallerNoAnswer(
          isCaller: true,
          reason: 'no_answer',
          wasConnected: false,
          callMinimized: false,
          flagOff: true,
        ),
        isFalse,
      );
    });
  });

  group('marker set/clear in CallController', () {
    test('marker is set in _handleCallTerminated BEFORE endCall() emits ended',
        () {
      final body = _section(
        controllerSrc,
        'void _handleCallTerminated',
        '/// Watchdog for remote-end',
      );
      expect(body.contains('shouldShowCallerNoAnswer('), isTrue);
      expect(body.contains('noAnswerUi.value = NoAnswerInfo('), isTrue);
      expect(body.contains('callNoAnswerScreen.value'), isTrue);
      final markerAt = body.indexOf('noAnswerUi.value = NoAnswerInfo(');
      final endCallAt = body.indexOf('_webrtcService.endCall();');
      expect(markerAt, greaterThan(-1));
      expect(endCallAt, greaterThan(markerAt));
    });

    test('snackbar is skipped only when the screen is presented', () {
      final body = _section(
        controllerSrc,
        'void _handleCallTerminated',
        '/// Watchdog for remote-end',
      );
      // Flag OFF / non-qualifying reasons keep today's snackbar exactly.
      expect(body.contains('if (!showNoAnswer)'), isTrue);
      expect(body.contains('_showFriendlyCallMessage('), isTrue);
    });

    test('ringback stop and history logging are unchanged in the handler', () {
      final body = _section(
        controllerSrc,
        'void _handleCallTerminated',
        '/// Watchdog for remote-end',
      );
      expect(body.contains("stopRingtone(reason: 'cancelled')"), isTrue);
      expect(body.contains('_logCallHistory('), isTrue);
      // History is logged before the marker decision — one entry per call.
      expect(
        body.indexOf('_logCallHistory('),
        lessThan(body.indexOf('shouldShowCallerNoAnswer(')),
      );
    });

    test('startCall clears a stale marker', () {
      final body = _section(
        controllerSrc,
        'Future<bool> startCall',
        '/// Call back a missed call',
      );
      expect(body.contains('noAnswerUi.value = null'), isTrue);
    });

    test('_handleIncomingCall clears the marker', () {
      final start = controllerSrc.indexOf('Future<void> _handleIncomingCall');
      expect(start, greaterThan(-1));
      final window = controllerSrc.substring(start, start + 1500);
      expect(window.contains('noAnswerUi.value = null'), isTrue);
    });

    test('_resetCallState retires only a stale (different-call) marker', () {
      final body = _section(
        controllerSrc,
        'void _resetCallState()',
        'Future<void> _setCallScreenVisible',
      );
      expect(
        body.contains('noAnswerUi.value!.callId != callId'),
        isTrue,
      );
    });

    test('_scheduleCallRouteDismissal respects the no-answer screen', () {
      final body = _section(
        controllerSrc,
        'void _scheduleCallRouteDismissal',
        '/// Handle local ICE candidate',
      );
      expect(body.contains('noAnswerUi.value != null'), isTrue);
    });
  });

  group('Call again / Cancel affordances', () {
    test('callAgain redials same peer and call type via startCall', () {
      final body = _section(
        controllerSrc,
        'void callAgainFromNoAnswer()',
        'void dismissNoAnswerScreen()',
      );
      expect(
        body.contains('startCall(info.peerId, isVideo: info.isVideo)'),
        isTrue,
      );
      // Same membership gate as the chat call buttons — no weaker copy.
      expect(body.contains('canMakeCalls'), isTrue);
      expect(body.contains('AppRoutes.stripeSubscription'), isTrue);
    });

    test('dismiss clears the marker and uses the guarded /call/ pop', () {
      final body = _section(
        controllerSrc,
        'void dismissNoAnswerScreen()',
        'void minimizeCallScreen',
      );
      expect(body.contains('noAnswerUi.value = null'), isTrue);
      expect(body.contains("route.startsWith('/call/')"), isTrue);
      expect(body.contains('popUntil'), isTrue);
      expect(body.contains("Get.offAllNamed('/chat-list')"), isTrue);
    });
  });

  group('call screens keep the route up for no-answer', () {
    test('outgoing screen guards close-on-ended and dismisses via PopScope',
        () {
      final worker = _section(
        outgoingSrc,
        'void _onCallStateChanged',
        '/// Pop this call route',
      );
      expect(worker.contains('noAnswerUi.value != null'), isTrue);
      expect(worker.contains('_closeCallRoute()'), isTrue);
      expect(outgoingSrc.contains('dismissNoAnswerScreen()'), isTrue);
      expect(outgoingSrc.contains("'No answer'"), isTrue);
      expect(outgoingSrc.contains('callAgainFromNoAnswer'), isTrue);
      expect(outgoingSrc.contains('dismissNoAnswerScreen'), isTrue);
    });

    test('video screen guards close and renders a renderer-free panel', () {
      final worker = _section(
        videoSrc,
        'void _onCallStateChanged',
        '/// Pop this call route',
      );
      expect(worker.contains('noAnswerUi.value != null'), isTrue);
      // The no-answer panel must not attach a disposed video renderer.
      final panel = _section(
        videoSrc,
        'Widget _buildNoAnswerPanel()',
        'Widget _noAnswerButton',
      );
      expect(panel.contains('RTCVideoView'), isFalse);
      expect(panel.contains('LocalCallVideoView'), isFalse);
      expect(panel.contains('RemoteCallVideoView'), isFalse);
      expect(panel.contains('dismissNoAnswerScreen'), isTrue);
      expect(videoSrc.contains('callAgainFromNoAnswer'), isTrue);
    });

    test('active screen guards close-on-ended (degraded-video fallback)', () {
      final worker = _section(
        activeSrc,
        'void _onCallStateChanged',
        '/// Pop this call route',
      );
      expect(worker.contains('noAnswerUi.value != null'), isTrue);
    });

    test('incoming screen is untouched (marker cannot co-exist)', () {
      expect(incomingSrc.contains('noAnswerUi'), isFalse);
    });
  });

  group('safety: no CallState change, no isInCall regression', () {
    test('CallState enum has no new value', () {
      final enumBody = _section(
        controllerSrc,
        'enum CallState {',
        '}',
      );
      expect(enumBody.contains('noAnswer'), isFalse);
    });

    test('isInCall/isConnecting are unchanged', () {
      expect(
        controllerSrc.contains(
          'callState.value != CallState.idle && callState.value != CallState.ended',
        ),
        isTrue,
      );
    });

    test('_resetCallState still ends with callState = ended', () {
      final body = _section(
        controllerSrc,
        'void _resetCallState()',
        'Future<void> _setCallScreenVisible',
      );
      expect(body.contains('callState.value = CallState.ended'), isTrue);
    });
  });
}
