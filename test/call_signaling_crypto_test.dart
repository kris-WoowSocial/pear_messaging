import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/call_signaling_crypto.dart';
import 'package:pear_messaging/core/services/identity_service.dart';

/// Builds a usable IdentityService without secure storage: we seed the
/// private fields via the same seed-based reconstruction the service uses.
class _TestIdentity extends IdentityService {
  _TestIdentity(this.x, this.ed);

  final SimpleKeyPair x;
  final SimpleKeyPair ed;
  final _x = X25519();
  final _e = Ed25519();

  @override
  KeyPair? get internalX25519KeyPair => x;
  @override
  KeyPair? get internalEd25519KeyPair => ed;

  Future<String> bundle() async {
    final xd = await x.extract() as SimpleKeyPairData;
    final edd = await ed.extract() as SimpleKeyPairData;
    return base64Encode(Uint8List.fromList(
        [1, ...xd.publicKey.bytes, ...edd.publicKey.bytes]));
  }
}

Future<_TestIdentity> _makeIdentity() async {
  final x = await X25519().newKeyPair();
  final ed = await Ed25519().newKeyPair();
  return _TestIdentity(x as SimpleKeyPair, ed as SimpleKeyPair);
}

const offerSdp = 'v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\nm=audio\r\n';
const answerSdp = 'v=0\r\na=fingerprint:sha-256 DD:EE:FF\r\nm=audio\r\n';

