import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;

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
///   caller: sign(callerFpDomain | callId | idA | idB | ephA |
///                offerFpsCount | offerFps)
///   callee: sign(calleeFpDomain | callId | idA | idB | ephA | ephB |
///                offerFpsCount | offerFps | answerFpsCount | answerFps |
///                sha256(callerSig))
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
typedef SignOperation = Future<Uint8List> Function(
    String domain, List<int> message);
typedef PeerBundleResolver = String? Function(String peerDeviceId);
typedef ParsedIdentityBundle = ({
  Uint8List x25519Pub,
  Uint8List ed25519Pub,
});

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

  static const String callerFpDomain =
      IdentityService.domainCallFingerprintCaller;
  static const String calleeFpDomain =
      IdentityService.domainCallFingerprintCallee;
  // Keep <= 63: Dart shifts are masked to 6 bits on 64-bit ints.
  static const int replayWindowBits = 63;
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
  ParsedIdentityBundle? _peerBundle;
  bool _amCaller = false;
  bool _answerStarted = false;
  bool _completingHandshake = false;
  bool _handshakeComplete = false;
  String? _inboundOfferRecord;
  Future<String>? _inboundOffer;
  String? _lastInboundOfferRecord;
  String? _lastInboundOfferPlaintext;

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

  static Uint8List _u32(int value) => Uint8List(4)
    ..[0] = (value >> 24) & 0xff
    ..[1] = (value >> 16) & 0xff
    ..[2] = (value >> 8) & 0xff
    ..[3] = value & 0xff;

  /// Extract every `a=fingerprint:` value from SDP in canonical order
  /// (sorted). Multi-section SDP MUST present identical fingerprints across
  /// sections — differing values are a downgrade/MITM shape.
  static List<Uint8List> extractDtlsFingerprints(String sdp) {
    final fps = <String>{};
    for (final line in sdp.split(RegExp(r'\r?\n'))) {
      final l = line.trim();
      if (l.startsWith('a=fingerprint:')) {
        final raw = l.substring('a=fingerprint:'.length).trim();
        final match =
            RegExp(r'^([A-Za-z0-9-]+)\s+([0-9A-Fa-f:]+)$').firstMatch(raw);
        if (match == null) {
          throw const CallSignalingCryptoException('invalid_dtls_fingerprint');
        }
        fps.add(
            '${match.group(1)!.toLowerCase()} ${match.group(2)!.toUpperCase()}');
      }
    }
    if (fps.isEmpty) {
      throw const CallSignalingCryptoException('sdp_no_dtls_fingerprint');
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

  void _requireIdleHandshake() {
    if (_callId != null) {
      throw const CallSignalingCryptoException('active_handshake');
    }
  }

  String _offerRecordId({
    required String callId,
    required String callerId,
    required Uint8List ephA,
    required Map<String, String> encrypted,
  }) {
    return base64Encode(_frame([
      utf8.encode(callId),
      utf8.encode(callerId),
      ephA,
      utf8.encode(encrypted['n'] ?? ''),
      utf8.encode(encrypted['c'] ?? ''),
      utf8.encode(encrypted['k'] ?? ''),
    ]));
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
    required List<Uint8List> offerDtlsFps,
    @visibleForTesting List<int>? ephSeed,
  }) =>
      _beginOffer(
        callId: callId,
        myId: myId,
        peerId: peerId,
        resolvePeer: () => _peerBundleFromPin(peerId),
        offerDtlsFps: offerDtlsFps,
        ephSeed: ephSeed,
      );

  Future<({Uint8List eph, Uint8List fp})> beginOfferFirstContact({
    required String callId,
    required String myId,
    required String peerId,
    required String peerBundleB64,
    required List<Uint8List> offerDtlsFps,
    @visibleForTesting List<int>? ephSeed,
  }) =>
      _beginOffer(
        callId: callId,
        myId: myId,
        peerId: peerId,
        resolvePeer: () => _firstContactBundle(peerId, peerBundleB64),
        offerDtlsFps: offerDtlsFps,
        ephSeed: ephSeed,
      );

  Future<({Uint8List eph, Uint8List fp})> _beginOffer({
    required String callId,
    required String myId,
    required String peerId,
    required ParsedIdentityBundle Function() resolvePeer,
    required List<Uint8List> offerDtlsFps,
    List<int>? ephSeed,
  }) async {
    _requireIdleHandshake();
    if (ephSeed != null && !_guarded) {
      // A caller-supplied ephemeral seed would silently kill forward
      // secrecy — throw loudly in release builds, never fall back.
      throw const CallSignalingCryptoException('test_only_parameter');
    }
    if (myId != _myDeviceId) {
      throw const CallSignalingCryptoException('identity_mismatch');
    }
    final peer = resolvePeer();
    _callId = callId;
    _peerDeviceId = peerId;
    _amCaller = true;
    try {
      _ephLocal = _guarded && ephSeed != null
          ? await _x25519.newKeyPairFromSeed(Uint8List.fromList(ephSeed))
          : await _x25519.newKeyPair();
      _ephLocalPub = Uint8List.fromList(
          (await _ephLocal!.extract() as SimpleKeyPairData).publicKey.bytes);

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
      _peerBundle = peer;
      return (eph: _requireLocalEphPub(), fp: fp);
    } catch (_) {
      _callId = null;
      _peerDeviceId = null;
      _peerBundle = null;
      _amCaller = false;
      _ephLocal = null;
      _ephLocalPub = null;
      _offerKey = null;
      _lastOfferFps = null;
      _lastCallerSig = null;
      rethrow;
    }
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
    required Uint8List ephB,
    required Uint8List calleeSig,
    required List<Uint8List> answerDtlsFps,
  }) =>
      _completeHandshake(
        peerId: peerId,
        resolvePeer: () => _peerBundleFromPin(peerId),
        ephB: ephB,
        calleeSig: calleeSig,
        answerDtlsFps: answerDtlsFps,
      );

  Future<void> completeHandshakeFirstContact({
    required String peerId,
    required String peerBundleB64,
    required Uint8List ephB,
    required Uint8List calleeSig,
    required List<Uint8List> answerDtlsFps,
  }) =>
      _completeHandshake(
        peerId: peerId,
        resolvePeer: () => _firstContactBundle(peerId, peerBundleB64),
        ephB: ephB,
        calleeSig: calleeSig,
        answerDtlsFps: answerDtlsFps,
      );

  Future<void> _completeHandshake({
    required String peerId,
    required ParsedIdentityBundle Function() resolvePeer,
    required Uint8List ephB,
    required Uint8List calleeSig,
    required List<Uint8List> answerDtlsFps,
  }) async {
    if (_handshakeComplete || _completingHandshake) {
      throw const CallSignalingCryptoException('active_handshake');
    }
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
    final peer = resolvePeer();

    _completingHandshake = true;
    try {
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
      _peerBundle = peer;
      _handshakeComplete = true;
    } finally {
      _completingHandshake = false;
    }
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
  }) =>
      _decryptOffer(
        callId: callId,
        callerId: callerId,
        resolveCaller: () => _peerBundleFromPin(callerId),
        ephA: ephA,
        encrypted: encrypted,
      );

  Future<String> decryptOfferFirstContact({
    required String callId,
    required String callerId,
    required String callerBundleB64,
    required Uint8List ephA,
    required Map<String, String> encrypted,
  }) =>
      _decryptOffer(
        callId: callId,
        callerId: callerId,
        resolveCaller: () => _firstContactBundle(callerId, callerBundleB64),
        ephA: ephA,
        encrypted: encrypted,
      );

  Future<String> _decryptOffer({
    required String callId,
    required String callerId,
    required ParsedIdentityBundle Function() resolveCaller,
    required Uint8List ephA,
    required Map<String, String> encrypted,
  }) async {
    final recordId = _offerRecordId(
      callId: callId,
      callerId: callerId,
      ephA: ephA,
      encrypted: encrypted,
    );
    if (_callId != null) {
      if (_lastInboundOfferRecord == recordId &&
          _lastInboundOfferPlaintext != null) {
        return _lastInboundOfferPlaintext!;
      }
      throw const CallSignalingCryptoException('active_handshake');
    }
    final inFlight = _inboundOffer;
    if (inFlight != null) {
      if (_inboundOfferRecord == recordId) return inFlight;
      throw const CallSignalingCryptoException('active_handshake');
    }
    final future = _decryptOfferRecord(
      recordId: recordId,
      callId: callId,
      callerId: callerId,
      resolveCaller: resolveCaller,
      ephA: ephA,
      encrypted: encrypted,
    );
    _inboundOfferRecord = recordId;
    _inboundOffer = future;
    try {
      return await future;
    } finally {
      if (identical(_inboundOffer, future)) {
        _inboundOfferRecord = null;
        _inboundOffer = null;
      }
    }
  }

  Future<String> _decryptOfferRecord({
    required String recordId,
    required String callId,
    required String callerId,
    required ParsedIdentityBundle Function() resolveCaller,
    required Uint8List ephA,
    required Map<String, String> encrypted,
  }) async {
    final caller = resolveCaller();
    final dhId = await _dhWithPub(caller.x25519Pub);
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
    _peerBundle = caller;
    _amCaller = false;
    _ephPeerPub = Uint8List.fromList(ephA);
    _lastInboundOfferRecord = recordId;
    _lastInboundOfferPlaintext = plaintext;
    return plaintext;
  }

  /// Callee at ANSWER time: generate ephB, derive session keys, sign fp.
  /// [offerDtlsFps]/[answerDtlsFps] come from the EXACT SDP strings handed
  /// to setRemoteDescription.
  Future<({Uint8List eph, Uint8List fp})> beginAnswer({
    required String peerId,
    required Uint8List callerSig,
    required List<Uint8List> offerDtlsFps,
    required List<Uint8List> answerDtlsFps,
    @visibleForTesting List<int>? ephSeed,
  }) =>
      _beginAnswer(
        peerId: peerId,
        resolvePeer: () => _peerBundleFromPin(peerId),
        callerSig: callerSig,
        offerDtlsFps: offerDtlsFps,
        answerDtlsFps: answerDtlsFps,
        ephSeed: ephSeed,
      );

  Future<({Uint8List eph, Uint8List fp})> beginAnswerFirstContact({
    required String peerId,
    required String peerBundleB64,
    required Uint8List callerSig,
    required List<Uint8List> offerDtlsFps,
    required List<Uint8List> answerDtlsFps,
    @visibleForTesting List<int>? ephSeed,
  }) =>
      _beginAnswer(
        peerId: peerId,
        resolvePeer: () => _firstContactBundle(peerId, peerBundleB64),
        callerSig: callerSig,
        offerDtlsFps: offerDtlsFps,
        answerDtlsFps: answerDtlsFps,
        ephSeed: ephSeed,
      );

  /// Callee ring-time work: every expensive step of [beginAnswer] that does
  /// not depend on the local answer SDP — caller fingerprint verification,
  /// ephemeral keygen, and session key derivation. A later [beginAnswer]
  /// whose inputs match these only produces the fingerprint signature.
  /// Fire-and-forget; on failure the accept path runs the full sequence.
  Future<void> prepareAnswer({
    required String peerId,
    required Uint8List callerSig,
    required List<Uint8List> offerDtlsFps,
  }) async {
    if (_amCaller ||
        _answerStarted ||
        _answerPrepared ||
        _prepareInFlight != null ||
        _handshakeComplete ||
        _peerDeviceId != peerId) {
      return;
    }
    final future = _prepareAnswerCore(
      peerId: peerId,
      callerSig: callerSig,
      offerDtlsFps: offerDtlsFps,
    );
    _prepareInFlight = future;
    await future;
  }

  Future<void> _prepareAnswerCore({
    required String peerId,
    required Uint8List callerSig,
    required List<Uint8List> offerDtlsFps,
  }) async {
    try {
      final callId = _requireCallId();
      final ephA = _requirePeerEphPub();
      final peer = _peerBundleFromPin(peerId);
      final ok = await _verifyCallerFp(
        callId: callId,
        idA: peerId,
        idB: _myDeviceId,
        ephA: ephA,
        offerFps: offerDtlsFps,
        callerSig: callerSig,
        callerEd25519Pub: peer.ed25519Pub,
      );
      if (!ok) throw const CallSignalingCryptoException('crypto_failed');
      _ephLocal = await _x25519.newKeyPair();
      _ephLocalPub = Uint8List.fromList(
          (await _ephLocal!.extract() as SimpleKeyPairData).publicKey.bytes);
      await _deriveSessionKeys(peer.x25519Pub);
      _preppedPeerId = peerId;
      _preppedCallerSig = callerSig;
      _preppedOfferFps = offerDtlsFps;
      _answerPrepared = true;
      debugPrint('📞 Call crypto pre-derived during ringing');
    } catch (e) {
      debugPrint('⚠️ Ringing-time crypto prepare failed: $e');
    } finally {
      _prepareInFlight = null;
    }
  }

  /// In-flight [prepareAnswer] — [beginAnswer] awaits it so the ephemeral
  /// used for session keys is the same one bound into the fingerprint.
  Future<void>? _prepareInFlight;
  bool _answerPrepared = false;
  String? _preppedPeerId;
  Uint8List? _preppedCallerSig;
  List<Uint8List>? _preppedOfferFps;

  static bool _eqBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _eqFps(List<Uint8List> a, List<Uint8List> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => i).every((i) => _eqBytes(a[i], b[i]));

  Future<({Uint8List eph, Uint8List fp})> _beginAnswer({
    required String peerId,
    required ParsedIdentityBundle Function() resolvePeer,
    required Uint8List callerSig,
    required List<Uint8List> offerDtlsFps,
    required List<Uint8List> answerDtlsFps,
    List<int>? ephSeed,
  }) async {
    if (ephSeed != null && !_guarded) {
      throw const CallSignalingCryptoException('test_only_parameter');
    }
    final callId = _requireCallId();
    if (_amCaller || _answerStarted || _handshakeComplete) {
      throw const CallSignalingCryptoException('active_handshake');
    }
    if (_peerDeviceId != peerId) {
      throw const CallSignalingCryptoException('peer_identity_mismatch');
    }
    // If a ring-time prepare is mid-flight, let it finish — starting a
    // second keygen/derive would diverge ephB from the session keys.
    final inFlight = _prepareInFlight;
    if (inFlight != null) {
      await inFlight;
    }
    final prepped = _answerPrepared &&
        _preppedPeerId == peerId &&
        _eqBytes(callerSig, _preppedCallerSig!) &&
        _eqFps(offerDtlsFps, _preppedOfferFps!);
    final ephA = _requirePeerEphPub();
    final peer = resolvePeer();
    final cryptoStepWatch = Stopwatch()..start();
    if (!prepped) {
      final callerFpOk = await _verifyCallerFp(
        callId: callId,
        idA: peerId,
        idB: _myDeviceId,
        ephA: ephA,
        offerFps: offerDtlsFps,
        callerSig: callerSig,
        callerEd25519Pub: peer.ed25519Pub,
      );
      if (!callerFpOk) {
        throw const CallSignalingCryptoException('crypto_failed');
      }
    }
    debugPrint(
      '⏱️ beginAnswer.verifyCallerFp: ${cryptoStepWatch.elapsedMilliseconds}ms'
      '${prepped ? ' (pre-verified during ring)' : ''}',
    );
    cryptoStepWatch.reset();
    _answerStarted = true;
    try {
      if (prepped) {
        debugPrint('⏱️ beginAnswer.ephKeygen: 0ms (pre-generated)');
      } else {
        _ephLocal = _guarded && ephSeed != null
            ? await _x25519.newKeyPairFromSeed(Uint8List.fromList(ephSeed))
            : await _x25519.newKeyPair();
        _ephLocalPub = Uint8List.fromList(
            (await _ephLocal!.extract() as SimpleKeyPairData).publicKey.bytes);
      }
      debugPrint(
        '⏱️ beginAnswer.ephKeygen: ${cryptoStepWatch.elapsedMilliseconds}ms',
      );
      cryptoStepWatch.reset();

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
      debugPrint(
        '⏱️ beginAnswer.signCalleeFp: ${cryptoStepWatch.elapsedMilliseconds}ms',
      );
      cryptoStepWatch.reset();
      if (!prepped) await _deriveSessionKeys(peer.x25519Pub);
      debugPrint(
        '⏱️ beginAnswer.deriveSessionKeys: ${cryptoStepWatch.elapsedMilliseconds}ms',
      );
      _peerBundle = peer;
      _handshakeComplete = true;
      return (eph: _requireLocalEphPub(), fp: fp);
    } catch (_) {
      _answerStarted = false;
      rethrow;
    }
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

  String get _localDirection => _amCaller ? 'a2b' : 'b2a';
  String get _remoteDirection => _amCaller ? 'b2a' : 'a2b';

  Future<Map<String, String>> encryptMessage({
    required String event,
    required String plaintext,
  }) {
    final direction = _localDirection;
    final key = direction == 'a2b' ? _kAB : _kBA;
    if (key == null) {
      throw const CallSignalingCryptoException('session_keys_not_ready');
    }
    return _encryptWith(key, event, direction, plaintext);
  }

  Future<Map<String, String>> _encryptWith(
      SecretKey key, String event, String direction, String plaintext) async {
    _validateDirection(direction);
    final counter = _sendCounters[direction]!;
    if (counter >= maxCounter) {
      throw const CallSignalingCryptoException('counter_exhausted');
    }
    // Reserve the counter before the first await: concurrent encrypt calls
    // therefore receive distinct counters even though GCM encryption is async.
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
    required String event,
    required Map<String, String> encrypted,
  }) async {
    if (_failed) {
      throw const CallSignalingCryptoException('crypto_failed');
    }
    final direction = _remoteDirection;
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
    _validateDirection(direction);
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
      utf8.encode(callerFpDomain),
      utf8.encode(callId),
      utf8.encode(idA),
      utf8.encode(idB),
      ephA,
      _u32(offerFps.length),
      ...offerFps,
    ]);
    return _sign(callerFpDomain, material);
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
      utf8.encode(calleeFpDomain),
      utf8.encode(callId),
      utf8.encode(idA),
      utf8.encode(idB),
      ephA,
      ephB,
      _u32(offerFps.length),
      ...offerFps,
      _u32(answerFps.length),
      ...answerFps,
      Uint8List.fromList(callerSigHash.bytes),
    ]);
    return _sign(calleeFpDomain, material);
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
      utf8.encode(calleeFpDomain),
      utf8.encode(callId),
      utf8.encode(idA),
      utf8.encode(idB),
      ephA,
      ephB,
      _u32(offerFps.length),
      ...offerFps,
      _u32(answerFps.length),
      ...answerFps,
      Uint8List.fromList(callerSigHash.bytes),
    ]);
    return _ed25519.verify(
      IdentityService.domainBoundMessage(calleeFpDomain, material),
      signature: Signature(
        calleeSig,
        publicKey: SimplePublicKey(peerEd25519Pub, type: KeyPairType.ed25519),
      ),
    );
  }

  /// Verify the caller's signature (callee side) against the pinned identity.
  Future<bool> verifyCallerFp({
    required String callId,
    required String idA,
    required String idB,
    required Uint8List ephA,
    required List<Uint8List> offerFps,
    required Uint8List callerSig,
  }) async {
    final caller = _peerBundleFromPin(idA);
    return _verifyCallerFp(
      callId: callId,
      idA: idA,
      idB: idB,
      ephA: ephA,
      offerFps: offerFps,
      callerSig: callerSig,
      callerEd25519Pub: caller.ed25519Pub,
    );
  }

  /// First-contact variant: the only path that accepts a wire-supplied bundle.
  Future<bool> verifyCallerFpFirstContact({
    required String callId,
    required String idA,
    required String idB,
    required String callerBundleB64,
    required Uint8List ephA,
    required List<Uint8List> offerFps,
    required Uint8List callerSig,
  }) async {
    final caller = _firstContactBundle(idA, callerBundleB64);
    return _verifyCallerFp(
      callId: callId,
      idA: idA,
      idB: idB,
      ephA: ephA,
      offerFps: offerFps,
      callerSig: callerSig,
      callerEd25519Pub: caller.ed25519Pub,
    );
  }

  Future<bool> _verifyCallerFp({
    required String callId,
    required String idA,
    required String idB,
    required Uint8List ephA,
    required List<Uint8List> offerFps,
    required Uint8List callerSig,
    required List<int> callerEd25519Pub,
  }) async {
    final material = _frame([
      utf8.encode(callerFpDomain),
      utf8.encode(callId),
      utf8.encode(idA),
      utf8.encode(idB),
      ephA,
      _u32(offerFps.length),
      ...offerFps,
    ]);
    return _ed25519.verify(
      IdentityService.domainBoundMessage(callerFpDomain, material),
      signature: Signature(
        callerSig,
        publicKey: SimplePublicKey(callerEd25519Pub, type: KeyPairType.ed25519),
      ),
    );
  }

  ParsedIdentityBundle _peerBundleFromPin(String peerId) {
    final active = _peerBundle;
    if (active != null) {
      if (_peerDeviceId != peerId) {
        throw const CallSignalingCryptoException('peer_identity_mismatch');
      }
      return active;
    }
    final pin = _resolvePeerBundle(peerId);
    final parsed = pin != null ? IdentityService.parseBundle(pin) : null;
    if (parsed == null) {
      throw const CallSignalingCryptoException('no_pinned_peer_bundle');
    }
    return parsed;
  }

  ParsedIdentityBundle _firstContactBundle(String peerId, String bundleBase64) {
    final supplied = IdentityService.parseBundle(bundleBase64);
    if (supplied == null) {
      throw const CallSignalingCryptoException('invalid_peer_bundle');
    }
    final active = _peerBundle;
    if (active != null) {
      if (_peerDeviceId != peerId || !_sameBundle(active, supplied)) {
        throw const CallSignalingCryptoException('pinned_peer_bundle_conflict');
      }
      return active;
    }
    final pin = _resolvePeerBundle(peerId);
    if (pin == null) return supplied;
    final pinned = IdentityService.parseBundle(pin);
    if (pinned == null || !_sameBundle(pinned, supplied)) {
      throw const CallSignalingCryptoException('pinned_peer_bundle_conflict');
    }
    return pinned;
  }

  static bool _sameBundle(ParsedIdentityBundle a, ParsedIdentityBundle b) =>
      _bytesEqual(a.x25519Pub, b.x25519Pub) &&
      _bytesEqual(a.ed25519Pub, b.ed25519Pub);

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
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
    _peerBundle = null;
    _amCaller = false;
    _answerStarted = false;
    _completingHandshake = false;
    _handshakeComplete = false;
    _inboundOfferRecord = null;
    _inboundOffer = null;
    _lastInboundOfferRecord = null;
    _lastInboundOfferPlaintext = null;
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
