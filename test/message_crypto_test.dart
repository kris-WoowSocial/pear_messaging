import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pear_messaging/core/crypto/media_crypto.dart';
import 'package:pear_messaging/core/crypto/pq_kem_service.dart';
import 'package:pear_messaging/core/services/group_crypto_service.dart';
import 'package:pear_messaging/core/services/encryption_service.dart';
import 'package:pear_messaging/core/services/identity_service.dart';
import 'package:pear_messaging/core/services/message_crypto_service.dart';

/// Build a shared root key the way the service does:
/// rk = HKDF(X25519(aId, bIdPub)) — symmetric on both sides.
Future<Uint8List> _sharedRootKey(KeyPair a, KeyPair b) async {
  final bPub = (await b.extractPublicKey() as SimplePublicKey).bytes;
  final aPub = (await a.extractPublicKey() as SimplePublicKey).bytes;
  final dhAB = await X25519().sharedSecretKey(
    keyPair: a,
    remotePublicKey: SimplePublicKey(bPub, type: KeyPairType.x25519),
  );
  final dhBA = await X25519().sharedSecretKey(
    keyPair: b,
    remotePublicKey: SimplePublicKey(aPub, type: KeyPairType.x25519),
  );
  final ab = await dhAB.extractBytes();
  final ba = await dhBA.extractBytes();
  expect(ab, equals(ba), reason: 'X25519 must be symmetric');
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final rk = await hkdf.deriveKey(
    secretKey: SecretKey(ab),
    nonce: const <int>[],
    info: utf8.encode('vant-msg-rk'),
  );
  return Uint8List.fromList(await rk.extractBytes());
}

Future<({RatchetCore a, RatchetCore b})> _pair() async {
  final aId = await X25519().newKeyPair();
  final bId = await X25519().newKeyPair();
  final rk = await _sharedRootKey(aId, bId);
  // device ids 'aaa' < 'bbb' → A is the lexically-low side.
  return (
    a: await RatchetCore.create(rootKey: rk, iAmLow: true),
    b: await RatchetCore.create(rootKey: rk, iAmLow: false),
  );
}

Uint8List _pack(String text) =>
    padToBucket(Uint8List.fromList(utf8.encode(jsonEncode({'t': text}))));

Future<String> _enc(RatchetCore core, String text) async =>
    (await core.encrypt(_pack(text)))!;

Future<String> _unpack(RatchetCore core, String env) async {
  final padded = await core.decrypt(env);
  if (padded == null) throw StateError('decrypt failed');
  final plain = unpadBucket(padded);
  if (plain == null) throw StateError('unpad failed');
  return (jsonDecode(utf8.decode(plain)) as Map<String, dynamic>)['t']
      as String;
}

Map<String, dynamic> _envJson(String env) => jsonDecode(
    utf8.decode(base64Url.decode(env.substring(env.indexOf(':') + 1))))
    as Map<String, dynamic>;

Future<Uint8List?> _tryOpen(Map<String, dynamic> envJson, Uint8List mk) async {
  try {
    final aad = utf8.encode(
        'v2|${envJson['e']}|${envJson['n']}|${envJson['pn'] ?? 0}');
    final pt = await AesGcm.with256bits().decrypt(
      SecretBox.fromConcatenation(
        base64Decode(envJson['nonce'] as String) +
            base64Decode(envJson['ct'] as String),
        nonceLength: 12,
        macLength: 16,
      ),
      secretKey: SecretKey(mk),
      aad: aad,
    );
    return Uint8List.fromList(pt);
  } catch (_) {
    return null;
  }
}

