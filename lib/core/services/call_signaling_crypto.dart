import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

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
/// Signed fingerprints bind the media to the verified identities:
///   caller: sign("vant-call-fp" | callId | idA | idB | ephA | fps(offer))
///   callee: sign(... | ephB | fps(answer) | sha256(callerSig))
/// covering EVERY a=fingerprint line in canonical order, verified against
/// the exact SDP string handed to setRemoteDescription.
///
/// All message fields are length-prefixed (4-byte BE) — concatenated
/// variable-length fields are ambiguous without them.
typedef PeerBundleResolver = String? Function(String peerDeviceId);

class CallSignalingCrypto {
  /// Constructor-injected so the module is testable without GetX or Hive.
  /// [identity] supplies our private key pairs (never serialized out);
  /// [myDeviceId] is our bound device id; [resolvePeerBundle] returns the
  /// pinned bundle for a peer (or null when unpinned).
  CallSignalingCrypto({
    required IdentityService identity,
    required String myDeviceId,
    required PeerBundleResolver resolvePeerBundle,
  })  : _identity = identity,
        _myDeviceId = myDeviceId,
        _resolvePeerBundle = resolvePeerBundle;

  final IdentityService _identity;
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
  bool _amCaller = false;

  // Per-direction counters + replay windows.
  int _sendCounter = 0;
  int _recvMaxCounter = -1;
  int _recvWindow = 0; // bitmap of the last 64 counters

