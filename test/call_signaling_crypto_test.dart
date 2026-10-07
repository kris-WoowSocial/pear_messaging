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
        remotePublicKey: SimplePublicKey(peerPub, type: KeyPairType.x25519),
      );

  Future<Uint8List> sign(String domain, List<int> msg) async {
    if (domain != CallSignalingCrypto.fpDomain) {
      throw ArgumentError.value(domain, 'domain');
    }
    return Uint8List.fromList((await _e.sign(msg, keyPair: ed)).bytes);
  }

  Future<String> bundle() async {
    final xd = await x.extract() as SimpleKeyPairData;
    final edd = await ed.extract() as SimpleKeyPairData;
    return base64Encode(
        Uint8List.fromList([1, ...xd.publicKey.bytes, ...edd.publicKey.bytes]));
  }

  Future<Uint8List> get edPub async => Uint8List.fromList(
      (await ed.extract() as SimpleKeyPairData).publicKey.bytes);
}

Future<_TestIdentity> _mk() async => _TestIdentity(
    await X25519().newKeyPair() as SimpleKeyPair, await Ed25519().newKeyPair());

const offerSdp = 'v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\nm=audio\r\n';
const answerSdp = 'v=0\r\na=fingerprint:sha-256 DD:EE:FF\r\nm=audio\r\n';

