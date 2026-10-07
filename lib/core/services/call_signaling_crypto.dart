import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;

import 'identity_service.dart';

/// Phase 2 — end-to-end encrypted call signaling.
///
/// Two-stage key schedule (the offer is encrypted before the callee's
/// ephemeral exists):
///
///   offerKey   = HKDF(DH(IKa,IKb) ‖ DH(EKa,IKb),
///                     salt=callId, info=infoOffer)   // caller only
///   sessionKey = HKDF(DH(IKa,IKb)‖DH(EKa,IKb)‖DH(IKa,EKb)‖DH(EKa,EKb),
///                     salt=callId, info=infoSession)
///   kAB = HKDF(sessionKey, info="vant-call A→B")   // caller→callee
///   kBA = HKDF(sessionKey, info="vant-call B→A")   // callee→caller
///
/// The callee's ephemeral is generated AT ANSWER TIME — a killed app can
/// still decrypt the offer with only its pinned identity key.
///
/// Signed fingerprints bind media to verified identities:
///   caller: sign("vant-call-fp" | callId | idA | idB | ephA | fps(offer))
///   callee: sign(... | ephB | fps(answer) | sha256(callerSig))
/// covering EVERY a=fingerprint line in canonical order, verified against
/// the exact SDP string handed to setRemoteDescription.
///
/// All framed fields are length-prefixed (4-byte BE) — concatenated
/// variable-length fields are ambiguous without them.
///
/// Private key material NEVER enters this module: DH and signing are
/// injected as operations ([dh], [sign]) so IdentityService's key pairs
/// stay inside IdentityService.
typedef DhOperation = Future<SecretKey> Function(List<int> peerX25519Pub);
typedef SignOperation = Future<Uint8List> Function(List<int> message);
typedef PeerBundleResolver = String? Function(String peerDeviceId);

class CallSignalingCryptoException implements Exception {
  final String message;
  const CallSignalingCryptoException(this.message);
  @override
  String toString() => 'CallSignalingCryptoException: $message';
}

class CallSignalingCrypto {
  CallSignalingCrypto({
    required DhOperation dh,
    required SignOperation sign,
    required String myDeviceId,
    required PeerBundleResolver resolvePeerBundle,
  })  : _dh0 = dh,
        _sign = sign,
        _myDeviceId = myDeviceId,
        _resolvePeerBundle = resolvePeerBundle;

  final DhOperation _dh0;
  final SignOperation _sign;
  final String _myDeviceId;
  final PeerBundleResolver _resolvePeerBundle;

  // HKDF info labels — shared with tests; never change these strings.
  static const String infoOffer = 'vant-call-offer';
  static const String infoSession = 'vant-call-session';
  static const String infoAB = 'vant-call A\u2192B'; // "vant-call A→B"
  static const String infoBA = 'vant-call B\u2192A'; // "vant-call B→A"

  static const String fpDomain = 'vant-call-fp';
  static const int replayWindowBits = 64;
  static const int maxCounter = 1 << 31; // hard cap — never wrap

  final _x25519 = X25519();
  final _ed25519 = Ed25519();
  final _gcm = AesGcm.with256bits();

  // Per-call state — cleared by [dispose].
  KeyPair? _ephLocal;
  Uint8List? _ephLocalPub;
  Uint8List? _ephPeerPub;
  SecretKey? _offerKey; // caller-side, pre-answer
  SecretKey? _kAB;
  SecretKey? _kBA;
  String? _callId;
  String? _peerDeviceId;
  bool _amCaller = false;

  // Per-direction counters + replay window (receivers: one per direction).
  final Map<String, int> _sendCounters = {'a2b': 0, 'b2a': 0};
  final Map<String, _ReplayWindow> _recvWindows = {
    'a2b': _ReplayWindow(),
    'b2a': _ReplayWindow(),
  };

  /// Test-only escape hatch: simulates release-mode checks inside
  /// debug-mode tests so the guard branches get real coverage.
  /// Harmless in release (the !kDebugMode path already throws first).
  @visibleForTesting
  static bool debugForceReleaseMode = false;

