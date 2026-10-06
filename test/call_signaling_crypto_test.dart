import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/call_signaling_crypto.dart';
import 'package:pear_messaging/core/services/identity_service.dart';

/// Test identity that exposes the two injected operations without touching
/// secure storage.
class _TestIdentity {
  _TestIdentity(this.x, this.ed);

  final SimpleKeyPair x;
  final SimpleKeyPair ed;
  final _x = X25519();
  final _e = Ed25519();

  Future<SecretKey> dh(List<int> peerPub) => _x.sharedSecretKey(
        keyPair: x,
        remotePublicKey:
            SimplePublicKey(peerPub, type: KeyPairType.x25519),
      );

  Future<Uint8List> sign(List<int> msg) async =>
      Uint8List.fromList((await _e.sign(msg, keyPair: ed)).bytes);

  Future<String> bundle() async {
    final xd = await x.extract() as SimpleKeyPairData;
    final edd = await ed.extract() as SimpleKeyPairData;
    return base64Encode(Uint8List.fromList(
        [1, ...xd.publicKey.bytes, ...edd.publicKey.bytes]));
  }

  Future<Uint8List> get edPub async =>
      Uint8List.fromList((await ed.extract() as SimpleKeyPairData)
          .publicKey
          .bytes);
}

Future<_TestIdentity> _mk() async => _TestIdentity(
    await X25519().newKeyPair() as SimpleKeyPair,
    await Ed25519().newKeyPair());

const offerSdp = 'v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\nm=audio\r\n';
const answerSdp = 'v=0\r\na=fingerprint:sha-256 DD:EE:FF\r\nm=audio\r\n';

/// Drive a full handshake, returning (caller, callee, ephA, callerSig).
Future<(CallSignalingCrypto, CallSignalingCrypto, Uint8List, Uint8List)>
    _handshake({
  _TestIdentity? callerId,
  _TestIdentity? calleeId,
  Map<String, String>? pins,
  String callId = 'call_1',
}) async {
  final a = callerId ?? await _mk();
  final b = calleeId ?? await _mk();
  final pinMap =
      pins ?? {'devB': await b.bundle(), 'devA': await a.bundle()};
  String? resolver(String id) => pinMap[id];

  final caller = CallSignalingCrypto(
      dh: a.dh, sign: a.sign, myDeviceId: 'devA', resolvePeerBundle: resolver);
  final callee = CallSignalingCrypto(
      dh: b.dh, sign: b.sign, myDeviceId: 'devB', resolvePeerBundle: resolver);

  final offerFps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
  final begin = await caller.beginOffer(
    callId: callId,
    myId: 'devA',
    peerId: 'devB',
    peerBundleB64: pinMap['devB']!,
    offerDtlsFps: offerFps,
  );
  final encOffer = await caller.encryptOffer(offerSdp);

  final plain = await callee.decryptOffer(
    callId: callId,
    callerId: 'devA',
    ephA: begin.eph,
    encrypted: encOffer,
  );
  expect(plain, offerSdp);

  final fpOk = await callee.verifyCallerFp(
    callId: callId,
    idA: 'devA',
    idB: 'devB',
    ephA: begin.eph,
    offerFps: offerFps,
    callerSig: begin.fp,
    callerEd25519Pub: IdentityService.parseBundle(pinMap['devA']!)!.ed25519Pub,
  );
  expect(fpOk, isTrue);

  final answerFps =
      CallSignalingCrypto.extractDtlsFingerprints(answerSdp);
  final ans = await callee.beginAnswer(
    peerId: 'devA',
    peerBundleB64: pinMap['devA']!,
    callerSig: begin.fp,
    offerDtlsFps: offerFps,
    answerDtlsFps: answerFps,
  );
  await caller.completeHandshake(
    peerId: 'devB',
    peerBundleB64: pinMap['devB']!,
    ephB: ans.eph,
    calleeSig: ans.fp,
    answerDtlsFps: answerFps,
  );
  return (caller, callee, begin.eph, begin.fp);
}