void main() {
  group('call signaling crypto', () {
    test('full handshake: offer encrypts, session established, both directions',
        () async {
      final a = await _makeIdentity();
      final b = await _makeIdentity();
      final pinMap = <String, String>{
        'devB': await b.bundle(),
        'devA': await a.bundle(),
      };
      String? resolver(String id) => pinMap[id];

      final caller = CallSignalingCrypto(
          identity: a, myDeviceId: 'devA', resolvePeerBundle: resolver);
      final callee = CallSignalingCrypto(
          identity: b, myDeviceId: 'devB', resolvePeerBundle: resolver);

      // Caller: begin + encrypt offer.
      final offerFps =
          CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      final begin = await caller.beginOffer(
        callId: 'call_1',
        myId: 'devA',
        peerId: 'devB',
        peerBundleB64: pinMap['devB']!,
        offerDtlsFps: offerFps,
      );
      final encOffer = await caller.encryptOffer(offerSdp);

      // Callee: verify caller fp + decrypt offer.
      final callerPub =
          IdentityService.parseBundle(pinMap['devA']!)!.ed25519Pub;
      final fpOk = await callee.verifyCallerFp(
        callId: 'call_1',
        idA: 'devA',
        idB: 'devB',
        ephA: begin.eph,
        offerFps: offerFps,
        callerSig: begin.fp,
        callerEd25519Pub: callerPub,
      );
      expect(fpOk, isTrue);
      final plainOffer = await callee.decryptOffer(
        callId: 'call_1',
        myId: 'devB',
        callerId: 'devA',
        ephA: begin.eph,
        encrypted: encOffer,
      );
      expect(plainOffer, offerSdp);

      // Callee answers: ephB + callee fp covering offer+answer+caller sig.
      final answerFps =
          CallSignalingCrypto.extractDtlsFingerprints(answerSdp);
      final ans = await callee.beginAnswer(
        peerId: 'devA',
        peerBundleB64: pinMap['devA']!,
        callerSig: begin.fp,
        offerDtlsFps: offerFps,
        answerDtlsFps: answerFps,
      );

      // Caller completes.
      await caller.completeHandshake(
        peerId: 'devB',
        peerBundleB64: pinMap['devB']!,
        ephB: ans.eph,
        callerSig: begin.fp,
        calleeSig: ans.fp,
        answerDtlsFps: answerFps,
      );

      // Both directions encrypt/decrypt.
      final c2c = await caller.encryptMessage(
          direction: 'a2b', event: 'ice_candidate', plaintext: 'cand-A');
      expect(
        await callee.decryptMessage(
            direction: 'a2b', event: 'ice_candidate', encrypted: c2c),
        'cand-A',
      );
      final b2a = await callee.encryptMessage(
          direction: 'b2a', event: 'call_accept', plaintext: 'answer-sdp');
      expect(
        await caller.decryptMessage(
            direction: 'b2a', event: 'call_accept', encrypted: b2a),
        'answer-sdp',
      );
    });

    test('tampered ciphertext fails authentication', () async {
      final a = await _makeIdentity();
      final b = await _makeIdentity();
      final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
      final caller = CallSignalingCrypto(
          identity: a, myDeviceId: 'devA', resolvePeerBundle: (id) => pins[id]);
      final callee = CallSignalingCrypto(
          identity: b, myDeviceId: 'devB', resolvePeerBundle: (id) => pins[id]);
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      final begin = await caller.beginOffer(
          callId: 'c', myId: 'devA', peerId: 'devB',
          peerBundleB64: pins['devB']!, offerDtlsFps: fps);
      final enc = await caller.encryptOffer(offerSdp);
      await callee.decryptOffer(
          callId: 'c', myId: 'devB', callerId: 'devA',
          ephA: begin.eph, encrypted: enc);
      final af = CallSignalingCrypto.extractDtlsFingerprints(answerSdp);
      final ans = await callee.beginAnswer(
          peerId: 'devA', peerBundleB64: pins['devA']!,
          callerSig: begin.fp, offerDtlsFps: fps, answerDtlsFps: af);
      await caller.completeHandshake(
          peerId: 'devB', peerBundleB64: pins['devB']!, ephB: ans.eph,
          callerSig: begin.fp, calleeSig: ans.fp, answerDtlsFps: af);

      final msg = await caller.encryptMessage(
          direction: 'a2b', event: 'ice_candidate', plaintext: 'x');
      final tampered = Map<String, String>.from(msg);
      final bytes = base64Decode(tampered['c']!);
      bytes[0] ^= 0xff;
      tampered['c'] = base64Encode(bytes);
      expect(
        () => callee.decryptMessage(
            direction: 'a2b', event: 'ice_candidate', encrypted: tampered),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('replay: same counter twice is rejected', () async {
      final a = await _makeIdentity();
      final b = await _makeIdentity();
      final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
      final caller = CallSignalingCrypto(
          identity: a, myDeviceId: 'devA', resolvePeerBundle: (id) => pins[id]);
      final callee = CallSignalingCrypto(
          identity: b, myDeviceId: 'devB', resolvePeerBundle: (id) => pins[id]);
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      final begin = await caller.beginOffer(
          callId: 'c', myId: 'devA', peerId: 'devB',
          peerBundleB64: pins['devB']!, offerDtlsFps: fps);
      await callee.decryptOffer(
          callId: 'c', myId: 'devB', callerId: 'devA',
          ephA: begin.eph,
          encrypted: await caller.encryptOffer(offerSdp));
      final af = CallSignalingCrypto.extractDtlsFingerprints(answerSdp);
      final ans = await callee.beginAnswer(
          peerId: 'devA', peerBundleB64: pins['devA']!,
          callerSig: begin.fp, offerDtlsFps: fps, answerDtlsFps: af);
      await caller.completeHandshake(
          peerId: 'devB', peerBundleB64: pins['devB']!, ephB: ans.eph,
          callerSig: begin.fp, calleeSig: ans.fp, answerDtlsFps: af);

      final msg = await caller.encryptMessage(
          direction: 'a2b', event: 'ice_candidate', plaintext: 'c');
      await callee.decryptMessage(
          direction: 'a2b', event: 'ice_candidate', encrypted: msg);
      expect(
        () => callee.decryptMessage(
            direction: 'a2b', event: 'ice_candidate', encrypted: msg),
        throwsA(isA<CallSignalingCryptoException>()),
      );
    });

    test('forged callee signature fails handshake', () async {
      final a = await _makeIdentity();
      final b = await _makeIdentity();
      final evil = await _makeIdentity();
      final pins = {
        'devB': await b.bundle(),
        'devA': await a.bundle(),
        'evil': await evil.bundle(),
      };
      final caller = CallSignalingCrypto(
          identity: a, myDeviceId: 'devA', resolvePeerBundle: (id) => pins[id]);
      final callee = CallSignalingCrypto(
          identity: b, myDeviceId: 'devB', resolvePeerBundle: (id) => pins[id]);
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      final begin = await caller.beginOffer(
          callId: 'c', myId: 'devA', peerId: 'devB',
          peerBundleB64: pins['devB']!, offerDtlsFps: fps);
      await callee.decryptOffer(
          callId: 'c', myId: 'devB', callerId: 'devA',
          ephA: begin.eph,
          encrypted: await caller.encryptOffer(offerSdp));
      final af = CallSignalingCrypto.extractDtlsFingerprints(answerSdp);
      final ans = await callee.beginAnswer(
          peerId: 'devA', peerBundleB64: pins['devA']!,
          callerSig: begin.fp, offerDtlsFps: fps, answerDtlsFps: af);
      // Forged callee sig (random bytes) → crypto_failed.
      expect(
        caller.completeHandshake(
          peerId: 'devB',
          peerBundleB64: pins['devB']!,
          ephB: ans.eph,
          callerSig: begin.fp,
          calleeSig: Uint8List(64),
          answerDtlsFps: af,
        ),
        throwsA(isA<CallSignalingCryptoException>()),
      );
    });

    test('fixed vectors — independently reproduced in Python/Node', () async {
      // HKDF-SHA256: ikm=32×0x01, salt='call_123', info='vant-call-offer'
      // Python hmac reproduction: rNgQZduDn+YkIvTgjtFG7U0tKN/X0Z7RwT3nLXmOjZU=
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final k = await hkdf.deriveKey(
        secretKey: SecretKey(Uint8List(32)..fillRange(0, 32, 1)),
        nonce: utf8.encode('call_123'),
        info: utf8.encode(CallSignalingCrypto.infoOffer),
      );
      expect(base64Encode(await k.extractBytes()),
          'rNgQZduDn+YkIvTgjtFG7U0tKN/X0Z7RwT3nLXmOjZU=');

      // AES-256-GCM: key=32×0x02 nonce=12×0x03 aad='AADBYTES'
      // Node crypto reproduction: rZiXRXjfChi6yyVc6+kulo5OMFE/SqmunXBFF33Bjw==
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode('hello signaling'),
        secretKey: SecretKey(Uint8List(32)..fillRange(0, 32, 2)),
        nonce: Uint8List(12)..fillRange(0, 12, 3),
        aad: utf8.encode('AADBYTES'),
      );
      expect(base64Encode(box.cipherText + box.mac.bytes),
          'rZiXRXjfChi6yyVc6+kulo5OMFE/SqmunXBFF33Bjw==');
    });

    test('DTLS fingerprint extraction: multi-section identical OK, differing rejected',
        () {
      final multi = 'v=0\r\na=fingerprint:sha-256 AA\r\nm=audio\r\n'
          'a=fingerprint:sha-256 AA\r\nm=video\r\n';
      expect(CallSignalingCrypto.extractDtlsFingerprints(multi).length, 1);
      final bad = 'v=0\r\na=fingerprint:sha-256 AA\r\nm=audio\r\n'
          'a=fingerprint:sha-256 BB\r\nm=video\r\n';
      expect(() => CallSignalingCrypto.extractDtlsFingerprints(bad),
          throwsA(isA<FormatException>()));
    });
  });
}