  bool get _guarded => kDebugMode && !debugForceReleaseMode;

  /// Test-only view of send counters (counter-cap test).
  /// Throws in release builds — a readable counter map invites misuse.
  @visibleForTesting
  Map<String, int> get sendCountersForTest {
    if (!_guarded) throw const CallSignalingCryptoException('test_only');
    return _sendCounters;
  }

  /// Test-only: extract derived key bytes for fixed-vector verification.
  /// 'offer' | 'kAB' | 'kBA'. Throws in release builds — raw key bytes
  /// must never be reachable from production code paths.
  @visibleForTesting
  Future<Uint8List> debugKeyBytes(String which) async {
    if (!_guarded) throw const CallSignalingCryptoException('test_only');
    final k = which == 'offer'
        ? _offerKey
        : which == 'kAB'
            ? _kAB
            : _kBA;
    if (k == null) {
      throw const CallSignalingCryptoException('key_not_ready');
    }
    return Uint8List.fromList(await k.extractBytes());
  }

  /// Threat model note: a compromised relay can inject 8 garbage
  /// candidates to force crypto_failed — but the relay can drop the call
  /// outright anyway, so this is DoS parity, not a new capability.
  /// UI guidance on crypto_failed: "connection security check failed" +
  /// retry — never accuse the contact of being compromised.
  ///
  /// Decrypt errors observed mid-call — a stray bad candidate shouldn't
  /// kill a good call; repeated failures end it (caller enforces).
  /// Only AUTH failures and malformed records count — replays of an
  /// already-accepted counter (Socket.IO redelivery, pre-ICE-restart
  /// stragglers) are dropped silently and never counted.
  int decryptFailures = 0;
  static const int decryptFailureThreshold = 8;

  // ---------------------------------------------------------------------------
  // Canonical byte framing — every multi-field value is length-prefixed
  // ---------------------------------------------------------------------------

  static Uint8List _frame(List<List<int>> fields) {
    final b = BytesBuilder();
    for (final f in fields) {
      final len = f.length;
      b.add([
        (len >> 24) & 0xff,
        (len >> 16) & 0xff,
        (len >> 8) & 0xff,
        len & 0xff,
      ]);
      b.add(f);
    }
    return b.toBytes();
  }

  /// Extract every `a=fingerprint:` value from SDP in canonical order
  /// (sorted). Multi-section SDP MUST present identical fingerprints across
  /// sections — differing values are a downgrade/MITM shape.
  static List<Uint8List> extractDtlsFingerprints(String sdp) {
    final fps = <String>{};
    for (final line in sdp.split(RegExp(r'\r?\n'))) {
      final l = line.trim();
      if (l.startsWith('a=fingerprint:')) {
        fps.add(l.substring('a=fingerprint:'.length).trim());
      }
    }
    if (fps.length > 1) {
      throw const CallSignalingCryptoException('sdp_fingerprint_mismatch');
    }
    return fps.map((f) => Uint8List.fromList(utf8.encode(f))).toList();
  }

  // ---------------------------------------------------------------------------
  // DH + KDF helpers
  // ---------------------------------------------------------------------------

  /// X25519 DH via the injected operation (identity keypairs stay inside
  /// IdentityService); rejects all-zero outputs (low-order points).
  Future<SecretKey> _dhWithPub(List<int> remotePub) async {
    final secret = await _dh0(remotePub);
    final bytes = await secret.extractBytes();
    if (bytes.every((b) => b == 0)) {
      throw const CallSignalingCryptoException('all_zero_dh');
    }
    return secret;
  }

