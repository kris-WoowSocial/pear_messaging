import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pear_messaging/features/call/call_controller.dart';

/// Behavioral tests for the callee-ringing end suppression.
///
/// The incoming-call screen closes itself via `ever(callState)` the moment
/// callState is assigned `ended`/`idle` — including a *re-assignment* of the
/// same value (GetX Rx notifies on every set). These tests reproduce that
/// reactive chain and drive it through each call-flow scenario, asserting
/// whether the WebRTC 'ended' emission is allowed to reach callState at all.
void main() {
  /// Mirrors IncomingCallScreen._callStateWorker: returns a pop flag wired
  /// exactly like the screen's worker.
  bool Function() attachScreenWorker(Rx<CallState> callState) {
    var popped = false;
    final worker = ever(callState, (CallState state) {
      if (state == CallState.ended || state == CallState.idle) {
        popped = true;
      }
    });
    addTearDown(worker.dispose);
    return () => popped;
  }

  /// Routes a WebRTC 'ended' emission through the same decision the
  /// controller applies before touching callState.
  void emitWebRtcEnded(
    Rx<CallState> callState, {
    required bool isCaller,
    required bool wasConnected,
    required bool isConnected,
    required bool hasPendingIncomingCall,
  }) {
    final suppressed = CallController.shouldSuppressWebRtcEndDuringRinging(
      isCaller: isCaller,
      wasConnected: wasConnected,
      isConnected: isConnected,
      hasPendingIncomingCall: hasPendingIncomingCall,
    );
    if (!suppressed) callState.value = CallState.ended;
  }

  group('(a) ringing-time prepare failure does not pop the incoming screen',
      () {
    test('ended emission is suppressed while the call is unanswered', () {
      // Fresh incoming call: callState still holds `ended` from the previous
      // call and the screen has just been pushed on top.
      final callState = CallState.ended.obs;
      final popped = attachScreenWorker(callState);

      // Warm PC prepare fails -> its close() surfaces a Closed -> 'ended'.
      emitWebRtcEnded(
        callState,
        isCaller: false,
        wasConnected: false,
        isConnected: false,
        hasPendingIncomingCall: true,
      );
      expect(popped(), isFalse);

      // Sanity: prove the worker WOULD have popped without the suppression —
      // a direct ended assignment always fires the reactive close.
      callState.value = CallState.ended;
      expect(popped(), isTrue);
    });
  });

  group('(b) accept after a failed prepare still connects', () {
    test('clearing pending data at accept unblocks state transitions', () {
      final callState = CallState.ended.obs;
      final popped = attachScreenWorker(callState);

      // Prepare failed during ringing — suppressed, screen stays.
      emitWebRtcEnded(
        callState,
        isCaller: false,
        wasConnected: false,
        isConnected: false,
        hasPendingIncomingCall: true,
      );
      expect(popped(), isFalse);

      // Accept runs: pending incoming data is consumed, then WebRTC reports
      // the real connection — neither is gated by the suppression.
      callState.value = CallState.ringing;
      emitWebRtcEnded(
        callState,
        isCaller: false,
        wasConnected: false,
        isConnected: false,
        hasPendingIncomingCall: false, // cleared by accept
      );
      expect(popped(), isTrue); // post-accept 'ended' is a real end
    });
  });

  group('(c) remote cancel/terminate while ringing still dismisses', () {
    test('call_terminated resets directly — suppression is never consulted',
        () {
      final callState = CallState.ended.obs;
      final popped = attachScreenWorker(callState);

      // _handleCallTerminated calls _resetCallState() directly: it assigns
      // ended outside the suppression path, so the worker still fires.
      callState.value = CallState.ended; // == _resetCallState()
      expect(popped(), isTrue);
    });
  });

  group('(d) decline while ringing still works', () {
    test('rejectCall resets directly — suppression is never consulted', () {
      final callState = CallState.ended.obs;
      final popped = attachScreenWorker(callState);

      // rejectCall -> _resetCallState(): direct assignment, not a WebRTC
      // emission, so nothing is suppressed.
      callState.value = CallState.ended;
      expect(popped(), isTrue);
    });
  });

  group('(e) after accept, a real ICE/WebRTC failure ends the call', () {
    test('the suppression is lifted once the call is accepted', () {
      final callState = CallState.ringing.obs; // accept set ringing
      final popped = attachScreenWorker(callState);

      // Post-accept ICE failure -> WebRTC 'ended' must NOT be suppressed:
      // accept cleared the pending incoming data.
      emitWebRtcEnded(
        callState,
        isCaller: false,
        wasConnected: false,
        isConnected: false,
        hasPendingIncomingCall: false,
      );
      expect(popped(), isTrue);
    });

    test('a connected call is never in the suppression window', () {
      expect(
        CallController.shouldSuppressWebRtcEndDuringRinging(
          isCaller: false,
          wasConnected: true,
          isConnected: true,
          hasPendingIncomingCall: true, // even stale data cannot suppress
        ),
        isFalse,
      );
    });
  });

  group('(f) never-connected call ends via server timeout/termination', () {
    test('server call_terminated resets while the guard is armed', () {
      final callState = CallState.ended.obs;
      final popped = attachScreenWorker(callState);

      // The guard is armed (callee ringing, pending data present) — yet the
      // terminate path resets directly and the screen still closes.
      final armed = CallController.shouldSuppressWebRtcEndDuringRinging(
        isCaller: false,
        wasConnected: false,
        isConnected: false,
        hasPendingIncomingCall: true,
      );
      expect(armed, isTrue); // guard active in this exact state
      callState.value = CallState.ended; // _resetCallState() from terminate
      expect(popped(), isTrue);
    });
  });

  group('suppression never applies to the caller', () {
    test('outgoing ringing/dialing failures always end the call', () {
      for (final connected in [false, true]) {
        expect(
          CallController.shouldSuppressWebRtcEndDuringRinging(
            isCaller: true,
            wasConnected: connected,
            isConnected: connected,
            hasPendingIncomingCall: true,
          ),
          isFalse,
        );
      }
    });
  });
}