Matcher throwsCrypto(String code) => throwsA(
      isA<CallSignalingCryptoException>()
          .having((error) => error.message, 'message', code),
    );

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
  final pinMap = pins ?? {'devB': await b.bundle(), 'devA': await a.bundle()};
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
  );
  expect(fpOk, isTrue);

  final answerFps = CallSignalingCrypto.extractDtlsFingerprints(answerSdp);
  final ans = await callee.beginAnswer(
    peerId: 'devA',
    callerSig: begin.fp,
    offerDtlsFps: offerFps,
    answerDtlsFps: answerFps,
  );
  await caller.completeHandshake(
    peerId: 'devB',
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
          callId: 'c', myId: 'devA', peerId: 'devB', offerDtlsFps: fps);
      await callee.decryptOffer(
          callId: 'c',
          callerId: 'devA',
          ephA: begin.eph,
          encrypted: await caller.encryptOffer(offerSdp));
      // Callee signs an answer with a DIFFERENT dtls fingerprint.
      final evilAnswerFps = CallSignalingCrypto.extractDtlsFingerprints(
          'v=0\r\na=fingerprint:sha-256 ZZ:ZZ:ZZ\r\nm=audio\r\n');
      final ans = await callee.beginAnswer(
          peerId: 'devA',
          callerSig: begin.fp,
          offerDtlsFps: fps,
          answerDtlsFps: evilAnswerFps);
      // Caller supplies the REAL answer fps → sig mismatch → crypto_failed.
      final realFps = CallSignalingCrypto.extractDtlsFingerprints(answerSdp);
      expect(
        caller.completeHandshake(
          peerId: 'devB',
          ephB: ans.eph,
          calleeSig: ans.fp,
          answerDtlsFps: realFps,
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
          callId: 'c', myId: 'devA', peerId: 'devB', offerDtlsFps: fps);
      await callee.decryptOffer(
          callId: 'c',
          callerId: 'devA',
          ephA: begin.eph,
          encrypted: await caller.encryptOffer(offerSdp));
      final af = CallSignalingCrypto.extractDtlsFingerprints(answerSdp);
      // callee signs a DIFFERENT callerSig — the answer isn't bound to
      // the offer the caller actually sent.
      final ans = await callee.beginAnswer(
          peerId: 'devA',
          callerSig: Uint8List(64)..[0] = 9,
          offerDtlsFps: fps,
          answerDtlsFps: af);
      expect(
        caller.completeHandshake(
          peerId: 'devB',
          ephB: ans.eph,
          calleeSig: ans.fp,
          answerDtlsFps: af,
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
      );
      expect(ok, isFalse);
    });

    test('caller identity source cannot diverge from configured identity',
        () async {
      final a = await _mk(), b = await _mk();
      final pins = {'devB': await b.bundle()};
      final caller = CallSignalingCrypto(
        dh: a.dh,
        sign: a.sign,
        myDeviceId: 'devA',
        resolvePeerBundle: (id) => pins[id],
      );
      expect(
        caller.beginOffer(
          callId: 'c',
          myId: 'attacker-controlled-id',
          peerId: 'devB',
          offerDtlsFps: CallSignalingCrypto.extractDtlsFingerprints(offerSdp),
        ),
        throwsCrypto('identity_mismatch'),
      );
    });

    test('normal path requires a pin; first-contact path is explicit',
        () async {
      final a = await _mk(), b = await _mk();
      final bundleB = await b.bundle();
      final crypto = CallSignalingCrypto(
        dh: a.dh,
        sign: a.sign,
        myDeviceId: 'devA',
        resolvePeerBundle: (_) => null,
      );
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      expect(
        () => crypto.beginOffer(
          callId: 'pinned-only',
          myId: 'devA',
          peerId: 'devB',
          offerDtlsFps: fps,
        ),
        throwsCrypto('no_pinned_peer_bundle'),
      );
      expect(
        crypto.beginOfferFirstContact(
          callId: 'invalid-first-contact',
          myId: 'devA',
          peerId: 'devB',
          peerBundleB64: 'invalid',
          offerDtlsFps: fps,
        ),
        throwsCrypto('invalid_peer_bundle'),
      );
      final firstContact = await crypto.beginOfferFirstContact(
        callId: 'first-contact',
        myId: 'devA',
        peerId: 'devB',
        peerBundleB64: bundleB,
        offerDtlsFps: fps,
      );
      expect(firstContact.eph, hasLength(32));
      expect(firstContact.fp, hasLength(64));
    });

    test('explicit first-contact APIs complete without a pin', () async {
      final a = await _mk(), b = await _mk();
      final bundleA = await a.bundle();
      final bundleB = await b.bundle();
      final caller = CallSignalingCrypto(
          dh: a.dh,
          sign: a.sign,
          myDeviceId: 'devA',
          resolvePeerBundle: (_) => null);
      final callee = CallSignalingCrypto(
          dh: b.dh,
          sign: b.sign,
          myDeviceId: 'devB',
          resolvePeerBundle: (_) => null);
      final offerFps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      final answerFps = CallSignalingCrypto.extractDtlsFingerprints(answerSdp);
      final begin = await caller.beginOfferFirstContact(
        callId: 'first-contact-full',
        myId: 'devA',
        peerId: 'devB',
        peerBundleB64: bundleB,
        offerDtlsFps: offerFps,
      );
      final encrypted = await caller.encryptOffer(offerSdp);
      expect(
        await callee.decryptOfferFirstContact(
          callId: 'first-contact-full',
          callerId: 'devA',
          callerBundleB64: bundleA,
          ephA: begin.eph,
          encrypted: encrypted,
        ),
        offerSdp,
      );
      expect(
        await callee.verifyCallerFpFirstContact(
          callId: 'first-contact-full',
          idA: 'devA',
          idB: 'devB',
          callerBundleB64: bundleA,
          ephA: begin.eph,
          offerFps: offerFps,
          callerSig: begin.fp,
        ),
        isTrue,
      );
      final answer = await callee.beginAnswerFirstContact(
        peerId: 'devA',
        peerBundleB64: bundleA,
        callerSig: begin.fp,
        offerDtlsFps: offerFps,
        answerDtlsFps: answerFps,
      );
      await caller.completeHandshakeFirstContact(
        peerId: 'devB',
        peerBundleB64: bundleB,
        ephB: answer.eph,
        calleeSig: answer.fp,
        answerDtlsFps: answerFps,
      );
      final message = await caller.encryptMessage(
        direction: 'a2b',
        event: 'ice_candidate',
        plaintext: 'first-contact-ok',
      );
      expect(
        await callee.decryptMessage(
          direction: 'a2b',
          event: 'ice_candidate',
          encrypted: message,
        ),
        'first-contact-ok',
      );
    });

    test('wrong-call offer decryption fails and commits no handshake state',
        () async {
      final a = await _mk(), b = await _mk();
      final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
      String? r(String id) => pins[id];
      final caller = CallSignalingCrypto(
          dh: a.dh, sign: a.sign, myDeviceId: 'devA', resolvePeerBundle: r);
      final callee = CallSignalingCrypto(
          dh: b.dh, sign: b.sign, myDeviceId: 'devB', resolvePeerBundle: r);
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      final begin = await caller.beginOffer(
        callId: 'right-call',
        myId: 'devA',
        peerId: 'devB',
        offerDtlsFps: fps,
      );
      final encrypted = await caller.encryptOffer(offerSdp);
      expect(
        callee.decryptOffer(
          callId: 'wrong-call',
          callerId: 'devA',
          ephA: begin.eph,
          encrypted: encrypted,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      expect(
        callee.beginAnswer(
          peerId: 'devA',
          callerSig: begin.fp,
          offerDtlsFps: fps,
          answerDtlsFps: CallSignalingCrypto.extractDtlsFingerprints(answerSdp),
        ),
        throwsCrypto('handshake_not_started'),
      );
    });

    test('offer decryption is idempotent for exact resync records', () async {
      final a = await _mk(), b = await _mk();
      final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
      var pinAvailable = true;
      String? r(String id) => pinAvailable ? pins[id] : null;
      final caller = CallSignalingCrypto(
          dh: a.dh, sign: a.sign, myDeviceId: 'devA', resolvePeerBundle: r);
      final callee = CallSignalingCrypto(
          dh: b.dh, sign: b.sign, myDeviceId: 'devB', resolvePeerBundle: r);
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      final begin = await caller.beginOffer(
        callId: 'resync-call',
        myId: 'devA',
        peerId: 'devB',
        offerDtlsFps: fps,
      );
      final encrypted = await caller.encryptOffer(offerSdp);
      final first = await callee.decryptOffer(
        callId: 'resync-call',
        callerId: 'devA',
        ephA: begin.eph,
        encrypted: encrypted,
      );
      pinAvailable = false;
      final second = await callee.decryptOffer(
        callId: 'resync-call',
        callerId: 'devA',
        ephA: begin.eph,
        encrypted: Map<String, String>.from(encrypted),
      );
      expect(first, offerSdp);
      expect(second, offerSdp);

      final changed = Map<String, String>.from(encrypted)..['k'] = '1';
      expect(
        callee.decryptOffer(
          callId: 'resync-call',
          callerId: 'devA',
          ephA: begin.eph,
          encrypted: changed,
        ),
        throwsCrypto('active_handshake'),
      );
    });

    test('out-of-order handshake calls return typed errors', () async {
      final a = await _mk(), b = await _mk();
      final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
      final crypto = CallSignalingCrypto(
        dh: a.dh,
        sign: a.sign,
        myDeviceId: 'devA',
        resolvePeerBundle: (id) => pins[id],
      );
      expect(
        crypto.beginAnswer(
          peerId: 'devB',
          callerSig: Uint8List(64),
          offerDtlsFps: const [],
          answerDtlsFps: const [],
        ),
        throwsCrypto('handshake_not_started'),
      );
      expect(
        crypto.completeHandshake(
          peerId: 'devB',
          ephB: Uint8List(32),
          calleeSig: Uint8List(64),
          answerDtlsFps: const [],
        ),
        throwsCrypto('no_pending_offer'),
      );
      expect(
        crypto.decryptMessage(
          direction: 'a2b',
          event: 'ice_candidate',
          encrypted: const {},
        ),
        throwsCrypto('session_keys_not_ready'),
      );
    });

    test('begin and non-resync offer calls reject an active handshake',
        () async {
      final (caller, callee, ephA, callerSig) = await _handshake();
      final offerFps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      final answerFps = CallSignalingCrypto.extractDtlsFingerprints(answerSdp);
      expect(
        caller.beginOffer(
          callId: 'another-call',
          myId: 'devA',
          peerId: 'devB',
          offerDtlsFps: offerFps,
        ),
        throwsCrypto('active_handshake'),
      );
      expect(
        callee.beginAnswer(
          peerId: 'devA',
          callerSig: callerSig,
          offerDtlsFps: offerFps,
          answerDtlsFps: answerFps,
        ),
        throwsCrypto('active_handshake'),
      );
      expect(
        callee.decryptOffer(
          callId: 'another-call',
          callerId: 'devA',
          ephA: ephA,
          encrypted: const {'n': '', 'c': '', 'k': '0'},
        ),
        throwsCrypto('active_handshake'),
      );
    });

    test('active-handshake guards run before peer resolution', () async {
      final a = await _mk(), b = await _mk();
      final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
      var pinAvailable = true;
      var resolveCalls = 0;
      String? r(String id) {
        resolveCalls++;
        return pinAvailable ? pins[id] : null;
      }

      final caller = CallSignalingCrypto(
          dh: a.dh, sign: a.sign, myDeviceId: 'devA', resolvePeerBundle: r);
      final callee = CallSignalingCrypto(
          dh: b.dh, sign: b.sign, myDeviceId: 'devB', resolvePeerBundle: r);
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      final begin = await caller.beginOffer(
          callId: 'guarded-call',
          myId: 'devA',
          peerId: 'devB',
          offerDtlsFps: fps);
      final encrypted = await caller.encryptOffer(offerSdp);
      await callee.decryptOffer(
        callId: 'guarded-call',
        callerId: 'devA',
        ephA: begin.eph,
        encrypted: encrypted,
      );

      pinAvailable = false;
      resolveCalls = 0;
      expect(
        caller.beginOffer(
          callId: 'overlap',
          myId: 'devA',
          peerId: 'devB',
          offerDtlsFps: fps,
        ),
        throwsCrypto('active_handshake'),
      );
      expect(
        caller.beginAnswer(
          peerId: 'devB',
          callerSig: begin.fp,
          offerDtlsFps: fps,
          answerDtlsFps: const [],
        ),
        throwsCrypto('active_handshake'),
      );
      expect(
        caller.decryptOffer(
          callId: 'overlap',
          callerId: 'devA',
          ephA: begin.eph,
          encrypted: const {'n': '', 'c': '', 'k': '0'},
        ),
        throwsCrypto('active_handshake'),
      );
      expect(
        await callee.decryptOffer(
          callId: 'guarded-call',
          callerId: 'devA',
          ephA: begin.eph,
          encrypted: Map<String, String>.from(encrypted),
        ),
        offerSdp,
      );
      expect(resolveCalls, 0);
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

    test('invalid directions are rejected before key selection', () async {
      final (caller, callee, _, __) = await _handshake();
      expect(
        () => caller.encryptMessage(
          direction: 'sideways',
          event: 'ice_candidate',
          plaintext: 'x',
        ),
        throwsCrypto('invalid_direction'),
      );
      expect(
        () => callee.decryptMessage(
          direction: 'sideways',
          event: 'ice_candidate',
          encrypted: const {},
        ),
        throwsCrypto('invalid_direction'),
      );
    });

    test('replay windows are independent per direction', () async {
      final (caller, callee, _, __) = await _handshake();
      final a2b0 = await caller.encryptMessage(
        direction: 'a2b',
        event: 'ice_candidate',
        plaintext: 'a0',
      );
      final b2a0 = await callee.encryptMessage(
        direction: 'b2a',
        event: 'ice_candidate',
        plaintext: 'b0',
      );
      expect(
        await callee.decryptMessage(
          direction: 'a2b',
          event: 'ice_candidate',
          encrypted: a2b0,
        ),
        'a0',
      );
      expect(
        await caller.decryptMessage(
          direction: 'b2a',
          event: 'ice_candidate',
          encrypted: b2a0,
        ),
        'b0',
      );
      expect(
        callee.decryptMessage(
          direction: 'a2b',
          event: 'ice_candidate',
          encrypted: a2b0,
        ),
        throwsCrypto('replayed'),
      );
      final b2a1 = await callee.encryptMessage(
        direction: 'b2a',
        event: 'ice_candidate',
        plaintext: 'b1',
      );
      expect(
        await caller.decryptMessage(
          direction: 'b2a',
          event: 'ice_candidate',
          encrypted: b2a1,
        ),
        'b1',
      );
    });

    test('random GCM nonces are 12 bytes and unique', () async {
      final (caller, _, __, ___) = await _handshake();
      final nonces = <String>{};
      for (var i = 0; i < 256; i++) {
        final encrypted = await caller.encryptMessage(
          direction: 'a2b',
          event: 'ice_candidate',
          plaintext: 'candidate-$i',
        );
        expect(base64Decode(encrypted['n']!), hasLength(12));
        nonces.add(encrypted['n']!);
      }
      expect(nonces, hasLength(256));
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
          callId: 'c', myId: 'devA', peerId: 'devB', offerDtlsFps: fps);
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
            callId: 'c', myId: 'devA', peerId: 'devB', offerDtlsFps: fps),
        throwsA(isA<CallSignalingCryptoException>()),
      );
    });

    test('identity unavailable → typed error, not null crash', () async {
      final a = await _mk(), b = await _mk();
      final deadDh = (_) async => throw const IdentityUnavailableException();
      final c = CallSignalingCrypto(
        dh: deadDh,
        sign: a.sign,
        myDeviceId: 'devA',
        resolvePeerBundle: (_) => null,
      );
      final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
      final bundleB = await b.bundle();
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          c.beginOfferFirstContact(
              callId: 'x$attempt',
              myId: 'devA',
              peerId: 'devB',
              peerBundleB64: bundleB,
              offerDtlsFps: fps),
          throwsA(isA<IdentityUnavailableException>()),
        );
      }
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

    test('dispose resets decrypt failures and handshake guards', () async {
      final (_, callee, __, ___) = await _handshake();
      try {
        await callee.decryptMessage(
          direction: 'a2b',
          event: 'ice_candidate',
          encrypted: const {'n': '', 'c': '', 'k': '0'},
        );
      } catch (_) {}
      expect(callee.decryptFailures, 1);
      callee.dispose();
      expect(callee.decryptFailures, 0);
      final offer = await callee.beginOffer(
        callId: 'after-dispose',
        myId: 'devB',
        peerId: 'devA',
        offerDtlsFps: CallSignalingCrypto.extractDtlsFingerprints(offerSdp),
      );
      expect(offer.eph, hasLength(32));
    });

    test('unsupported IdentityService signing domains are rejected', () async {
      final identity = IdentityService();
      expect(
        () => identity.signBytes('attacker-domain', const [1, 2, 3]),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        identity.signBytes(
          IdentityService.domainCallFingerprint,
          const [1, 2, 3],
        ),
        throwsA(isA<IdentityUnavailableException>()),
      );
    });

    test('malformed wire records — missing, empty, oversized fields', () async {
      final (_, callee, __, ___) = await _handshake();
      Future<void> bad(Map<String, String> m) async {
        try {
          await callee.decryptMessage(
              direction: 'a2b', event: 'ice_candidate', encrypted: m);
        } catch (_) {} // counted or thrown — must never crash
      }

      await bad({}); // missing keys
      await bad({'n': '', 'c': '', 'k': ''}); // empty strings
      await bad({'n': '!!!', 'c': '!!!', 'k': 'x'}); // bad b64/int
      await bad({'n': 'AAAA', 'c': 'AAAA', 'k': '-1'}); // negative counter
      await bad({'n': 'AAAA', 'c': 'AAAA', 'k': '99999999999'});
      // oversized nonce field (b64 of 1KB)
      await bad({
        'n': base64Encode(List.filled(1024, 1)),
        'c': base64Encode(List.filled(32, 2)),
        'k': '1',
      });
      // huge ciphertext field — beyond cap must reject pre-parse
      await bad({
        'n': base64Encode(List.filled(12, 3)),
        'c': base64Encode(List.filled(200000, 4)),
        'k': '1',
      });
    });

    test('20 duplicate records do NOT push toward crypto_failed', () async {
      final (caller, callee, _, __) = await _handshake();
      final m = await caller.encryptMessage(
          direction: 'a2b', event: 'ice_candidate', plaintext: 'dup');
      await callee.decryptMessage(
          direction: 'a2b', event: 'ice_candidate', encrypted: m);
      for (var i = 0; i < 20; i++) {
        try {
          await callee.decryptMessage(
              direction: 'a2b', event: 'ice_candidate', encrypted: m);
        } catch (_) {}
      }
      // Call still healthy — a fresh message decrypts fine.
      final fresh = await caller.encryptMessage(
          direction: 'a2b', event: 'ice_candidate', plaintext: 'fresh');
      expect(
        await callee.decryptMessage(
            direction: 'a2b', event: 'ice_candidate', encrypted: fresh),
        'fresh',
      );
      expect(callee.decryptFailures, 0); // replays never counted
    });

    test('mixed: 7 auth failures + 100 duplicates + 1 failure = crypto_failed',
        () async {
      final (caller, callee, _, __) = await _handshake();
      // 7 real auth failures
      for (var i = 0; i < 7; i++) {
        try {
          await callee.decryptMessage(
              direction: 'a2b',
              event: 'ice_candidate',
              encrypted: {'n': 'AAAA', 'c': 'AAAA', 'k': '500$i'});
        } catch (_) {}
      }
      // 100 duplicates of a valid record — replays never count
      final dup = await caller.encryptMessage(
          direction: 'a2b', event: 'ice_candidate', plaintext: 'd');
      await callee.decryptMessage(
          direction: 'a2b', event: 'ice_candidate', encrypted: dup);
      for (var i = 0; i < 100; i++) {
        try {
          await callee.decryptMessage(
              direction: 'a2b', event: 'ice_candidate', encrypted: dup);
        } catch (_) {}
      }
      expect(callee.decryptFailures, 7);
      // 8th real failure → crypto_failed
      expect(
        callee.decryptMessage(
            direction: 'a2b',
            event: 'ice_candidate',
            encrypted: {'n': 'AAAA', 'c': 'AAAA', 'k': '5007'}),
        throwsA(isA<CallSignalingCryptoException>()),
      );
    });

    test('release-mode guard: seeded ephemeral throws, no fallback', () async {
      CallSignalingCrypto.debugForceReleaseMode = true;
      try {
        final a = await _mk(), b = await _mk();
        final pins = {'devB': await b.bundle()};
        final c = CallSignalingCrypto(
            dh: a.dh,
            sign: a.sign,
            myDeviceId: 'devA',
            resolvePeerBundle: (id) => pins[id]);
        expect(
          c.beginOffer(
              callId: 'c',
              myId: 'devA',
              peerId: 'devB',
              offerDtlsFps:
                  CallSignalingCrypto.extractDtlsFingerprints(offerSdp),
              ephSeed: Uint8List(32)),
          throwsA(isA<CallSignalingCryptoException>()),
        );
        expect(() => c.sendCountersForTest,
            throwsA(isA<CallSignalingCryptoException>()));
        expect(c.debugKeyBytes('offer'),
            throwsA(isA<CallSignalingCryptoException>()));
      } finally {
        CallSignalingCrypto.debugForceReleaseMode = false;
      }
    });

    test('crypto_failed is sticky — no decrypts accepted after', () async {
      final (caller, callee, _, __) = await _handshake();
      // force the threshold
      for (var i = 0; i < 8; i++) {
        try {
          await callee.decryptMessage(
              direction: 'a2b',
              event: 'ice_candidate',
              encrypted: {'n': 'AAAA', 'c': 'AAAA', 'k': '$i'});
        } catch (_) {}
      }
      // A subsequent perfectly-valid message must still be refused.
      final good = await caller.encryptMessage(
          direction: 'a2b', event: 'ice_candidate', plaintext: 'ok');
      expect(
        callee.decryptMessage(
            direction: 'a2b', event: 'ice_candidate', encrypted: good),
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
          callId: 'c', myId: 'devA', peerId: 'devB', offerDtlsFps: fps);
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
    final a = _TestIdentity(await seeded(0x11), await Ed25519().newKeyPair());
    final b = _TestIdentity(await seeded(0x22), await Ed25519().newKeyPair());
    final pins = {'devB': await b.bundle(), 'devA': await a.bundle()};
    String? r(String id) => pins[id];
    final caller = CallSignalingCrypto(
        dh: a.dh, sign: a.sign, myDeviceId: 'devA', resolvePeerBundle: r);
    final fps = CallSignalingCrypto.extractDtlsFingerprints(offerSdp);
    final begin = await caller.beginOffer(
        callId: 'call_vec',
        myId: 'devA',
        peerId: 'devB',
        offerDtlsFps: fps,
        ephSeed: Uint8List(32)..fillRange(0, 32, 0x33));
    expect(base64Encode(await caller.debugKeyBytes('offer')),
        'sxUpzdQz1IjJyDeaElrpIy3u5KGQKvzrlwz2c71bVOQ=');

    // Callee side: decrypt the offer with the seeded ephemeral, answer with
    // the seeded ephB — the derived kAB/kBA must equal Node's on BOTH roles.
    final callee = CallSignalingCrypto(
        dh: b.dh, sign: b.sign, myDeviceId: 'devB', resolvePeerBundle: r);
    final encOffer = await caller.encryptOffer(offerSdp);
    await callee.decryptOffer(
        callId: 'call_vec',
        callerId: 'devA',
        ephA: begin.eph,
        encrypted: encOffer);
    final af = CallSignalingCrypto.extractDtlsFingerprints(answerSdp);
    final ans = await callee.beginAnswer(
        peerId: 'devA',
        callerSig: begin.fp,
        offerDtlsFps: fps,
        answerDtlsFps: af,
        ephSeed: Uint8List(32)..fillRange(0, 32, 0x44));
    await caller.completeHandshake(
        peerId: 'devB', ephB: ans.eph, calleeSig: ans.fp, answerDtlsFps: af);

    for (final side in [caller, callee]) {
      expect(base64Encode(await side.debugKeyBytes('kAB')),
          '/IkeMhMugLy5BK+bl6d4zSoltgmVlT2/3+EdGVTfasY=');
      expect(base64Encode(await side.debugKeyBytes('kBA')),
          'K8wQP4gxFxPuOqrGvrlep+Fm6X2ocgVSUxxC/YgNjAs=');
    }
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