  /// Ephemeral×peer DH — the ephemeral key pair is local, so it uses the
  /// library directly (it is OUR ephemeral, never leaves the object).
  Future<SecretKey> _dhEph(List<int> remotePub) async {
    final keyPair = _ephLocal;
    if (keyPair == null) {
      throw const CallSignalingCryptoException('local_ephemeral_not_ready');
    }
    final secret = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(remotePub, type: KeyPairType.x25519),
    );
    final bytes = await secret.extractBytes();
    if (bytes.every((b) => b == 0)) {
      throw const CallSignalingCryptoException('all_zero_dh');
    }
    return secret;
  }

  static Future<SecretKey> _hkdfConcat(
    List<SecretKey> parts, {
    required String salt,
    required String info,
  }) async {
    final ikm = BytesBuilder();
    for (final p in parts) {
      ikm.add(await p.extractBytes());
    }
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: SecretKey(ikm.toBytes()),
      nonce: utf8.encode(salt),
      info: utf8.encode(info),
    );
  }

  String _requireCallId() {
    final value = _callId;
    if (value == null) {
      throw const CallSignalingCryptoException('handshake_not_started');
    }
    return value;
  }

  Uint8List _requireLocalEphPub() {
    final value = _ephLocalPub;
    if (value == null) {
      throw const CallSignalingCryptoException('local_ephemeral_not_ready');
    }
    return value;
  }

  Uint8List _requirePeerEphPub() {
    final value = _ephPeerPub;
    if (value == null) {
      throw const CallSignalingCryptoException('peer_ephemeral_not_ready');
    }
    return value;
  }

  void _validateDirection(String direction) {
    if (direction != 'a2b' && direction != 'b2a') {
      throw const CallSignalingCryptoException('invalid_direction');
    }
  }

  // ---------------------------------------------------------------------------
  // Caller side
  // ---------------------------------------------------------------------------

  List<Uint8List>? _lastOfferFps;
  Uint8List? _lastCallerSig;

  /// Caller begin: generate ephA, derive offerKey, sign the offer fp.
  /// [offerDtlsFps] = canonical fingerprints extracted from the OFFER SDP —
  /// extracted by the caller from the exact string handed to WebRTC.
  Future<({Uint8List eph, Uint8List fp})> beginOffer({
    required String callId,
    required String myId,
    required String peerId,
    required String peerBundleB64,
    required List<Uint8List> offerDtlsFps,
    @visibleForTesting List<int>? ephSeed,
  }) async {
    if (ephSeed != null && !_guarded) {
      // A caller-supplied ephemeral seed would silently kill forward
      // secrecy — throw loudly in release builds, never fall back.
      throw const CallSignalingCryptoException('test_only_parameter');
    }
    if (myId != _myDeviceId) {
      throw const CallSignalingCryptoException('identity_mismatch');
    }
    _callId = callId;
    _peerDeviceId = peerId;
    _amCaller = true;
    _ephLocal = _guarded && ephSeed != null
        ? await _x25519.newKeyPairFromSeed(Uint8List.fromList(ephSeed))
        : await _x25519.newKeyPair();
    _ephLocalPub = Uint8List.fromList(
        (await _ephLocal!.extract() as SimpleKeyPairData).publicKey.bytes);

    final peer = IdentityService.parseBundle(peerBundleB64);
    if (peer == null) {
      throw const CallSignalingCryptoException('invalid_peer_bundle');
    }

    // offerKey = HKDF(DH(IKa,IKb) ‖ DH(EKa,IKb))
    final dhId = await _dhWithPub(peer.x25519Pub);
    final dhEphId = await _dhEph(peer.x25519Pub);
    _offerKey = await _hkdfConcat(
      [dhId, dhEphId],
      salt: callId,
      info: infoOffer,
    );

    _lastOfferFps = offerDtlsFps;
    final fp = await _signCallerFp(
      callId: callId,
      idA: _myDeviceId,
      idB: peerId,
      ephA: _requireLocalEphPub(),
      offerFps: offerDtlsFps,
    );
    _lastCallerSig = fp;
    return (eph: _requireLocalEphPub(), fp: fp);
  }

  /// Encrypt the offer payload (caller only, pre-answer).
  Future<Map<String, String>> encryptOffer(String sdp) {
    final key = _offerKey;
    if (key == null) {
      throw const CallSignalingCryptoException('no_offer_key');
    }
    return _encryptWith(key, 'call_initiate', 'a2b', sdp);
  }

  /// Caller completes the handshake when the callee's answer arrives:
  /// verifies the callee signature covering ephB + answer fps + caller sig,
  /// then derives session keys.
  Future<void> completeHandshake({
    required String peerId,
    required String peerBundleB64,
    required Uint8List ephB,
    required Uint8List calleeSig,
    required List<Uint8List> answerDtlsFps,
  }) async {
    final callerSig = _lastCallerSig;
    final offerFps = _lastOfferFps;
    if (callerSig == null || offerFps == null) {
      throw const CallSignalingCryptoException('no_pending_offer');
    }
    if (_peerDeviceId != peerId) {
      throw const CallSignalingCryptoException('peer_identity_mismatch');
    }
    final callId = _requireCallId();
    final ephA = _requireLocalEphPub();
    final peer = IdentityService.parseBundle(peerBundleB64);
    if (peer == null) {
      throw const CallSignalingCryptoException('invalid_peer_bundle');
    }

    final ok = await _verifyCalleeFp(
      callId: callId,
      idA: _myDeviceId,
      idB: peerId,
      ephA: ephA,
      ephB: ephB,
      offerFps: offerFps,
      answerFps: answerDtlsFps,
      callerSig: callerSig,
      calleeSig: calleeSig,
      peerEd25519Pub: peer.ed25519Pub, // pinned key — NOT the message's key
    );
    if (!ok) throw const CallSignalingCryptoException('crypto_failed');

    _ephPeerPub = ephB;
    await _deriveSessionKeys(peer.x25519Pub);
  }

  // ---------------------------------------------------------------------------
  // Callee side
  // ---------------------------------------------------------------------------

  /// Callee: decrypt an inbound offer using offerKey (identity keys + ephA
  /// only — no callee ephemeral needed, so cold-start answers work).
  Future<String> decryptOffer({
    required String callId,
    required String callerId,
    required Uint8List ephA,
    required Map<String, String> encrypted,
  }) async {
    final dhId = await _dhWithPub(_peerX25519FromPin(callerId));
    final dhIdEph = await _dhWithPub(ephA);
    final offerKey = await _hkdfConcat(
      [dhId, dhIdEph],
      salt: callId,
      info: infoOffer,
    );
    final plaintext = await _decryptWith(
      offerKey,
      'call_initiate',
      'a2b',
      _recvWindows['a2b']!,
      encrypted,
      callId: callId,
    );
    _callId = callId;
    _peerDeviceId = callerId;
    _amCaller = false;
    _ephPeerPub = Uint8List.fromList(ephA);
    return plaintext;
  }

  /// Callee at ANSWER time: generate ephB, derive session keys, sign fp.
  /// [offerDtlsFps]/[answerDtlsFps] come from the EXACT SDP strings handed
  /// to setRemoteDescription.
  Future<({Uint8List eph, Uint8List fp})> beginAnswer({
    required String peerId,
    required String peerBundleB64,
    required Uint8List callerSig,
    required List<Uint8List> offerDtlsFps,
    required List<Uint8List> answerDtlsFps,
    @visibleForTesting List<int>? ephSeed,
  }) async {
    if (ephSeed != null && !_guarded) {
      throw const CallSignalingCryptoException('test_only_parameter');
    }
    final callId = _requireCallId();
    final ephA = _requirePeerEphPub();
    if (_peerDeviceId != peerId) {
      throw const CallSignalingCryptoException('peer_identity_mismatch');
    }
    _ephLocal = _guarded && ephSeed != null
        ? await _x25519.newKeyPairFromSeed(Uint8List.fromList(ephSeed))
        : await _x25519.newKeyPair();
    _ephLocalPub = Uint8List.fromList(
        (await _ephLocal!.extract() as SimpleKeyPairData).publicKey.bytes);
    final peer = IdentityService.parseBundle(peerBundleB64);
    if (peer == null) {
      throw const CallSignalingCryptoException('invalid_peer_bundle');
    }

    final fp = await _signCalleeFp(
      callId: callId,
      idA: peerId, // caller
      idB: _myDeviceId,
      ephA: ephA,
      ephB: _requireLocalEphPub(),
      offerFps: offerDtlsFps,
      answerFps: answerDtlsFps,
      callerSig: callerSig,
    );
    await _deriveSessionKeys(peer.x25519Pub);
    return (eph: _requireLocalEphPub(), fp: fp);
  }

  /// Derive session keys in FIXED role order so both sides compute
  /// identical bytes:
  ///   DH1 = DH(IKa, IKb)  DH2 = DH(EKa, IKb)
  ///   DH3 = DH(IKa, EKb)  DH4 = DH(EKa, EKb)
  Future<void> _deriveSessionKeys(List<int> peerX25519Pub) async {
    final peerEph = _requirePeerEphPub();
    final callId = _requireCallId();

    final SecretKey dh1, dh2, dh3, dh4;
    if (_amCaller) {
      dh1 = await _dhWithPub(peerX25519Pub); // IKa × IKb
      dh2 = await _dhEph(peerX25519Pub); // EKa × IKb
      dh3 = await _dhWithPub(peerEph); // IKa × EKb
      dh4 = await _dhEph(peerEph); // EKa × EKb
    } else {
      dh1 = await _dhWithPub(peerX25519Pub); // IKb × IKa
      dh2 = await _dhWithPub(peerEph); // IKb × EKa
      dh3 = await _dhEph(peerX25519Pub); // EKb × IKa
      dh4 = await _dhEph(peerEph); // EKb × EKa
    }
    final session = await _hkdfConcat(
      [dh1, dh2, dh3, dh4],
      salt: callId,
      info: infoSession,
    );
    _kAB = await _hkdfConcat([session], salt: callId, info: infoAB);
    _kBA = await _hkdfConcat([session], salt: callId, info: infoBA);
  }

  // ---------------------------------------------------------------------------
  // AEAD — AES-256-GCM, random 12B nonce, length-prefixed AAD
  // ---------------------------------------------------------------------------

  /// AAD binds each ciphertext to call + direction + event + counter.
  /// Fixed format: each field length-prefixed so no ambiguity.
  Uint8List _aad(String event, String direction, int counter,
      {String? callId}) {
    return _frame([
      utf8.encode(callId ?? _requireCallId()),
      utf8.encode(direction),
      utf8.encode(event),
      Uint8List(4)
        ..[0] = (counter >> 24) & 0xff
        ..[1] = (counter >> 16) & 0xff
        ..[2] = (counter >> 8) & 0xff
        ..[3] = counter & 0xff,
    ]);
  }

  Future<Map<String, String>> encryptMessage({
    required String direction, // 'a2b' | 'b2a'
    required String event,
    required String plaintext,
  }) {
    _validateDirection(direction);
    final key = direction == 'a2b' ? _kAB : _kBA;
    if (key == null) {
      throw const CallSignalingCryptoException('session_keys_not_ready');
    }
    return _encryptWith(key, event, direction, plaintext);
  }

  Future<Map<String, String>> _encryptWith(
      SecretKey key, String event, String direction, String plaintext) async {
    final counter = _sendCounters[direction]!;
    if (counter >= maxCounter) {
      throw const CallSignalingCryptoException('counter_exhausted');
    }
    _sendCounters[direction] = counter + 1;
    final nonce = _randomNonce();
    final box = await _gcm.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
      aad: _aad(event, direction, counter),
    );
    return {
      'n': base64Encode(nonce),
      'c': base64Encode(box.cipherText + box.mac.bytes),
      'k': counter.toString(),
    };
  }

  Future<String> decryptMessage({
    required String direction,
    required String event,
    required Map<String, String> encrypted,
  }) async {
    _validateDirection(direction);
    if (_failed) {
      throw const CallSignalingCryptoException('crypto_failed');
    }
    final key = direction == 'a2b' ? _kAB : _kBA;
    if (key == null) {
      throw const CallSignalingCryptoException('session_keys_not_ready');
    }
    try {
      return await _decryptWith(
          key, event, direction, _recvWindows[direction]!, encrypted);
    } on CallSignalingCryptoException catch (e) {
      if (e.message == 'malformed_record' ||
          e.message == 'counter_out_of_range') {
        decryptFailures++;
        if (decryptFailures >= decryptFailureThreshold) {
          _failed = true;
          throw const CallSignalingCryptoException('crypto_failed');
        }
      }
      rethrow;
    } on SecretBoxAuthenticationError {
      decryptFailures++;
      if (decryptFailures >= decryptFailureThreshold) {
        _failed = true;
        throw const CallSignalingCryptoException('crypto_failed');
      }
      rethrow;
    } on RangeError {
      // Malformed record (too short for GCM tag) — counts as a failed
      // candidate, same threshold.
      decryptFailures++;
      if (decryptFailures >= decryptFailureThreshold) {
        _failed = true;
        throw const CallSignalingCryptoException('crypto_failed');
      }
      throw const CallSignalingCryptoException('malformed_record');
    }
  }

  bool _failed = false; // sticky crypto_failed — nothing more decrypts

  /// Order matters: AUTHENTICATE first, then update the replay window —
  /// otherwise a forged record could poison the window.
  Future<String> _decryptWith(
    SecretKey key,
    String event,
    String direction,
    _ReplayWindow window,
    Map<String, String> encrypted, {
    String? callId,
  }) async {
    // Validate every wire field BEFORE parsing — these bytes are
    // attacker-controlled. No '!' on untrusted input.
    final nB64 = encrypted['n'];
    final cB64 = encrypted['c'];
    final kStr = encrypted['k'];
    if (nB64 == null || cB64 == null || kStr == null) {
      throw const CallSignalingCryptoException('malformed_record');
    }
    final Uint8List n, c;
    final int counter;
    try {
      n = base64Decode(nB64);
      c = base64Decode(cB64);
      counter = int.parse(kStr);
    } catch (_) {
      throw const CallSignalingCryptoException('malformed_record');
    }
    if (n.length != 12 || c.length < 17 || c.length > 1 << 16) {
      throw const CallSignalingCryptoException('malformed_record');
    }
    if (counter < 0 || counter > maxCounter) {
      throw const CallSignalingCryptoException('counter_out_of_range');
    }
    final clear = await _gcm.decrypt(
      SecretBox(c.sublist(0, c.length - 16),
          nonce: n, mac: Mac(c.sublist(c.length - 16))),
      secretKey: key,
      aad: _aad(event, direction, counter, callId: callId),
    );
    window.accept(counter); // throws only on replay AFTER auth succeeded
    return utf8.decode(clear);
  }

  // ---------------------------------------------------------------------------
  // Fingerprint signatures — public values only, length-prefixed
  // ---------------------------------------------------------------------------

  Future<Uint8List> _signCallerFp({
    required String callId,
    required String idA,
    required String idB,
    required Uint8List ephA,
    required List<Uint8List> offerFps,
  }) async {
    final material = _frame([
      utf8.encode(fpDomain),
      utf8.encode(callId),
      utf8.encode(idA),
      utf8.encode(idB),
      ephA,
      ...offerFps,
    ]);
    return _sign(material);
  }

  Future<Uint8List> _signCalleeFp({
    required String callId,
    required String idA,
    required String idB,
    required Uint8List ephA,
    required Uint8List ephB,
    required List<Uint8List> offerFps,
    required List<Uint8List> answerFps,
    required Uint8List callerSig,
  }) async {
    final callerSigHash = await Sha256().hash(callerSig);
    final material = _frame([
      utf8.encode(fpDomain),
      utf8.encode(callId),
      utf8.encode(idA),
      utf8.encode(idB),
      ephA,
      ephB,
      ...offerFps,
      ...answerFps,
      Uint8List.fromList(callerSigHash.bytes),
    ]);
    return _sign(material);
  }

  Future<bool> _verifyCalleeFp({
    required String callId,
    required String idA,
    required String idB,
    required Uint8List ephA,
    required Uint8List ephB,
    required List<Uint8List> offerFps,
    required List<Uint8List> answerFps,
    required Uint8List callerSig,
    required Uint8List calleeSig,
    required List<int> peerEd25519Pub,
  }) async {
    final callerSigHash = await Sha256().hash(callerSig);
    final material = _frame([
      utf8.encode(fpDomain),
      utf8.encode(callId),
      utf8.encode(idA),
      utf8.encode(idB),
      ephA,
      ephB,
      ...offerFps,
      ...answerFps,
      Uint8List.fromList(callerSigHash.bytes),
    ]);
    return _ed25519.verify(
      material,
      signature: Signature(
        calleeSig,
        publicKey: SimplePublicKey(peerEd25519Pub, type: KeyPairType.ed25519),
      ),
    );
  }

  /// Verify the caller's signature (callee side) — binds ephA and the
  /// offer fingerprints to the PINNED Ed25519 key, never a message-supplied
  /// key.
  Future<bool> verifyCallerFp({
    required String callId,
    required String idA,
    required String idB,
    required Uint8List ephA,
    required List<Uint8List> offerFps,
    required Uint8List callerSig,
    required List<int> callerEd25519Pub,
  }) async {
    final material = _frame([
      utf8.encode(fpDomain),
      utf8.encode(callId),
      utf8.encode(idA),
      utf8.encode(idB),
      ephA,
      ...offerFps,
    ]);
    return _ed25519.verify(
      material,
      signature: Signature(
        callerSig,
        publicKey: SimplePublicKey(callerEd25519Pub, type: KeyPairType.ed25519),
      ),
    );
  }

  List<int> _peerX25519FromPin(String peerId) {
    final pin = _resolvePeerBundle(peerId);
    final parsed = pin != null ? IdentityService.parseBundle(pin) : null;
    if (parsed == null) {
      throw const CallSignalingCryptoException('no_pinned_peer_bundle');
    }
    return parsed.x25519Pub;
  }

  Uint8List _randomNonce() {
    final r = SecureRandom.fast;
    return Uint8List.fromList(List.generate(12, (_) => r.nextInt(256)));
  }

  /// Clear key state at call end (hygiene — Dart's GC gives no wiping
  /// guarantee; this reduces exposure windows, not memory forensics).
  void dispose() {
    _offerKey = null;
    _kAB = null;
    _kBA = null;
    _ephLocal = null;
    _ephLocalPub = null;
    _ephPeerPub = null;
    _callId = null;
    _peerDeviceId = null;
    _amCaller = false;
    _failed = false;
    _sendCounters['a2b'] = 0;
    _sendCounters['b2a'] = 0;
    _recvWindows['a2b'] = _ReplayWindow();
    _recvWindows['b2a'] = _ReplayWindow();
    decryptFailures = 0;
    _lastOfferFps = null;
    _lastCallerSig = null;
  }
}

/// Sliding 64-bit replay window. [accept] throws on replay; called only
/// after successful AEAD authentication.
class _ReplayWindow {
  int maxCounter = -1;
  int window = 0;

  void accept(int counter) {
    if (counter < 0) {
      throw const CallSignalingCryptoException('counter_out_of_range');
    }
    if (counter <= maxCounter - CallSignalingCrypto.replayWindowBits) {
      throw const CallSignalingCryptoException('replayed');
    }
    if (counter <= maxCounter) {
      final shift = maxCounter - counter;
      if ((window >> shift) & 1 == 1) {
        throw const CallSignalingCryptoException('replayed');
      }
      window |= (1 << shift);
    } else {
      final shift = counter - maxCounter;
      window = (window << shift) | 1;
      maxCounter = counter;
    }
  }
}