void main() {
  group('RatchetCore — per-message ratcheted X25519 + AES-256-GCM', () {
    test('bootstrap + reply ratchet round trip', () async {
      final p = await _pair();
      final m1 = await _enc(p.a, 'hello');
      expect(m1.startsWith(kV2Prefix), isTrue);
      expect(await _unpack(p.b, m1), 'hello');

      // B replies → first DH ratchet step on both sides.
      final r1 = await _enc(p.b, 'hi back');
      expect(await _unpack(p.a, r1), 'hi back');

      // A sends again → another ratchet step.
      final m2 = await _enc(p.a, 'again');
      expect(await _unpack(p.b, m2), 'again');
    });

    test('identical plaintexts produce different ciphertext, nonce, chain',
        () async {
      final p = await _pair();
      final e1 = await _enc(p.a, 'hello');
      final e2 = await _enc(p.a, 'hello');
      final j1 = _envJson(e1);
      final j2 = _envJson(e2);
      expect(j1['ct'], isNot(equals(j2['ct'])));
      // First 12 bytes of the concatenation are the random nonce.
      expect(base64Decode(j1['ct'] as String).sublist(0, 12),
          isNot(equals(base64Decode(j2['ct'] as String).sublist(0, 12))));
      expect(j1['n'], 0);
      expect(j2['n'], 1);
      // Every ciphertext opens on the peer — chain advanced correctly.
      expect(await _unpack(p.b, e1), 'hello');
      expect(await _unpack(p.b, e2), 'hello');
    });

    test('forward secrecy: later chain key cannot decrypt earlier message',
        () async {
      final p = await _pair();
      final e0 = await _enc(p.a, 'first');
      final e1 = await _enc(p.a, 'second');
      final j0 = _envJson(e0);

      // B consumes both — its recv chain key is now post-message-1.
      expect(await _unpack(p.b, e0), 'first');
      expect(await _unpack(p.b, e1), 'second');

      // Compromise the CURRENT receive chain key from the dumped state.
      final state = p.b.dumpState();
      final compromisedCk =
          Uint8List.fromList(base64Decode(state['rck'] as String? ??
              state['brck'] as String));

      // Walk the compromised chain forward — none of the derived keys may
      // open the earlier ciphertext (all AES-GCM attempts must fail).
      var ck = compromisedCk;
      for (var i = 0; i < 6; i++) {
        final mk = Uint8List.fromList((await Hmac.sha256()
                .calculateMac([0x01], secretKey: SecretKey(ck)))
            .bytes);
        expect(await _tryOpen(j0, mk), isNull,
            reason: 'forward-derived key $i must not decrypt earlier msg');
        ck = Uint8List.fromList((await Hmac.sha256()
                .calculateMac([0x02], secretKey: SecretKey(ck)))
            .bytes);
      }
    });

    test('out-of-order delivery decrypts via skipped-key cache', () async {
      final p = await _pair();
      final e0 = await _enc(p.a, 'm0');
      final e1 = await _enc(p.a, 'm1');
      final e2 = await _enc(p.a, 'm2');

      // Deliver 1, 2, then the straggler 0.
      expect(await _unpack(p.b, e1), 'm1');
      expect(await _unpack(p.b, e2), 'm2');
      expect(await _unpack(p.b, e0), 'm0');
    });

    test('replay of a consumed counter is rejected', () async {
      final p = await _pair();
      final e0 = await _enc(p.a, 'once');
      expect(await _unpack(p.b, e0), 'once');
      expect(await p.b.decrypt(e0), isNull, reason: 'replay must not open');
    });

    test('reflected own-ephemeral frame is rejected', () async {
      final p = await _pair();
      final e0 = await _enc(p.a, 'reflect me');
      // Attacker sends A's own frame back to A — its ephemeral matches
      // A's advertised key, so it can never authenticate.
      expect(await p.a.decrypt(e0), isNull);
      // And the real peer still decrypts normally.
      expect(await _unpack(p.b, e0), 'reflect me');
    });

    test('state persists: dump/restore keeps the chain intact', () async {
      final p = await _pair();
      final e0 = await _enc(p.a, 'before restart');
      expect(await _unpack(p.b, e0), 'before restart');

      // Simulate an app restart: restore B's core from persisted JSON.
      final restored = RatchetCore.restore(p.b.dumpState(), iAmLow: false);
      expect(restored, isNotNull);

      final e1 = await _enc(p.a, 'after restart');
      expect(await _unpack(restored!, e1), 'after restart');

      // And the reply path still ratchets.
      final r = await _enc(restored, 'resumed reply');
      expect(await _unpack(p.a, r), 'resumed reply');
    });
  });

  group('padding — ISO7816-4 fixed buckets', () {
    test('pads to the next bucket size', () {
      for (final len in [1, 100, 255]) {
        expect(padToBucket(Uint8List(len)).length, 256);
      }
      expect(padToBucket(Uint8List(256)).length, 512);
      expect(padToBucket(Uint8List(600)).length, 1024);
      expect(padToBucket(Uint8List(2000)).length, 4096);
      // Beyond the largest bucket: next 4096 multiple.
      expect(padToBucket(Uint8List(5000)).length, 8192);
    });

    test('round-trips and rejects malformed padding', () {
      final data = Uint8List.fromList(utf8.encode('{"t":"pad me"}'));
      final padded = padToBucket(data);
      expect(unpadBucket(padded), equals(data));
      expect(unpadBucket(Uint8List(256)), isNull); // all zeros, no 0x80
    });
  });

  group('sealed sender (v2s)', () {
    Future<({KeyPair x, KeyPair ed})> keys() async =>
        (x: await X25519().newKeyPair(), ed: await Ed25519().newKeyPair());

    Future<Uint8List> sign(KeyPair ed, List<int> message) async {
      final sig = await Ed25519().sign(
        IdentityService.domainBoundMessage(
            IdentityService.domainMsgSeal, message),
        keyPair: ed,
      );
      return Uint8List.fromList(sig.bytes);
    }

    test('wraps + unwraps; sender hidden from the outer packet', () async {
      final sender = await keys();
      final recip = await keys();
      const senderId = 'alice111';
      const recipientId = 'bob2222';
      const inner = 'v2:ZW52ZWxvcGU';

      final sealed = await MessageCryptoService.sealEnvelope(
        senderId: senderId,
        recipientId: recipientId,
        recipientX25519Pub:
            Uint8List.fromList((await sender.x.extractPublicKey() as SimplePublicKey).bytes
                .map((_) => 0)
                .toList()),
        innerV2: inner,
        signFn: (m) => sign(sender.ed, m),
      );
      expect(sealed, isNull,
          reason: 'a zeroed pubkey must fail or produce unusable seal');

      final recipPub =
          Uint8List.fromList((await recip.x.extractPublicKey() as SimplePublicKey).bytes);
      final sealed2 = await MessageCryptoService.sealEnvelope(
        senderId: senderId,
        recipientId: recipientId,
        recipientX25519Pub: recipPub,
        innerV2: inner,
        signFn: (m) => sign(sender.ed, m),
      );
      expect(sealed2, isNotNull);
      expect(sealed2!.startsWith(kV2sPrefix), isTrue);

      // The outer packet must not expose the sender id or inner envelope.
      final outer = _envJson(sealed2);
      expect(outer.containsKey('s'), isFalse);
      expect(outer.containsKey('senderDeviceId'), isFalse);
      expect(sealed2.contains(senderId), isFalse);
      expect(sealed2.contains(inner), isFalse);

      final opened = await MessageCryptoService.openSealedEnvelope(
        envelope: sealed2,
        myId: recipientId,
        dhFn: (ephPub) => X25519().sharedSecretKey(
          keyPair: recip.x,
          remotePublicKey:
              SimplePublicKey(ephPub, type: KeyPairType.x25519),
        ),
        verifyFn: (sid, message, sigB64) async {
          return Ed25519().verify(
            IdentityService.domainBoundMessage(
                IdentityService.domainMsgSeal, message),
            signature: Signature(
              base64Decode(sigB64),
              publicKey: SimplePublicKey(
                  (await sender.ed.extractPublicKey() as SimplePublicKey).bytes,
                  type: KeyPairType.ed25519),
            ),
          );
        },
      );
      expect(opened, isNotNull);
      expect(opened!.senderId, senderId);
      expect(opened.innerV2, inner);
    });

    test('wrong-recipient verify binding is rejected', () async {
      final sender = await keys();
      final recip = await keys();
      final recipPub =
          Uint8List.fromList((await recip.x.extractPublicKey() as SimplePublicKey).bytes);
      final sealed = await MessageCryptoService.sealEnvelope(
        senderId: 'alice111',
        recipientId: 'bob2222',
        recipientX25519Pub: recipPub,
        innerV2: 'v2:ZW52ZWxvcGU',
        signFn: (m) => sign(sender.ed, m),
      );
      // The signature binds 'bob2222|<inner>' — verifying under a
      // different recipient id must fail.
      final opened = await MessageCryptoService.openSealedEnvelope(
        envelope: sealed!,
        myId: 'eve3333',
        dhFn: (ephPub) => X25519().sharedSecretKey(
          keyPair: recip.x,
          remotePublicKey:
              SimplePublicKey(ephPub, type: KeyPairType.x25519),
        ),
        verifyFn: (sid, message, sigB64) async {
          return Ed25519().verify(
            IdentityService.domainBoundMessage(
                IdentityService.domainMsgSeal, message),
            signature: Signature(
              base64Decode(sigB64),
              publicKey: SimplePublicKey(
                  (await sender.ed.extractPublicKey() as SimplePublicKey).bytes,
                  type: KeyPairType.ed25519),
            ),
          );
        },
      );
      expect(opened, isNull);
    });

    test('wrong recipient private key cannot open', () async {
      final sender = await keys();
      final recip = await keys();
      final attacker = await keys();
      final sealed = await MessageCryptoService.sealEnvelope(
        senderId: 'alice111',
        recipientId: 'bob2222',
        recipientX25519Pub:
            Uint8List.fromList((await recip.x.extractPublicKey() as SimplePublicKey).bytes),
        innerV2: 'v2:ZW52ZWxvcGU',
        signFn: (m) => sign(sender.ed, m),
      );
      final opened = await MessageCryptoService.openSealedEnvelope(
        envelope: sealed!,
        myId: 'bob2222',
        dhFn: (ephPub) => X25519().sharedSecretKey(
          keyPair: attacker.x,
          remotePublicKey:
              SimplePublicKey(ephPub, type: KeyPairType.x25519),
        ),
        verifyFn: (_, __, ___) async => true,
      );
      expect(opened, isNull);
    });
  });

  group('wire contract — no static XOR on outgoing path', () {
    final socketSrc =
        File('lib/core/services/socket_service.dart').readAsStringSync();
    final serverSrc = File('../vant_chatting/server/src/sockets/'
            'chat.handlers.js')
        .existsSync()
        ? File('../vant_chatting/server/src/sockets/chat.handlers.js')
            .readAsStringSync()
        : '';

    test('sealed emit claims no senderDeviceId on the wire', () {
      final idx = socketSrc.indexOf("'sealed': true");
      expect(idx, greaterThan(0), reason: 'sealed emit must exist');
      // The sealed emit block must not claim senderDeviceId — the
      // registered socket is the server-side proof.
      final blockStart = socketSrc.lastIndexOf("emit('send_message'", idx);
      final block = socketSrc.substring(blockStart, idx);
      expect(block.contains('senderDeviceId'), isFalse);
      expect(block.contains('receiverDeviceId'), isTrue);
      // Generic notification label only.
      expect(socketSrc.contains("'body': 'New message'"), isTrue);
    });

    test('E2E is gated on the signed e2e_msg capability + pinned bundle', () {
      expect(socketSrc.contains('canSealTo'), isTrue);
      expect(socketSrc.contains('sealForPeer'), isTrue);
      final cryptoSrc =
          File('lib/core/services/message_crypto_service.dart')
              .readAsStringSync();
      expect(cryptoSrc.contains("'e2e_msg'"), isTrue);
      expect(cryptoSrc.contains('peerHasCapability'), isTrue);
      expect(cryptoSrc.contains('getPeerBundle'), isTrue);
    });

    test('server strips sender fields for sealed packets', () {
      if (serverSrc.isEmpty) {
        return; // server repo not adjacent — client tests unaffected
      }
      expect(serverSrc.contains('v2s:|v3s:'), isTrue);
      expect(serverSrc.contains('sealed: true'), isTrue);
      // Sealed identity derives from the registered socket, never the
      // client's claimed sender field.
      expect(serverSrc.contains('isSealed ? registeredDeviceId'), isTrue);
      expect(serverSrc.contains('!isSealed && !claimedSender'), isTrue);
      expect(
          serverSrc.contains('!isSealed && registeredDeviceId !== claimedSender'),
          isTrue);
    });
  });

  group('ML-KEM-768 primitive (FIPS 203)', () {
    test('keygen/encapsulate/decapsulate sizes + round trip', () async {
      final kp = await PqKemService.generateKeyPair();
      expect(kp.publicKey.length, PqKemService.publicKeyBytes);
      expect(kp.secretKey.length, PqKemService.secretKeyBytes);
      final enc = await PqKemService.encapsulate(kp.publicKey);
      expect(enc.ciphertext.length, PqKemService.ciphertextBytes);
      expect(enc.sharedSecret.length, PqKemService.sharedSecretBytes);
      final ss = await PqKemService.decapsulate(
          enc.ciphertext, kp.secretKey);
      expect(ss, equals(enc.sharedSecret));
    });

    test('encapsulate rejects wrong-length and zero public keys', () {
      expect(() => PqKemService.encapsulate(Uint8List(10)),
          throwsArgumentError);
      expect(() => PqKemService.encapsulate(Uint8List(1184)),
          throwsArgumentError,
          reason: 'all-zero encapsulation key must be rejected');
    });

    test('decapsulate rejects wrong-length inputs', () {
      expect(
          () =>
              PqKemService.decapsulate(Uint8List(10), Uint8List(2400)),
          throwsArgumentError);
      expect(
          () =>
              PqKemService.decapsulate(Uint8List(1088), Uint8List(32)),
          throwsArgumentError);
    });

    test('tampered ciphertext → different secret (implicit rejection)',
        () async {
      final kp = await PqKemService.generateKeyPair();
      final enc = await PqKemService.encapsulate(kp.publicKey);
      final tampered = Uint8List.fromList(enc.ciphertext)..[0] ^= 0x01;
      final ss = await PqKemService.decapsulate(tampered, kp.secretKey);
      expect(ss, isNot(equals(enc.sharedSecret)),
          reason:
              'FIPS 203 implicit rejection must yield a foreign secret');
    });
  });

  group('RatchetCore v3 — hybrid X25519 + ML-KEM-768', () {
    Future<({RatchetCore a, RatchetCore b, PqKeyPair aPq, PqKeyPair bPq})>
        pqPair() async {
      final aId = await X25519().newKeyPair();
      final bId = await X25519().newKeyPair();
      final rk = await _sharedRootKey(aId, bId);
      final aPq = await PqKemService.generateKeyPair();
      final bPq = await PqKemService.generateKeyPair();
      // Raw identity X25519 output — the hybrid combiner's ssX input.
      final bPub = (await bId.extractPublicKey()).bytes;
      final ssX = Uint8List.fromList(await (await X25519()
              .sharedSecretKey(
        keyPair: aId,
        remotePublicKey:
            SimplePublicKey(bPub, type: KeyPairType.x25519),
      ))
          .extractBytes());
      return (
        a: await RatchetCore.create(
          rootKey: rk,
          iAmLow: true,
          isPostQuantum: true,
          peerPqPub: bPq.publicKey,
          ssX25519: () async => Uint8List.fromList(ssX),
          myPqSecretKey: () async => Uint8List.fromList(aPq.secretKey),
        ),
        b: await RatchetCore.create(
          rootKey: rk,
          iAmLow: false,
          isPostQuantum: true,
          peerPqPub: aPq.publicKey,
          ssX25519: () async => Uint8List.fromList(ssX),
          myPqSecretKey: () async => Uint8List.fromList(bPq.secretKey),
        ),
        aPq: aPq,
        bPq: bPq,
      );
    }

    test('v3 sealed-session round trip; kemCt only until epoch ack',
        () async {
      final p = await pqPair();
      final m1 = await _enc(p.a, 'pq hello');
      expect(m1.startsWith(kV3Prefix), isTrue);
      final j1 = _envJson(m1);
      expect(j1['pq'], 1);
      expect(j1['kct'], isNotNull);
      expect(base64Decode(j1['kct'] as String).length, 1088);
      expect(await _unpack(p.b, m1), 'pq hello');

      // The pending ciphertext re-attaches until the peer's ack proves
      // decapsulation — a lost first frame must not deadlock the epoch.
      final m2 = await _enc(p.a, 'still pending');
      expect(_envJson(m2)['kct'], isNotNull);
      expect(await _unpack(p.b, m2), 'still pending');

      // B's reply carries ka=1 — A's epoch is acked; kct drops off.
      final r1 = await _enc(p.b, 'pq reply');
      final jr = _envJson(r1);
      expect(jr['ka'], 1);
      expect(jr['kct'], isNull);
      expect(await _unpack(p.a, r1), 'pq reply');

      final m3 = await _enc(p.a, 'post ack');
      expect(_envJson(m3)['kct'], isNull,
          reason:
              'post-ack frames must carry zero 1.1KB KEM overhead');
      expect(await _unpack(p.b, m3), 'post ack');
    });

    test('epoch rotates after 100 sent messages', () async {
      final p = await pqPair();
      await _unpack(p.b, await _enc(p.a, 'epoch1'));
      await _unpack(p.a, await _enc(p.b, 'ack')); // clears A's pending
      // Deliver each frame in order — the epoch chain derives from A's
      // current root key, so B must track the intermediate ratchets.
      for (var i = 0; i < 99; i++) {
        await _unpack(p.b, await _enc(p.a, 'm$i'));
      }
      final rotated = await _enc(p.a, 'epoch2');
      final j = _envJson(rotated);
      expect(j['pq'], 2);
      expect(j['kct'], isNotNull);
      // And the new epoch still decrypts end-to-end.
      expect(await _unpack(p.b, rotated), 'epoch2');
    });

    test('tampered kemCt fails authentication cleanly', () async {
      final p = await pqPair();
      final m1 = await _enc(p.a, 'untampered');
      final j = _envJson(m1);
      final kct = base64Decode(j['kct'] as String)..[7] ^= 0x40;
      final forged =
          'v3:${base64UrlEncode(utf8.encode(jsonEncode({
            ...j,
            'kct': base64Encode(kct),
          })))}';
      expect(await p.b.decrypt(forged), isNull,
          reason:
              'AAD binds kct AND implicit rejection yields a wrong chain');
    });

    test('forged epoch / ratchet frames leave state untouched', () async {
      // v3 session: a forged epoch frame must not desync the receiver.
      final p = await pqPair();
      final m1 = await _enc(p.a, 'genuine epoch');
      final j1 = _envJson(m1);
      final stateBefore = jsonEncode(p.b.dumpState());

      // Forge: new-epoch frame with a tampered KEM ciphertext.
      final badKct = base64Decode(j1['kct'] as String)..[0] ^= 0x01;
      final forgedEpoch =
          'v3:${base64UrlEncode(utf8.encode(jsonEncode({
            ...j1,
            'kct': base64Encode(badKct),
          })))}';
      expect(await p.b.decrypt(forgedEpoch), isNull);
      expect(jsonEncode(p.b.dumpState()), stateBefore,
          reason: 'forged epoch must not mutate recv state');

      // Forge: valid-length garbage KEM ciphertext (different ephemeral).
      final p2 = await pqPair();
      final m2 = await _enc(p2.a, 'another epoch');
      final j2 = _envJson(m2);
      final before2 = jsonEncode(p2.b.dumpState());
      final forgedEpoch2 =
          'v3:${base64UrlEncode(utf8.encode(jsonEncode({
            ...j2,
            'kct': base64Encode(
                Uint8List(1088)..[55] = 0xAA),
          })))}';
      expect(await p2.b.decrypt(forgedEpoch2), isNull);
      expect(jsonEncode(p2.b.dumpState()), before2,
          reason: 'state must be identical after forged epoch');

      // v2 session: forged DH-ratchet frame (new-eph header, garbage body).
      final v2 = await _pair();
      final v2frame = await _enc(v2.a, 'real');
      await _unpack(v2.b, v2frame); // B now has a live ratchet chain
      final before3 = jsonEncode(v2.b.dumpState());
      final jv = _envJson(v2frame)..remove('b');
      final fakeEph = (await (await X25519().newKeyPair())
              .extractPublicKey())
          .bytes;
      final forgedRatchet =
          'v2:${base64UrlEncode(utf8.encode(jsonEncode({
            ...jv,
            'e': base64Encode(fakeEph),
            'n': 0,
            'pn': 1,
          })))}';
      expect(await v2.b.decrypt(forgedRatchet), isNull);
      expect(jsonEncode(v2.b.dumpState()), before3,
          reason: 'forged DH ratchet must not mutate recv state');
      // And the next genuine frame still decrypts.
      final next = await _enc(v2.a, 'still works');
      expect(await _unpack(v2.b, next), 'still works');
    });

    test('epoch frame without kct is rejected', () async {
      final p = await pqPair();
      final m1 = await _enc(p.a, 'need ct');
      final j = _envJson(m1);
      final forged =
          'v3:${base64UrlEncode(utf8.encode(jsonEncode({...j}..remove('kct'))))}';
      expect(await p.b.decrypt(forged), isNull);
    });

    test('v2 core rejects v3 frames', () async {
      final classic = await _pair();
      final pq = await pqPair();
      final v3frame = await _enc(pq.a, 'pq');
      expect(await classic.b.decrypt(v3frame), isNull,
          reason: 'a v3 frame must not open on a classical session');
    });

    test('v3 state survives dump/restore', () async {
      final p = await pqPair();
      await _unpack(p.b, await _enc(p.a, 'before restart'));
      final restored = RatchetCore.restore(
        p.b.dumpState(),
        iAmLow: false,
        ssX25519: p.b.ssX25519,
        myPqSecretKey: p.b.myPqSecretKey,
      );
      expect(restored, isNotNull);
      expect(restored!.s.isPostQuantum, isTrue);
      await _unpack(restored, await _enc(p.a, 'after restart'));
      final r = await _enc(restored, 'resumed');
      expect(await _unpack(p.a, r), 'resumed');
    });
  });

  group('sealed sender v3s — hybrid outer envelope', () {
    Future<({KeyPair x, KeyPair ed})> keys() async =>
        (x: await X25519().newKeyPair(), ed: await Ed25519().newKeyPair());

    Future<Uint8List> sign(KeyPair ed, List<int> message) async {
      final sig = await Ed25519().sign(
        IdentityService.domainBoundMessage(
            IdentityService.domainMsgSeal, message),
        keyPair: ed,
      );
      return Uint8List.fromList(sig.bytes);
    }

    test('v3s round trip: sender hidden, opens only with decaps', () async {
      final sender = await keys();
      final recip = await keys();
      final recipPq = await PqKemService.generateKeyPair();
      const senderId = 'alice111';
      const recipientId = 'bob2222';
      const inner = 'v3:aW5uZXJ2Mw';

      final sealed = await MessageCryptoService.sealEnvelope(
        senderId: senderId,
        recipientId: recipientId,
        recipientX25519Pub: Uint8List.fromList(
            (await recip.x.extractPublicKey() as SimplePublicKey).bytes),
        recipientPqPub: recipPq.publicKey,
        innerV2: inner,
        signFn: (m) => sign(sender.ed, m),
      );
      expect(sealed, isNotNull);
      expect(sealed!.startsWith(kV3sPrefix), isTrue);
      final outer = _envJson(sealed);
      expect(base64Decode(outer['kct'] as String).length, 1088);
      expect(sealed.contains(senderId), isFalse);
      expect(sealed.contains(inner), isFalse);

      Future<SecretKey> dh(Uint8List ephPub) => X25519().sharedSecretKey(
            keyPair: recip.x,
            remotePublicKey:
                SimplePublicKey(ephPub, type: KeyPairType.x25519),
          );
      Future<bool> verify(String sid, List<int> msg, String sigB64) async =>
          Ed25519().verify(
            IdentityService.domainBoundMessage(
                IdentityService.domainMsgSeal, msg),
            signature: Signature(
              base64Decode(sigB64),
              publicKey: SimplePublicKey(
                  (await sender.ed.extractPublicKey() as SimplePublicKey)
                      .bytes,
                  type: KeyPairType.ed25519),
            ),
          );

      // Without a decapsulator the v3s envelope cannot open.
      expect(
        await MessageCryptoService.openSealedEnvelope(
          envelope: sealed,
          myId: recipientId,
          dhFn: dh,
          verifyFn: verify,
        ),
        isNull,
      );

      final opened = await MessageCryptoService.openSealedEnvelope(
        envelope: sealed,
        myId: recipientId,
        dhFn: dh,
        verifyFn: verify,
        pqDecapsFn: (ct) =>
            PqKemService.decapsulate(ct, recipPq.secretKey),
      );
      expect(opened, isNotNull);
      expect(opened!.senderId, senderId);
      expect(opened.innerV2, inner);
    });

    test('tampered v3s kemCt fails to open', () async {
      final sender = await keys();
      final recip = await keys();
      final recipPq = await PqKemService.generateKeyPair();
      final sealed = (await MessageCryptoService.sealEnvelope(
        senderId: 'alice111',
        recipientId: 'bob2222',
        recipientX25519Pub: Uint8List.fromList(
            (await recip.x.extractPublicKey() as SimplePublicKey).bytes),
        recipientPqPub: recipPq.publicKey,
        innerV2: 'v3:aW5uZXI',
        signFn: (m) => sign(sender.ed, m),
      ))!;
      final j = _envJson(sealed);
      final kct = base64Decode(j['kct'] as String)..[0] ^= 0x02;
      final forged =
          'v3s:${base64UrlEncode(utf8.encode(jsonEncode({
            ...j,
            'kct': base64Encode(kct),
          })))}';
      final opened = await MessageCryptoService.openSealedEnvelope(
        envelope: forged,
        myId: 'bob2222',
        dhFn: (ephPub) => X25519().sharedSecretKey(
          keyPair: recip.x,
          remotePublicKey:
              SimplePublicKey(ephPub, type: KeyPairType.x25519),
        ),
        verifyFn: (_, __, ___) async => true,
        pqDecapsFn: (ct) =>
            PqKemService.decapsulate(ct, recipPq.secretKey),
      );
      expect(opened, isNull);
    });

    test('downgrade: absent pqPub produces v2s, still opens', () async {
      final sender = await keys();
      final recip = await keys();
      final sealed = await MessageCryptoService.sealEnvelope(
        senderId: 'alice111',
        recipientId: 'bob2222',
        recipientX25519Pub: Uint8List.fromList(
            (await recip.x.extractPublicKey() as SimplePublicKey).bytes),
        innerV2: 'v2:aW5uZXI',
        signFn: (m) => sign(sender.ed, m),
      );
      expect(sealed, isNotNull);
      expect(sealed!.startsWith(kV2sPrefix), isTrue);
      final opened = await MessageCryptoService.openSealedEnvelope(
        envelope: sealed,
        myId: 'bob2222',
        dhFn: (ephPub) => X25519().sharedSecretKey(
          keyPair: recip.x,
          remotePublicKey:
              SimplePublicKey(ephPub, type: KeyPairType.x25519),
        ),
        verifyFn: (_, __, ___) async => true,
      );
      expect(opened, isNotNull);
      expect(opened!.innerV2, 'v2:aW5uZXI');
    });
  });

  // -------------------------------------------------------------------
  // S3 media blob crypto (AES-256-GCM per-file key)
  // -------------------------------------------------------------------
  group('MediaCrypto — per-file AES-256-GCM', () {
    test('encryptBlob produces 32B key + packed nonce||ct||mac blob',
        () async {
      final src = Uint8List.fromList(
          List<int>.generate(1500, (i) => i & 0xff));
      final r = await MediaCrypto.encryptBlob(src);
      expect(base64Decode(r.key).length, 32);
      final packed = base64Decode(r.blob);
      // 12B nonce + 1500B ct + 16B tag
      expect(packed.length, 12 + src.length + 16);
      // digest = sha256(packed)
      final mac = await Sha256().hash(packed);
      expect(base64Encode(mac.bytes), r.digest);
      expect(base64Encode(packed.sublist(12)) ==
          base64Encode(src), isFalse);
    });

    test('refFor encodes token|key|digest; extractRef round-trips',
        () async {
      final r = await MediaCrypto.encryptBlob(Uint8List(4));
      final ref = r.refFor('tok123');
      final parsed = MediaCrypto.extractRef('MEDIA:$ref');
      expect(parsed, isNotNull);
      expect(parsed!.token, 'tok123');
      expect(parsed.key, r.key);
      expect(parsed.digest, r.digest);
      expect(parsed.hasKey, isTrue);
      // FILE:/AUDIO:/IMAGE: prefixes work identically
      expect(MediaCrypto.extractRef('FILE:$ref')!.hasKey, isTrue);
      // bare token = legacy XOR, no key material
      final legacy = MediaCrypto.extractRef('MEDIA:tok123');
      expect(legacy!.hasKey, isFalse);
      // token extraction never carries key material
      expect(MediaCrypto.tokenFromContent('MEDIA:$ref'), 'tok123');
    });

    test('decryptForRef round-trips', () async {
      final src = Uint8List.fromList(
          List<int>.generate(700, (i) => (i * 7) & 0xff));
      final r = await MediaCrypto.encryptBlob(src);
      final ref = MediaCrypto.extractRef('MEDIA:${r.refFor("t")}')!;
      final out = await MediaCrypto.decryptForRef(r.blob, ref);
      expect(out, src);
    });

    test('tampered ciphertext rejected via sha256 digest', () async {
      final src = Uint8List.fromList(List<int>.filled(300, 9));
      final r = await MediaCrypto.encryptBlob(src);
      final packed = base64Decode(r.blob)..[40] ^= 0xff;
      final ref = MediaCrypto.extractRef('MEDIA:${r.refFor("t")}')!;
      expect(
          await MediaCrypto.decryptForRef(base64Encode(packed), ref),
          isNull);
    });

    test('tampered key fails AEAD after digest passes', () async {
      final src = Uint8List.fromList(List<int>.filled(64, 1));
      final r = await MediaCrypto.encryptBlob(src);
      final kb = base64Decode(r.key)..[0] ^= 1;
      final bad = MediaRef(
          token: 't', key: base64Encode(kb), digest: r.digest);
      expect(await MediaCrypto.decryptForRef(r.blob, bad), isNull);
    });

    test('decryptForRef falls back to legacy XOR blobs', () async {
      // Legacy wire blob = XOR(base64(rawBytes))
      final blob = EncryptionService.encryptMessage(
          base64Encode(utf8.encode('hello-legacy')));
      final ref = MediaCrypto.extractRef('MEDIA:oldtok')!;
      final out = await MediaCrypto.decryptForRef(blob, ref);
      expect(utf8.decode(out!), 'hello-legacy');
    });

    test('legacy decrypt returns null for undecryptable blob', () {
      expect(MediaCrypto.decryptLegacyBlob('!!!notbase64!!!'), isNull);
    });
  });

  // -------------------------------------------------------------------
  // Group sender-key frames (v2g:/v3g:) + VGK1 distribution payload
  // -------------------------------------------------------------------
  group('GroupCryptoService — v2g/v3g frames + VGK1', () {
    test('sealFrame/openFrame round-trip (v2g)', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final wire = await GroupCryptoService.sealFrame(
        keyBytes: key,
        keyId: 'kid-1',
        plaintext: 'grp hello',
        postQuantum: false,
      );
      expect(wire.startsWith('v2g:'), isTrue);
      final f = GroupCryptoService.parseFrame(wire);
      expect(f, isNotNull);
      expect(f!.keyId, 'kid-1');
      expect(f.postQuantum, isFalse);
      expect(
          await GroupCryptoService.openFrame(keyBytes: key, frame: f),
          'grp hello');
    });

    test('v3g prefix marks postQuantum frames', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
      final wire = await GroupCryptoService.sealFrame(
        keyBytes: key,
        keyId: 'k2',
        plaintext: 'x',
        postQuantum: true,
      );
      expect(wire.startsWith('v3g:'), isTrue);
      final f = GroupCryptoService.parseFrame(wire)!;
      expect(f.postQuantum, isTrue);
      expect(await GroupCryptoService.openFrame(keyBytes: key, frame: f),
          'x');
    });

    test('openFrame fails on tampered ciphertext and wrong key',
        () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final wire = await GroupCryptoService.sealFrame(
        keyBytes: key, keyId: 'k', plaintext: 'p', postQuantum: false);
      final f = GroupCryptoService.parseFrame(wire)!;
      final ct = base64Decode(f.ciphertextB64)..[0] ^= 1;
      final tampered = GroupFrame(
          keyId: 'k',
          ciphertextB64: base64Encode(ct),
          postQuantum: false);
      expect(
          await GroupCryptoService.openFrame(
              keyBytes: key, frame: tampered),
          isNull);
      expect(
          await GroupCryptoService.openFrame(
              keyBytes: Uint8List.fromList(List<int>.filled(32, 0)),
              frame: f),
          isNull);
    });

    test('parseFrame rejects non-group / malformed payloads', () {
      expect(GroupCryptoService.parseFrame('v2s:abc'), isNull);
      expect(GroupCryptoService.parseFrame('v2g:notB64!'), isNull);
      expect(GroupCryptoService.parseFrame('plain'), isNull);
    });

    test('VGK1 build/parse round-trip; rejects bad key length', () {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i ^ 5));
      final msg = GroupCryptoService.buildKeyMessage('grp1', 'kid9', key);
      expect(msg.startsWith('VGK1:'), isTrue);
      final d = GroupCryptoService.parseKeyMessage(msg);
      expect(d, isNotNull);
      expect(d!.groupId, 'grp1');
      expect(d.keyId, 'kid9');
      expect(base64Decode(d.keyB64), key);

      final short = GroupCryptoService.buildKeyMessage(
          'g', 'k', Uint8List(16));
      expect(GroupCryptoService.parseKeyMessage(short), isNull);
      expect(GroupCryptoService.parseKeyMessage('v2g:x'), isNull);
    });
  });
}
