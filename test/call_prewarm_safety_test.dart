import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-inspection tests proving the ring-time pre-warm path (socket
/// resync, PC prewarm/prepare, crypto pre-derivation, engine prewarm)
/// never touches media, never signals acceptance, and that every
/// not-answered outcome (decline, caller cancel, timeout, second
/// incoming call) disposes the prepared resources.
String src(String path) => File(path).readAsStringSync();

String section(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex);
  expect(startIndex, greaterThanOrEqualTo(0), reason: 'missing: $start');
  expect(endIndex, greaterThan(startIndex), reason: 'missing: $end');
  return source.substring(startIndex, endIndex);
}

void main() {
  final webrtc = src('lib/core/services/webrtc_call_service.dart');
  final controller = src('lib/features/call/call_controller.dart');
  final crypto = src('lib/core/services/call_signaling_crypto.dart');
  final socket = src('lib/core/services/socket_service.dart');
  final fcmService =
      src('android/app/src/main/kotlin/com/vant/chat/VantFirebaseMessagingService.kt');
  final callManager =
      src('android/app/src/main/kotlin/com/vant/chat/VantCallManager.kt');

  group('pre-Accept invariants — nothing user-visible happens early', () {
    test('prewarmPeerConnection creates no media and applies no description', () {
      final body = section(
        webrtc,
        'Future<bool> prewarmPeerConnection()',
        '/// Create the PeerConnection and apply the caller',
      );
      expect(body, isNot(contains('getUserMedia')));
      expect(body, isNot(contains('mediaDevices')));
      expect(body, isNot(contains('setRemoteDescription')));
      expect(body, isNot(contains('setLocalDescription')));
      expect(body, isNot(contains('createAnswer')));
      expect(body, isNot(contains('createOffer')));
    });

    test('prepareIncomingCall captures no media and sends no answer', () {
      final body = section(
        webrtc,
        'Future<bool> prepareIncomingCall({',
        '/// Create peer connection with per-call ICE servers',
      );
      // Accepts the remote offer only — never creates/sends a local answer.
      expect(body, isNot(contains('getUserMedia')));
      expect(body, isNot(contains('mediaDevices')));
      expect(body, isNot(contains('createAnswer')));
      expect(body, isNot(contains('onLocalDescription')));
      // No local tracks are added during ringing.
      expect(body, isNot(contains('addTrack')));
    });

    test('ring-time prepare is skipped when a call is already active', () {
      final prewarm = section(
        webrtc,
        'Future<bool> prewarmPeerConnection()',
        '/// Create the PeerConnection and apply the caller',
      );
      expect(prewarm, contains('_peerConnection != null || isInCall'));
      final prepare = section(
        webrtc,
        'Future<bool> prepareIncomingCall({',
        '/// Create peer connection with per-call ICE servers',
      );
      expect(prepare, contains('_incomingPrepared'));
      expect(prepare, contains('already in progress'));
    });

    test('crypto prepareAnswer derives keys but never emits an answer', () {
      final body = section(
        crypto,
        'Future<void> prepareAnswer({',
        'Future<void> _prepareAnswerCore({',
      );
      // The ring-time prepare must not mark the handshake answered or
      // complete — that would break beginAnswer's guards.
      expect(body, isNot(contains('_answerStarted = true')));
      expect(body, isNot(contains('_handshakeComplete = true')));
      final core = section(
        crypto,
        'Future<void> _prepareAnswerCore({',
        '/// In-flight [prepareAnswer]',
      );
      // No fingerprint signature — that depends on the answer SDP.
      expect(core, isNot(contains('_signCalleeFp')));
      // No SDP encryption — nothing goes on the wire.
      expect(core, isNot(contains('encryptAnswer')));
      expect(core, isNot(contains('encryptSignal')));
    });

    test('prepared crypto only skips work when call inputs match exactly', () {
      final begin = section(
        crypto,
        'Future<({Uint8List eph, Uint8List fp})> _beginAnswer({',
        '/// Derive session keys in FIXED role order',
      );
      expect(begin, contains('_answerPrepared &&'));
      expect(begin, contains('_preppedPeerId == peerId'));
      expect(begin, contains('_eqBytes(callerSig, _preppedCallerSig!)'));
      expect(begin, contains('_eqFps(offerDtlsFps, _preppedOfferFps!)'));
      // A mid-flight prepare must be awaited — two keygens would diverge.
      expect(begin, contains('await inFlight'));
    });

    test('ICE candidates generated before an answer are buffered, not sent', () {
      final handler = section(
        controller,
        'Future<void> _handleIceCandidate(',
        'Future<void> _flushPendingIceCandidates',
      );
      // Without a server callId or ready crypto session, candidates go to
      // _pendingIceCandidates — never to the socket.
      expect(handler, contains('_pendingIceCandidates.add'));
      expect(
        handler.indexOf('_pendingIceCandidates.add'),
        lessThan(handler.indexOf('sendIceCandidate')),
      );
    });

    test('FCM ring-time path reports to Telecom but sends no accept signal', () {
      // The FCM data message only contains call metadata — no SDP offer —
      // so the native layer physically cannot signal acceptance early.
      final fcm = section(
        fcmService,
        'private fun handleIncomingCall',
        'private fun prewarmCallEngine',
      );
      expect(fcm, isNot(contains('call_accepted')));
      expect(fcm, isNot(contains('sdpAnswer')));
      expect(fcm, contains('prewarmCallEngine'));
      expect(fcm, contains('reportIncomingCall'));
    });
  });

  group('cleanup — every not-answered outcome disposes prepared state', () {
    test('decline (rejectCall) tears down PC, crypto and native call', () {
      final body = section(
        controller,
        'void rejectCall(Map<String, dynamic> callData)',
        '/// Reset call state when we know the call has already ended',
      );
      expect(body, contains('_stopNativeIncomingCall()'));
      expect(body, contains('_ringtoneService.stopRingtone(reason: '));
      expect(body, contains('_webrtcService.endCall()'));
      expect(body, contains('_resetCallState()'));
    });

    test('caller cancel (remote terminate) tears down without re-terminating', () {
      final body = section(
        controller,
        'void resetCallStateForRemoteEnd()',
        '/// End the current call',
      );
      expect(body, contains('_ringtoneService.stopRingtone(reason: '));
      expect(body, contains('_webrtcService.endCall()'));
      expect(body, contains('_resetCallState()'));
      // Must NOT emit call_terminated back to the server.
      expect(body, isNot(contains('terminateCall')));
    });

    test('socket call_terminated handler releases WebRTC + notification', () {
      final body = section(
        controller,
        'void _handleCallTerminated(Map<String, dynamic> data)',
        'Future<void> _handleIceCandidate(',
      );
      expect(body, contains('cancelNotification'));
      expect(body, contains('CallForegroundService().stop()'));
      expect(body, contains('_webrtcService.endCall()'));
      expect(body, contains('_resetCallState()'));
    });

    test('endCall releases WebRTC, Telecom and call state', () {
      final body = section(
        controller,
        'void endCall()',
        '/// Minimize the call screen',
      );
      expect(body, contains('_webrtcService.endCall()'));
      expect(body, contains('_resetCallState()'));
      expect(body, contains('_ringtoneService.stopRingtone(reason: '));
    });

    test('_resetCallState disposes crypto, accept-in-flight and urgency', () {
      final body = section(
        controller,
        'void _resetCallState()',
        'void _cleanup()',
      );
      expect(body, contains('_resetCryptoState()'));
      expect(body, contains('_acceptInFlightCallId = null'));
      expect(body, contains('_latestIncomingCallData = null'));
      expect(body, contains('_socketService.callUrgency = false'));
      expect(body, contains('_teardownAndroidCall'));
      expect(body, contains('_iceServersPrefetched = false'));
    });

    test('crypto dispose clears pre-derived ephemeral + prepared markers', () {
      final body = section(crypto, 'void dispose()', '}');
      for (final field in const [
        '_ephLocal',
        '_ephLocalPub',
        '_ephPeerPub',
        '_kAB',
        '_kBA',
        '_prepareInFlight',
        '_answerPrepared',
        '_preppedPeerId',
        '_preppedCallerSig',
        '_preppedOfferFps',
      ]) {
        expect(body, contains(field), reason: 'dispose() must clear $field');
      }
    });

    test('stale prepared PC is disposed when the accepted offer differs', () {
      final body = section(
        webrtc,
        'final prepared = _incomingPrepared &&',
        '// CRITICAL: Stop any active ringtone',
      );
      // Second-call-during-ring or a rotated offer must not reuse the PC.
      expect(body, contains('_peerConnection?.close()'));
      expect(body, contains('_peerConnection?.dispose()'));
      expect(body, contains('_pendingRemoteIceCandidates.clear()'));
    });

    test('prewarm engine is destroyed on every call teardown + timeout', () {
      // VantCallManager.releaseCallResources runs on decline/cancel/end.
      expect(callManager, contains('discardPrewarmEngine()'));
      // ...and the engine also self-destructs on a timeout in the service.
      expect(fcmService, contains('PREWARM_TIMEOUT_MS'));
      expect(fcmService, contains('postDelayed(prewarmTimeoutRunnable'));
      // discardPrewarmEngine removes the engine from the cache and destroys it.
      final discard = section(
        fcmService,
        'fun discardPrewarmEngine()',
        'private fun',
      );
      expect(discard, contains('cache.remove(CALL_PREWARM_ENGINE_ID)'));
      expect(discard, contains('stale.destroy()'));
    });

    test('a second incoming call replaces the pre-derived crypto session', () {
      // _decryptIncomingOffer reuses crypto only when the sessionId matches —
      // a different incoming call resets the previous prepared state.
      final body = section(
        controller,
        'Future<String?> _decryptIncomingOffer(',
        'void _rejectCryptoCall(',
      );
      expect(body, contains('_cryptoSessionId == sessionId'));
      expect(body, contains('if (!reuseCrypto) _resetCryptoState()'));
    });
  });

  group('resync and socket discipline', () {
    test('ring-time resync dedupes per callId', () {
      expect(socket, contains('_lastResyncCallId'));
      final fn = section(
        socket,
        'void requestCallResync',
        '/// Get socket instance for direct event listening',
      );
      expect(fn, contains('already sent'));
      expect(fn, contains('Duration(seconds: 3)'));
    });

    test('resync reuses a live/in-flight socket instead of reconnecting', () {
      final fn = section(
        socket,
        'Future<void> reconnectForCallResync()',
        '/// Force reconnect',
      );
      expect(fn, contains('already connected/connecting'));
      // The reuse early-return must run before any disconnect/dispose.
      expect(
        fn.indexOf('already connected/connecting'),
        lessThan(fn.indexOf('_socket?.dispose()')),
      );
    });

    test('call urgency is cleared when call state resets', () {
      final body = section(
        controller,
        'void _resetCallState()',
        'void _cleanup()',
      );
      expect(body, contains('_socketService.callUrgency = false'));
    });
  });
}
