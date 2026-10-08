import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/socket_service.dart';

/// Voice-call wire contract — the exact event payloads shipped clients use.
/// These must NOT change; if a test here fails, an existing call flow broke.
void main() {
  group('voice call payload contract', () {
    test(
        'call_initiate keys are exactly {callerId, calleeId, sdpOffer, callerName?}',
        () {
      final p = SocketService.buildCallInitiatePayload(
        callerId: '1111111111',
        calleeId: '2222222222',
        sdpOffer: 'v=0 o=- ...',
      );
      expect(p.keys.toSet(), {'callerId', 'calleeId', 'sdpOffer'});
      expect(p['callerId'], '1111111111');
      expect(p['sdpOffer'], startsWith('v=0'));

      final withName = SocketService.buildCallInitiatePayload(
        callerId: '1',
        calleeId: '2',
        sdpOffer: 's',
        callerName: 'Kris',
      );
      expect(withName['callerName'], 'Kris');

      // Empty caller name must not add the key at all.
      final empty = SocketService.buildCallInitiatePayload(
        callerId: '1',
        calleeId: '2',
        sdpOffer: 's',
        callerName: '',
      );
      expect(empty.containsKey('callerName'), isFalse);
    });

    test('call_accept keys are exactly {callId, callerId, sdpAnswer}', () {
      final p = SocketService.buildCallAcceptPayload(
        callId: 'c1',
        callerId: 'a',
        sdpAnswer: 'ans',
      );
      expect(p, {'callId': 'c1', 'callerId': 'a', 'sdpAnswer': 'ans'});
    });

    test('call_reject defaults reason to rejected', () {
      expect(
        SocketService.buildCallRejectPayload(callId: 'c', callerId: 'a'),
        {'callId': 'c', 'callerId': 'a', 'reason': 'rejected'},
      );
    });

    test('call_terminate defaults reason to ended', () {
      expect(
        SocketService.buildCallTerminatePayload(callId: 'c'),
        {'callId': 'c', 'reason': 'ended'},
      );
    });

    test('ice_candidate keys are fixed', () {
      final p = SocketService.buildIceCandidatePayload(
        callId: 'c',
        targetDeviceId: 't',
        candidate: 'cand',
        sdpMid: '0',
        sdpMLineIndex: 0,
      );
      expect(
        p.keys.toSet(),
        {'callId', 'targetDeviceId', 'candidate', 'sdpMid', 'sdpMLineIndex'},
      );
    });

    test('clientVersion keeps semantic version plus build metadata', () {
      expect(
        SocketService.formatClientVersion('1.8.0', '180'),
        '1.8.0+180',
      );
    });

    test('encrypted payloads carry opaque crypto envelopes without SDP', () {
      const crypto = {
        'v': 1,
        'sessionId': 'cs_test-session',
        'sdpOfferEnc': {'n': 'nonce', 'c': 'cipher', 'k': '0'},
      };
      final initiate = SocketService.buildCallInitiatePayload(
        callerId: 'a',
        calleeId: 'b',
        crypto: crypto,
      );
      expect(initiate.containsKey('sdpOffer'), isFalse);
      expect(initiate['crypto'], crypto);

      final accept = SocketService.buildCallAcceptPayload(
        callId: 'cs_test-session',
        callerId: 'a',
        crypto: crypto,
      );
      expect(accept.containsKey('sdpAnswer'), isFalse);
      expect(accept['crypto'], crypto);

      final ice = SocketService.buildIceCandidatePayload(
        callId: 'cs_test-session',
        targetDeviceId: 'a',
        crypto: crypto,
      );
      expect(ice.containsKey('candidate'), isFalse);
      expect(ice['crypto'], crypto);
    });
  });
}