  /// Decrypt errors observed mid-call — a stray bad candidate shouldn't
  /// kill a good call; repeated failures end it (caller enforces threshold).
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
    final fps = <String>[];
    for (final line in sdp.split(RegExp(r'\r?\n'))) {
      final l = line.trim();
      if (l.startsWith('a=fingerprint:')) {
        fps.add(l.substring('a=fingerprint:'.length).trim());
      }
    }
    final unique = fps.toSet().toList()..sort();
    if (unique.length > 1) {
      // Differing fingerprints across media sections — refuse to canonicalize.
      throw const FormatException('SDP fingerprints differ across sections');
    }
    return unique.map((f) => Uint8List.fromList(utf8.encode(f))).toList();
  }

  // ---------------------------------------------------------------------------
  // DH + KDF helpers
  // ---------------------------------------------------------------------------

  Future<SecretKey> _dh(KeyPair local, List<int> remotePub) async {
    final secret = await _x25519.sharedSecretKey(
      keyPair: local,
      remotePublicKey: SimplePublicKey(remotePub, type: KeyPairType.x25519),
    );
    final bytes = await secret.extractBytes();
    // Reject all-zero DH output (low-order point / failed agreement).
    if (bytes.every((b) => b == 0)) {
      throw const FormatException('all-zero DH output rejected');
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

  // ---------------------------------------------------------------------------
  // Caller side
  // ---------------------------------------------------------------------------

  /// Caller begin: generate ephA, derive offerKey, sign the offer fp.
  /// Returns fields for call_initiate: eph, fp (caller signature).
  /// [dtlsFps] = canonical fingerprints extracted from the OFFER SDP.
  Future<({Uint8List eph, Uint8List fp})> beginOffer({
    required String callId,
    required String myId,
    required String peerId,
    required String peerBundleB64,
    required List<Uint8List> offerDtlsFps,
  }) async {
    _callId = callId;
    _amCaller = true;
    _ephLocal = await _x25519.newKeyPair();
    _ephLocalPub = Uint8List.fromList(
        (await _ephLocal!.extract() as SimpleKeyPairData).publicKey.bytes);

    final peer = IdentityService.parseBundle(peerBundleB64);
    if (peer == null) throw const FormatException('invalid peer bundle');

    // offerKey = HKDF(DH(IKa,IKb) ‖ DH(EKa,IKb))
    final myX25519 = _identity.internalX25519KeyPair!;
    final dhId = await _dh(myX25519, peer.x25519Pub);
    final dhEphId = await _dh(_ephLocal!, peer.x25519Pub);
    _offerKey = await _hkdfConcat(
      [dhId, dhEphId],
      salt: callId,
      info: infoOffer,
    );

    final fp = await _signCallerFp(
      callId: callId,
      idA: myId,
      idB: peerId,
      ephA: _ephLocalPub!,
      offerFps: offerDtlsFps,
    );
    return (eph: _ephLocalPub!, fp: fp);
  }

  /// Encrypt the offer payload (caller only, pre-answer).
  Future<Map<String, String>> encryptOffer(String sdp) =>
      _encryptWith(_offerKey!, 'call_initiate', 'a2b', sdp);

  /// Caller completes the handshake when the callee's answer arrives:
  /// verifies the callee signature covering ephB + answer fps + caller sig,
  /// then derives session keys.
  Future<void> completeHandshake({
    required String peerId,
    required String peerBundleB64,
    required Uint8List ephB,
    required Uint8List callerSig, // the fp we sent
    required Uint8List calleeSig,
    required List<Uint8List> answerDtlsFps,
  }) async {
    final peer = IdentityService.parseBundle(peerBundleB64);
    if (peer == null) throw const FormatException('invalid peer bundle');

    final ok = await _verifyCalleeFp(
      callId: _callId!,
      idA: _storageDeviceId(),
      idB: peerId,
      ephA: _ephLocalPub!,
      ephB: ephB,
      offerFps: _lastOfferFps,
      answerFps: answerDtlsFps,
      callerSig: callerSig,
      calleeSig: calleeSig,
      peerEd25519Pub: peer.ed25519Pub,
    );
    if (!ok) throw const CallSignalingCryptoException('crypto_failed');

    await _deriveSessionKeys(peer.x25519Pub, ephB);
  }

  // ---------------------------------------------------------------------------
  // Callee side
  // ---------------------------------------------------------------------------

  /// Callee: decrypt an inbound offer using offerKey (identity keys + ephA
  /// only — no callee ephemeral needed, so cold-start answers work).
  Future<String> decryptOffer({
    required String callId,
    required String myId,
    required String callerId,
    required Uint8List ephA,
    required Map<String, String> encrypted,
  }) async {
    _callId = callId;
    _amCaller = false;
    _ephPeerPub = ephA;
    final myX25519 = _identity.internalX25519KeyPair!;
    final dhId = await _dh(myX25519, _peerX25519FromPin(callerId));
    final dhIdEph = await _dh(myX25519, ephA);
    final offerKey = await _hkdfConcat(
      [dhId, dhIdEph],
      salt: callId,
      info: infoOffer,
    );
    return _decryptWith(offerKey, 'call_initiate', 'a2b', encrypted);
  }

  /// Callee at ANSWER time: generate ephB, derive session keys, sign fp.
  Future<({Uint8List eph, Uint8List fp})> beginAnswer({
    required String peerId,
    required String peerBundleB64,
    required Uint8List callerSig,
    required List<Uint8List> offerDtlsFps,
    required List<Uint8List> answerDtlsFps,
  }) async {
    _ephLocal = await _x25519.newKeyPair();
    _ephLocalPub = Uint8List.fromList(
        (await _ephLocal!.extract() as SimpleKeyPairData).publicKey.bytes);
    final peer = IdentityService.parseBundle(peerBundleB64)!;

    final fp = await _signCalleeFp(
      callId: _callId!,
      idA: peerId, // caller
      idB: _storageDeviceId(),
      ephA: _ephPeerPub!,
      ephB: _ephLocalPub!,
      offerFps: offerDtlsFps,
      answerFps: answerDtlsFps,
      callerSig: callerSig,
    );
    await _deriveSessionKeys(peer.x25519Pub, null);
    return (eph: _ephLocalPub!, fp: fp);
  }

  /// Derive session keys in FIXED role order so both sides compute
  /// identical bytes:
  ///   DH1 = DH(IKa, IKb)  DH2 = DH(EKa, IKb)
  ///   DH3 = DH(IKa, EKb)  DH4 = DH(EKa, EKb)
  /// [_amCaller] is set by beginOffer/decryptOffer.
  Future<void> _deriveSessionKeys(
      List<int> peerX25519Pub, Uint8List? ephB) async {
    final myX = _identity.internalX25519KeyPair!;
    final peerEph = ephB ?? _ephPeerPub!;

    final SecretKey dh1, dh2, dh3, dh4;
    if (_amCaller) {
      dh1 = await _dh(myX, peerX25519Pub);       // IKa × IKb
      dh2 = await _dh(_ephLocal!, peerX25519Pub); // EKa × IKb
      dh3 = await _dh(myX, peerEph);             // IKa × EKb
      dh4 = await _dh(_ephLocal!, peerEph);      // EKa × EKb
    } else {
      dh1 = await _dh(myX, peerX25519Pub);       // IKb × IKa
      dh2 = await _dh(myX, peerEph);             // IKb × EKa
      dh3 = await _dh(_ephLocal!, peerX25519Pub); // EKb × IKa
      dh4 = await _dh(_ephLocal!, peerEph);      // EKb × EKa
    }
    final session = await _hkdfConcat(
      [dh1, dh2, dh3, dh4],
      salt: _callId!,
      info: infoSession,
    );
    _kAB = await _hkdfConcat([session], salt: _callId!, info: infoAB);
    _kBA = await _hkdfConcat([session], salt: _callId!, info: infoBA);
  }

  // ---------------------------------------------------------------------------
  // AEAD — AES-256-GCM, random 12B nonce, length-prefixed AAD
  // ---------------------------------------------------------------------------

  /// AAD binds each ciphertext to call + direction + event + counter.
  /// Fixed format: each field length-prefixed so no ambiguity.
  Uint8List _aad(String event, String direction, int counter) {
    return _frame([
      utf8.encode(_callId!),
      utf8.encode(direction),
      utf8.encode(event),
      [
        (counter >> 24) & 0xff,
        (counter >> 16) & 0xff,
        (counter >> 8) & 0xff,
        counter & 0xff,
      ],
    ]);
  }

  Future<Map<String, String>> encryptMessage({
    required String direction, // 'a2b' | 'b2a'
    required String event,
    required String plaintext,
  }) {
    final key = direction == 'a2b' ? _kAB : _kBA;
    if (key == null) {
      throw const CallSignalingCryptoException('session keys not ready');
    }
    return _encryptWith(key, event, direction, plaintext);
  }

  Future<Map<String, String>> _encryptWith(
      SecretKey key, String event, String direction, String plaintext) async {
    if (_sendCounter >= maxCounter) {
      throw const CallSignalingCryptoException('counter exhausted');
    }
    final counter = _sendCounter++;
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
    final key = direction == 'a2b' ? _kAB : _kBA;
    if (key == null) {
      throw const CallSignalingCryptoException('session keys not ready');
    }
    try {
      return await _decryptWith(key, event, direction, encrypted);
    } on SecretBoxAuthenticationError {
      decryptFailures++;
      if (decryptFailures >= decryptFailureThreshold) {
        throw const CallSignalingCryptoException('crypto_failed');
      }
      rethrow;
    }
  }

  Future<String> _decryptWith(
    SecretKey key,
    String event,
    String direction,
    Map<String, String> encrypted,
  ) async {
    final n = base64Decode(encrypted['n']!);
    final c = base64Decode(encrypted['c']!);
    final counter = int.parse(encrypted['k']!);
    _checkReplay(counter);
    final clear = await _gcm.decrypt(
      SecretBox(c.sublist(0, c.length - 16),
          nonce: n, mac: Mac(c.sublist(c.length - 16))),
      secretKey: key,
      aad: _aad(event, direction, counter),
    );
    return utf8.decode(clear);
  }

  /// Sliding 64-bit replay window over the receive counter.
  void _checkReplay(int counter) {
    if (counter < 0 || counter > maxCounter) {
      throw const CallSignalingCryptoException('counter out of range');
    }
    if (counter <= _recvMaxCounter - replayWindowBits) {
      throw const CallSignalingCryptoException('replayed message');
    }
    if (counter <= _recvMaxCounter) {
      final shift = _recvMaxCounter - counter;
      if ((_recvWindow >> shift) & 1 == 1) {
        throw const CallSignalingCryptoException('replayed message');
      }
      _recvWindow |= (1 << shift);
    } else {
      final shift = counter - _recvMaxCounter;
      _recvWindow = (_recvWindow << shift) | 1;
      _recvMaxCounter = counter;
    }
  }

  // ---------------------------------------------------------------------------
  // Fingerprint signatures — public values only, length-prefixed
  // ---------------------------------------------------------------------------

  List<Uint8List>? _lastOfferFps;
  String _storageDeviceId() => _myDeviceId;

  Future<Uint8List> _signCallerFp({
    required String callId,
    required String idA,
    required String idB,
    required Uint8List ephA,
    required List<Uint8List> offerFps,
  }) async {
    _lastOfferFps = offerFps;
    final material = _frame([
      utf8.encode(fpDomain),
      utf8.encode(callId),
      utf8.encode(idA),
      utf8.encode(idB),
      ephA,
      ...offerFps,
    ]);
    final sig = await _ed25519.sign(
      material,
      keyPair: _identity.internalEd25519KeyPair!,
    );
    return Uint8List.fromList(sig.bytes);
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
    final callerSigHash =
        await Sha256().hash(callerSig);
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
    final sig = await _ed25519.sign(
      material,
      keyPair: _identity.internalEd25519KeyPair!,
    );
    return Uint8List.fromList(sig.bytes);
  }

  Future<bool> _verifyCalleeFp({
    required String callId,
    required String idA,
    required String idB,
    required Uint8List ephA,
    required Uint8List ephB,
    required List<Uint8List>? offerFps,
    required List<Uint8List> answerFps,
    required Uint8List callerSig,
    required Uint8List calleeSig,
    required List<int> peerEd25519Pub,
  }) async {
    if (offerFps == null) return false;
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

  /// Verify the caller's signature (callee side) — binds ephA and the offer
  /// fingerprint to the pinned Ed25519 key.
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
        publicKey:
            SimplePublicKey(callerEd25519Pub, type: KeyPairType.ed25519),
      ),
    );
  }

  List<int> _peerX25519FromPin(String peerId) {
    final pin = _resolvePeerBundle(peerId);
    final parsed = pin != null ? IdentityService.parseBundle(pin) : null;
    if (parsed == null) {
      throw const CallSignalingCryptoException('no pinned peer bundle');
    }
    return parsed.x25519Pub;
  }

  Uint8List _randomNonce() {
    final r = SecureRandom.fast;
    return Uint8List.fromList(List.generate(12, (_) => r.nextInt(256)));
  }

  /// Zero key state at call end.
  void dispose() {
    _offerKey = null;
    _kAB = null;
    _kBA = null;
    _ephLocal = null;
    _ephLocalPub = null;
    _ephPeerPub = null;
    _callId = null;
    _sendCounter = 0;
    _recvMaxCounter = -1;
    _recvWindow = 0;
    decryptFailures = 0;
    _lastOfferFps = null;
  }
}

class CallSignalingCryptoException implements Exception {
  final String message;
  const CallSignalingCryptoException(this.message);
  @override
  String toString() => 'CallSignalingCryptoException: $message';
}