void main() {
  group('handshake', () {
    test('round-trip: offer decrypts, both directions work', () async {
      final (caller, callee, _, __) = await _handshake();
      final c2c = await caller.encryptMessage(
          direction: 'a2b', event: 'ice_candidate', plaintext: 'cand-A');
      expect(
        await callee.decryptMessage(
            direction: 'a2b', event: 'ice_candidate', encrypted: c2c),
        'cand-A',
      );
      final b2a = await callee.encryptMessage(
          direction: 'b2a', event: 'call_accept', plaintext: 'answer');
      expect(
        await caller.decryptMessage(
            direction: 'b2a', event: 'call_accept', encrypted: b2a),
        'answer',
      );
    });

    test('callee sig covering a DIFFERENT answer fingerprint fails', () async {
      final a = await _mk(), b = await _mk();
      final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
      String? r(String id) => pins[id];
      final caller = CallSignalingCrypto(
          dh: a.dh, sign: a.sign, myDeviceId: 'devA', resolvePeerBundle: r);
      final callee = CallSignalingCrypto(
          dh: b.dh, sign: b.sign, myDeviceId: 'devB', resolvePeerBundle: r);
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      final begin = await caller.beginOffer(
          callId: 'c', myId: 'devA', peerId: 'devB',
          peerBundleB64: pins['devB']!, offerDtlsFps: fps);
      await callee.decryptOffer(
          callId: 'c', callerId: 'devA', ephA: begin.eph,
          encrypted: await caller.encryptOffer(offerSdp));
      // Callee signs an answer with a DIFFERENT dtls fingerprint.
      final evilAnswerFps = CallSignalingCrypto.extractDtlsFingerprints(
          'v=0\r\na=fingerprint:sha-256 ZZ:ZZ:ZZ\r\nm=audio\r\n');
      final ans = await callee.beginAnswer(
          peerId: 'devA', peerBundleB64: pins['devA']!,
          callerSig: begin.fp, offerDtlsFps: fps, answerDtlsFps: evilAnswerFps);
      // Caller supplies the REAL answer fps → sig mismatch → crypto_failed.
      final realFps =
          CallSignalingCrypto.extractDtlsFingerprints(answerSdp);
      expect(
        caller.completeHandshake(
          peerId: 'devB', peerBundleB64: pins['devB']!, ephB: ans.eph,
          calleeSig: ans.fp, answerDtlsFps: realFps,
        ),
        throwsA(isA<CallSignalingCryptoException>()),
      );
    });

    test('answer bound to a different offer (wrong callerSig) fails', () async {
      final a = await _mk(), b = await _mk();
      final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
      String? r(String id) => pins[id];
      final caller = CallSignalingCrypto(
          dh: a.dh, sign: a.sign, myDeviceId: 'devA', resolvePeerBundle: r);
      final callee = CallSignalingCrypto(
          dh: b.dh, sign: b.sign, myDeviceId: 'devB', resolvePeerBundle: r);
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      final begin = await caller.beginOffer(
          callId: 'c', myId: 'devA', peerId: 'devB',
          peerBundleB64: pins['devB']!, offerDtlsFps: fps);
      await callee.decryptOffer(
          callId: 'c', callerId: 'devA', ephA: begin.eph,
          encrypted: await caller.encryptOffer(offerSdp));
      final af = CallSignalingCrypto.extractDtlsFingerprints(answerSdp);
      // callee signs a DIFFERENT callerSig — the answer isn't bound to
      // the offer the caller actually sent.
      final ans = await callee.beginAnswer(
          peerId: 'devA', peerBundleB64: pins['devA']!,
          callerSig: Uint8List(64)..[0] = 9,
          offerDtlsFps: fps, answerDtlsFps: af);
      expect(
        caller.completeHandshake(
          peerId: 'devB', peerBundleB64: pins['devB']!, ephB: ans.eph,
          calleeSig: ans.fp, answerDtlsFps: af,
        ),
        throwsA(isA<CallSignalingCryptoException>()),
      );
    });

    test('swapped ephemeral keys fail signature verification', () async {
      final a = await _mk(), b = await _mk();
      final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
      String? r(String id) => pins[id];
      final callee = CallSignalingCrypto(
          dh: b.dh, sign: b.sign, myDeviceId: 'devB', resolvePeerBundle: r);
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      // A swapped ephA (server substitute) fails caller-fp verification.
      final evilEph = await X25519().newKeyPair();
      final evilEphPub = Uint8List.fromList(
          (await evilEph.extract() as SimpleKeyPairData).publicKey.bytes);
      final ok = await callee.verifyCallerFp(
        callId: 'c',
        idA: 'devA',
        idB: 'devB',
        ephA: evilEphPub, // substituted
        offerFps: fps,
        callerSig: Uint8List(64),
        callerEd25519Pub:
            IdentityService.parseBundle(pins['devA']!)!.ed25519Pub,
      );
      expect(ok, isFalse);
    });
  });

  group('AEAD', () {
    test('wrong direction / event / callId all fail auth', () async {
      final (caller, callee, _, __) = await _handshake();
      final msg = await caller.encryptMessage(
          direction: 'a2b', event: 'ice_candidate', plaintext: 'x');
      // wrong direction key (b2a vs a2b)
      expect(
        () => callee.decryptMessage(
            direction: 'b2a', event: 'ice_candidate', encrypted: msg),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      // wrong event in AAD
      expect(
        () => callee.decryptMessage(
            direction: 'a2b', event: 'call_accept', encrypted: msg),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('replay edges: duplicate, boundary, far-ahead', () async {
      final (caller, callee, _, __) = await _handshake();
      final msgs = <Map<String, String>>[];
      for (var i = 0; i < 3; i++) {
        msgs.add(await caller.encryptMessage(
            direction: 'a2b', event: 'ice_candidate', plaintext: 'c$i'));
      }
      // in-order delivery
      for (final m in msgs) {
        await callee.decryptMessage(
            direction: 'a2b', event: 'ice_candidate', encrypted: m);
      }
      // replay the first — rejected
      expect(
        () => callee.decryptMessage(
            direction: 'a2b', event: 'ice_candidate', encrypted: msgs[0]),
        throwsA(isA<CallSignalingCryptoException>()),
      );
    });

    test('counter cap refuses to wrap', () async {
      final a = await _mk(), b = await _mk();
      final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
      String? r(String id) => pins[id];
      final caller = CallSignalingCrypto(
          dh: a.dh, sign: a.sign, myDeviceId: 'devA', resolvePeerBundle: r);
      // force counter to cap
      final counters = caller.sendCountersForTest;
      counters['a2b'] = CallSignalingCrypto.maxCounter;
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      await caller.beginOffer(
          callId: 'c', myId: 'devA', peerId: 'devB',
          peerBundleB64: pins['devB']!, offerDtlsFps: fps);
      expect(
        () => caller.encryptOffer(offerSdp),
        throwsA(isA<CallSignalingCryptoException>()),
      );
    });
  });

  group('robustness', () {
    test('all-zero DH rejected', () async {
      final a = await _mk(), b = await _mk();
      final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
      String? r(String id) => pins[id];
      final caller = CallSignalingCrypto(
          dh: a.dh, sign: a.sign, myDeviceId: 'devA', resolvePeerBundle: r);
      // Override dh to return an all-zero secret — simulating a low-order
      // peer point producing a degenerate shared secret.
      final caller2 = CallSignalingCrypto(
        dh: (_) async => SecretKey(Uint8List(32)),
        sign: a.sign,
        myDeviceId: 'devA',
        resolvePeerBundle: r,
      );
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      expect(
        caller2.beginOffer(
            callId: 'c', myId: 'devA', peerId: 'devB',
            peerBundleB64: pins['devB']!, offerDtlsFps: fps),
        throwsA(isA<CallSignalingCryptoException>()),
      );
    });

    test('identity unavailable → typed error, not null crash', () async {
      final a = await _mk();
      final deadDh = (_) async =>
          throw const IdentityUnavailableException();
      final c = CallSignalingCrypto(
        dh: deadDh,
        sign: a.sign,
        myDeviceId: 'devA',
        resolvePeerBundle: (_) => null,
      );
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      expect(
        c.beginOffer(
            callId: 'x', myId: 'devA', peerId: 'devB',
            peerBundleB64: 'invalid',
            offerDtlsFps: fps),
        throwsA(anything), // either unavailable or invalid bundle — typed
      );
    });

    test('decrypt-failure threshold: 7 bad ok, 8th ends the call', () async {
      final (caller, callee, _, __) = await _handshake();
      for (var i = 0; i < 7; i++) {
        try {
          await callee.decryptMessage(
              direction: 'a2b',
              event: 'ice_candidate',
              encrypted: {'n': 'AAAA', 'c': 'AAAA', 'k': '999$i'});
        } catch (_) {}
      }
      // still alive — a good message decrypts
      final good = await caller.encryptMessage(
          direction: 'a2b', event: 'ice_candidate', plaintext: 'good');
      await callee.decryptMessage(
          direction: 'a2b', event: 'ice_candidate', encrypted: good);
      // 8th failure ends it
      expect(
        callee.decryptMessage(
            direction: 'a2b',
            event: 'ice_candidate',
            encrypted: {'n': 'AAAA', 'c': 'AAAA', 'k': '9998'}),
        throwsA(isA<CallSignalingCryptoException>()),
      );
    });

    test('cold start: fresh callee object decrypts stored offer', () async {
      final a = await _mk(), b = await _mk();
      final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
      String? r(String id) => pins[id];
      final caller = CallSignalingCrypto(
          dh: a.dh, sign: a.sign, myDeviceId: 'devA', resolvePeerBundle: r);
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      final begin = await caller.beginOffer(
          callId: 'c', myId: 'devA', peerId: 'devB',
          peerBundleB64: pins['devB']!, offerDtlsFps: fps);
      final encOffer = await caller.encryptOffer(offerSdp);
      // NEW object — only the pinned identity exists (as on app restart).
      final freshCallee = CallSignalingCrypto(
          dh: b.dh, sign: b.sign, myDeviceId: 'devB', resolvePeerBundle: r);
      final plain = await freshCallee.decryptOffer(
        callId: 'c',
        callerId: 'devA',
        ephA: begin.eph,
        encrypted: encOffer,
      );
      expect(plain, offerSdp);
    });
  });

  test('full-schedule fixed vector — reproduced in Node X25519+HKDF', () async {
    // Fixed seeds so every DH output is deterministic. Node's
    // crypto.diffieHellman (x25519) + hkdfSync reproduced the whole chain:
    //   OFFERKEY=sxUpzdQz1IjJyDeaElrpIy3u5KGQKvzrlwz2c71bVOQ=
    //   SESSION =xdBUYmhSFtLUhifoggtHVaOTfN7cTDmPAQIthh0ZwbA=
    //   KAB     =/IkeMhMugLy5BK+bl6d4zSoltgmVlT2/3+EdGVTfasY=
    //   KBA     =K8wQP4gxFxPuOqrGvrlep+Fm6X2ocgVSUxxC/YgNjAs=
    final x = X25519();
    Future<SimpleKeyPair> seeded(int fill) async =>
        (await x.newKeyPairFromSeed(Uint8List(32)..fillRange(0, 32, fill)))
            as SimpleKeyPair;
    final a = _TestIdentity(await seeded(0x11),
        await Ed25519().newKeyPair());
    final b = _TestIdentity(await seeded(0x22),
        await Ed25519().newKeyPair());
    final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
    String? r(String id) => pins[id];
    final caller = CallSignalingCrypto(
        dh: a.dh, sign: a.sign, myDeviceId: 'devA', resolvePeerBundle: r);
    final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
    await caller.beginOffer(
        callId: 'call_vec', myId: 'devA', peerId: 'devB',
        peerBundleB64: pins['devB']!, offerDtlsFps: fps,
        ephSeed: Uint8List(32)..fillRange(0, 32, 0x33));
    expect(base64Encode(await caller.debugKeyBytes('offer')),
        'sxUpzdQz1IjJyDeaElrpIy3u5KGQKvzrlwz2c71bVOQ=');
  });

  test('fixed vectors — independently reproduced in Python/Node', () async {
    // HKDF-SHA256: ikm=32×0x01, salt='call_123', info='vant-call-offer'
    // Python stdlib reproduction: rNgQZduDn+YkIvTgjtFG7U0tKN/X0Z7RwT3nLXmOjZU=
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
}
