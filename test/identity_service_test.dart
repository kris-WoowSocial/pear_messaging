import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/identity_announcement_service.dart';
import 'package:pear_messaging/core/services/identity_service.dart';
import 'package:pear_messaging/core/services/local_storage_service.dart';

void main() {
  final ed25519 = Ed25519();
  final x25519 = X25519();

  /// Build a valid wire bundle [version][x25519 pub][ed25519 pub].
  Future<String> makeBundle(SimpleKeyPair ed) async {
    final x = await x25519.newKeyPair();
    final xPub = (await x.extract() as SimpleKeyPairData).publicKey;
    final edData = await ed.extract() as SimpleKeyPairData;
    return base64Encode(
      Uint8List.fromList(
        [
          IdentityService.bundleVersion,
          ...xPub.bytes,
          ...edData.publicKey.bytes
        ],
      ),
    );
  }

  Uint8List payload(String domain, String deviceId,
      [List<int> material = const [], String? nonce]) {
    final b = BytesBuilder()
      ..add(utf8.encode(domain))
      ..add(utf8.encode('|'))
      ..add(utf8.encode(deviceId))
      ..add(utf8.encode('|'))
      ..add(material);
    if (nonce != null) {
      b
        ..add(utf8.encode('|'))
        ..add(utf8.encode(nonce));
    }
    return b.toBytes();
  }

  group('IdentityService.parseBundle', () {
    test('parses a valid 65-byte v1 bundle', () async {
      final ed = await ed25519.newKeyPair();
      final bundle = await makeBundle(ed as SimpleKeyPair);
      final parsed = IdentityService.parseBundle(bundle);
      expect(parsed, isNotNull);
      expect(parsed!.x25519Pub.length, 32);
      expect(parsed.ed25519Pub.length, 32);
    });

    test('rejects wrong length, version, and garbage', () {
      expect(IdentityService.parseBundle(base64Encode([1, 2, 3])), isNull);
      expect(
        IdentityService.parseBundle(base64Encode(Uint8List(65)..[0] = 99)),
        isNull,
      );
      expect(IdentityService.parseBundle('!!!not-base64!!!'), isNull);
    });
  });

  group('announcement signature verification', () {
    late IdentityService service;
    setUp(() => service = IdentityService());

    test('accepts a valid self-signed announcement', () async {
      final ed = await ed25519.newKeyPair() as SimpleKeyPair;
      final bundle = await makeBundle(ed);
      final bundleBytes = base64Decode(bundle);
      final sig = await ed25519.sign(
        payload(IdentityService.domainAnnounce, 'dev123', bundleBytes),
        keyPair: ed,
      );
      final ok = await service.verifyAnnouncement(
        senderDeviceId: 'dev123',
        bundleBase64: bundle,
        signatureBase64: base64Encode(sig.bytes),
      );
      expect(ok, isTrue);
    });

    test('rejects a signature for a different deviceId', () async {
      final ed = await ed25519.newKeyPair() as SimpleKeyPair;
      final bundle = await makeBundle(ed);
      final sig = await ed25519.sign(
        payload(
            IdentityService.domainAnnounce, 'attacker', base64Decode(bundle)),
        keyPair: ed,
      );
      final ok = await service.verifyAnnouncement(
        senderDeviceId: 'victim',
        bundleBase64: bundle,
        signatureBase64: base64Encode(sig.bytes),
      );
      expect(ok, isFalse);
    });

    test('rejects a signature under a different domain', () async {
      final ed = await ed25519.newKeyPair() as SimpleKeyPair;
      final bundle = await makeBundle(ed);
      final sig = await ed25519.sign(
        payload(IdentityService.domainBind, 'dev123', base64Decode(bundle)),
        keyPair: ed,
      );
      final ok = await service.verifyAnnouncement(
        senderDeviceId: 'dev123',
        bundleBase64: bundle,
        signatureBase64: base64Encode(sig.bytes),
      );
      expect(ok, isFalse);
    });

    test('rejects a tampered bundle', () async {
      final ed = await ed25519.newKeyPair() as SimpleKeyPair;
      final bundle = await makeBundle(ed);
      final sig = await ed25519.sign(
        payload(IdentityService.domainAnnounce, 'dev123', base64Decode(bundle)),
        keyPair: ed,
      );
      final tampered = base64Decode(bundle);
      tampered[10] ^= 0xff; // flip a bit inside the x25519 public key
      final ok = await service.verifyAnnouncement(
        senderDeviceId: 'dev123',
        bundleBase64: base64Encode(tampered),
        signatureBase64: base64Encode(sig.bytes),
      );
      expect(ok, isFalse);
    });

    test('signed capability fields verify and reject tampering', () async {
      final ed = await ed25519.newKeyPair() as SimpleKeyPair;
      final bundle = await makeBundle(ed);
      const capabilities = ['encrypted_call', 'video_call'];
      final sig = await ed25519.sign(
        payload(
          IdentityService.domainCapabilities,
          'dev123',
          IdentityService.capabilityMaterial(
            '1810000001234',
            7,
            capabilities,
          ),
        ),
        keyPair: ed,
      );
      Future<bool> verify({
        int sequence = 7,
        List<String> signedCapabilities = capabilities,
        String target = '1810000001234',
      }) =>
          service.verifyCapabilities(
            senderDeviceId: 'dev123',
            targetDeviceId: target,
            bundleBase64: bundle,
            sequence: sequence,
            capabilities: signedCapabilities,
            signatureBase64: base64Encode(sig.bytes),
          );
      expect(await verify(), isTrue);
      expect(await verify(sequence: 6), isFalse);
      expect(await verify(target: '1810000009999'), isFalse);
      expect(
        await verify(signedCapabilities: const ['encrypted_call']),
        isFalse,
      );
    });
  });

  group('recovery gating (shouldTriggerIdentityRecovery)', () {
    test('only conflict-class reasons may mint a new ID', () {
      // Permitted — user confirmation still required before minting.
      expect(IdentityService.shouldTriggerIdentityRecovery('identity_required'),
          isTrue);
      expect(IdentityService.shouldTriggerIdentityRecovery('identity_conflict'),
          isTrue);

      // Everything else leaves the device ID alone — including reasons that
      // a malicious or buggy server could use to force re-keying.
      for (final reason in [
        'missing_challenge',
        'rate_limited',
        'bad_identity_signature',
        'bad_register_signature',
        'identity_unavailable',
        'invalid_device_id',
        null,
        '',
        'conflict', // looks similar — must NOT match
      ]) {
        expect(IdentityService.shouldTriggerIdentityRecovery(reason), isFalse,
            reason: 'reason=$reason');
      }
    });
  });

  group('announcement ack status mapping', () {
    test(
        'unchanged must ack unchanged (dequeues) — regression for the '
        'infinite-retry bug', () {
      expect(
          IdentityAnnouncementService.statusForPinResult(
              LocalStorageService.pinResultUnchanged),
          'unchanged');
      expect(
          IdentityAnnouncementService.statusForPinResult(
              LocalStorageService.pinResultPinned),
          'pinned');
      expect(
          IdentityAnnouncementService.statusForPinResult(
              LocalStorageService.pinResultConflict),
          'conflict');
      // Generic rejection — no probing signal to the sender.
      for (final r in [
        LocalStorageService.pinResultNoChat,
        LocalStorageService.pinResultUnavailable,
        'anything-else',
      ]) {
        expect(IdentityAnnouncementService.statusForPinResult(r), 'rejected');
      }
    });
  });

  group('announcement ack dequeue rule', () {
    test('dequeues only for a queued target + terminal status + hash match',
        () {
      bool deq(String status, bool queued, bool hashMatch) =>
          IdentityAnnouncementService.isDequeueableAck(
              status: status, targetQueued: queued, hashMatch: hashMatch);
      expect(deq('pinned', true, true), isTrue);
      expect(deq('unchanged', true, true), isTrue);
      expect(deq('conflict', true, true), isTrue);
      // 'rejected' stays queued forever (retried with backoff).
      expect(deq('rejected', true, true), isFalse);
      // ack for a target we never announced to.
      expect(deq('pinned', false, true), isFalse);
      // stale/misattributed ack — hash doesn't match what we sent.
      expect(deq('pinned', true, false), isFalse);
      expect(deq('rejected', false, false), isFalse);
      // Unknown/typo statuses stay queued — whitelist, not blacklist.
      expect(deq('delivered', true, true), isFalse);
      expect(deq('', true, true), isFalse);
    });
  });

  group('ephemeral X25519 key agreement', () {
    test('both sides derive the same shared secret', () async {
      final service = IdentityService();
      final a = await service.generateEphemeralKeyPair();
      final b = await service.generateEphemeralKeyPair();
      final aPub = (await a.extract() as SimpleKeyPairData).publicKey.bytes;
      final bPub = (await b.extract() as SimpleKeyPairData).publicKey.bytes;
      final sA = await service.sharedSecret(
        myKeyPair: a,
        peerPublicKey: Uint8List.fromList(bPub),
      );
      final sB = await service.sharedSecret(
        myKeyPair: b,
        peerPublicKey: Uint8List.fromList(aPub),
      );
      expect(await sA.extractBytes(), await sB.extractBytes());
    });
  });
}
