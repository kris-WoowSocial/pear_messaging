import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pear_messaging/core/services/peer_ringing_notifier.dart';
import 'package:pear_messaging/features/call/call_controller.dart';

/// Behavioral tests for the peer_ringing signal path:
///  - callee emits exactly once when the call UI is presented (any platform:
///    the emission points in _handleIncomingCall/_handleCallResync are
///    platform-agnostic Dart, so Android→Android and iOS paths share it);
///  - the caller-side watchdog is now a backstop behind the server's 45s
///    no_answer instead of firing at 20s (prod forensics: client iPhone
///    woken ~11–20s late by VoIP push got a premature "Could not reach").
void main() {
  group('PeerRingingNotifier', () {
    test('emits exactly once per callId at presentation', () {
      final sent = <String>[];
      final n = PeerRingingNotifier(
        ({required callId, required callerId}) => sent.add('$callId:$callerId'),
      );
      // Socket-delivered incoming_call presentation.
      expect(n.notify(callId: 'cs_1', callerId: 'caller'), isTrue);
      // Resync re-emit for the same call must NOT re-notify.
      expect(n.notify(callId: 'cs_1', callerId: 'caller'), isFalse);
      expect(sent, ['cs_1:caller']);
    });

    test('reset allows the next call to emit', () {
      final sent = <String>[];
      final n = PeerRingingNotifier(
        ({required callId, required callerId}) => sent.add(callId),
      );
      n.notify(callId: 'cs_1', callerId: 'a');
      n.reset();
      expect(n.notify(callId: 'cs_2', callerId: 'a'), isTrue);
      expect(sent, ['cs_1', 'cs_2']);
    });

    test('empty callId/callerId never emits', () {
      var emits = 0;
      final n = PeerRingingNotifier(
        ({required callId, required callerId}) => emits++,
      );
      expect(n.notify(callId: '', callerId: 'a'), isFalse);
      expect(n.notify(callId: 'c', callerId: ''), isFalse);
      expect(emits, 0);
      expect(n.sentForCallId, isNull);
    });
  });

  group('caller watchdog (server-authoritative)', () {
    test('watchdog outlives the server 45s no_answer timeout', () {
      // The server emits call_terminated{no_answer} at 45s. The client
      // watchdog is the backstop for when even that event can't arrive.
      expect(
        CallController.dialWatchdogTimeout,
        greaterThan(const Duration(seconds: 45)),
      );
    });

    test('late wake: ringing at 15s then accept at 30s never fires', () {
      // Replay the prod sequence: callee's VoIP push wakes ~15s late; the
      // callee emits peer_ringing on presentation; caller accepts at 30s.
      // At no point may the watchdog fire.
      final state = CallState.dialing.obs;
      var watchdogFired = false;
      void fire() {
        if (CallController.shouldFireDialWatchdog(
          isCaller: true,
          state: state.value,
        )) {
          watchdogFired = true;
        }
      }

      // t=15s: peer_ringing arrives → _handlePeerRinging sets ringing.
      state.value = CallState.ringing;
      fire();
      // t=30s: call_accept → connected.
      state.value = CallState.connected;
      fire();
      expect(watchdogFired, isFalse);
    });

    test('fires only while caller is still dialing', () {
      for (final (isCaller, state, expected) in [
        (true, CallState.dialing, true),
        (true, CallState.ringing, false),
        (true, CallState.connected, false),
        (true, CallState.ended, false),
        (false, CallState.dialing, false),
      ]) {
        expect(
          CallController.shouldFireDialWatchdog(
            isCaller: isCaller,
            state: state,
          ),
          expected,
          reason: 'isCaller=$isCaller state=$state',
        );
      }
    });
  });
}
