import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';

import '../crypto/pq_kem_service.dart';
import 'encryption_service.dart';
import 'identity_service.dart';
import 'local_storage_service.dart';

/// Result of decrypting any incoming envelope — v2, v2s, or legacy XOR.
class DecryptedEnvelope {
  DecryptedEnvelope({required this.senderId, required this.payload});

  /// Real sender device id. For sealed (v2s) messages this comes from the
  /// signed inner envelope, NOT the transport map.
  final String senderId;

  /// Inner payload fields ({t, rt, ex, vo, fn, fs, c, d, w, np, ts}).
  final Map<String, dynamic> payload;

  String get text => payload['t'] as String? ?? '';
  Map<String, dynamic>? get replyTo =>
      payload['rt'] is Map ? Map<String, dynamic>.from(payload['rt']) : null;
  int? get expiresAt => (payload['ex'] as num?)?.toInt();
  bool get isViewOnce => payload['vo'] == 1;
  String? get fileName => payload['fn'] as String?;
  int? get fileSize => (payload['fs'] as num?)?.toInt();
  bool? get compressed => payload['c'] == null ? null : payload['c'] == 1;
  int? get duration => (payload['d'] as num?)?.toInt();
  String? get waveformData => payload['w'] as String?;
  bool get disablePreview => payload['np'] == 1;
}

/// Wire prefixes.
const String kV2Prefix = 'v2:';
const String kV2sPrefix = 'v2s:';
const String kV3Prefix = 'v3:';
const String kV3sPrefix = 'v3s:';

/// Fixed ciphertext padding buckets (bytes) — ISO/IEC 7816-4 padding.
const List<int> kPaddingBuckets = [256, 512, 1024, 4096];

/// ISO/IEC 7816-4 pad: append 0x80 then 0x00s up to the next bucket.
Uint8List padToBucket(Uint8List plain) {
  var target = kPaddingBuckets.last;
  for (final b in kPaddingBuckets) {
    if (plain.length + 1 <= b) {
      target = b;
      break;
    }
  }
  if (plain.length + 1 > kPaddingBuckets.last) {
    target = ((plain.length + 1 + kPaddingBuckets.last - 1) ~/
            kPaddingBuckets.last) *
        kPaddingBuckets.last;
  }
  final out = Uint8List(target);
  out.setRange(0, plain.length, plain);
  out[plain.length] = 0x80;
  return out;
}

/// Strip ISO/IEC 7816-4 padding. Returns null when malformed — callers must
/// treat this as an authentication failure even though GCM already checked.
Uint8List? unpadBucket(Uint8List padded) {
  var i = padded.length - 1;
  while (i >= 0 && padded[i] == 0x00) {
    i--;
  }
  if (i < 0 || padded[i] != 0x80) return null;
  return Uint8List.fromList(padded.sublist(0, i));
}

/// Per-peer ratchet state, persisted in secure storage as JSON.
class RatchetState {
  RatchetState({required this.rk, required this.meSeed, required this.mePub});

  Uint8List rk; // root key (32B)
  Uint8List? sck; // send chain key
  Uint8List? rck; // recv chain key (ratcheted direction)
  Uint8List? brck; // bootstrap recv chain key (stragglers)
  int sn = 0; // send counter (current chain)
  int rn = 0; // recv counter (current ratcheted chain)
  int brn = 0; // recv counter (bootstrap chain)
  int pn = 0; // messages sent on the chain we just left
  bool sendBoot = true; // still sending on the bootstrap chain
  Uint8List meSeed; // local ephemeral X25519 seed
  Uint8List mePub; // local ephemeral X25519 public
  Uint8List? te; // their current ephemeral public
  Uint8List? teb; // their bootstrap-chain ephemeral public

  // -----------------------------------------------------------------------
  // Post-quantum state (v3 sessions). All fields default for backward
  // compatibility with persisted v2 sessions — absent keys mean classical.
  // -----------------------------------------------------------------------
  bool isPostQuantum = false;
  int pqEpoch = 0; // encapsulation epochs WE have sent (0 = none)
  int recvPqEpoch = 0; // latest peer epoch we decapsulated
  int pqSent = 0; // messages sent on the current epoch
  Uint8List? pqPub; // peer's verified ML-KEM-768 encapsulation key
  Uint8List? pendingKemCt; // our un-acked epoch ciphertext (re-sent until ka)
  Uint8List? pendingHybrid; // our epoch's hybrid secret (rebase material)
  Uint8List? rkPreEpoch; // rk before our pending epoch applied (rebase anchor)

  /// Skipped message keys `"<ephB64>:<counter>"` -> key, insertion ordered.
  final LinkedHashMap<String, String> skipped = LinkedHashMap();

  Map<String, dynamic> toJson() => {
        'rk': base64Encode(rk),
        'sck': sck == null ? null : base64Encode(sck!),
        'rck': rck == null ? null : base64Encode(rck!),
        'brck': brck == null ? null : base64Encode(brck!),
        'sn': sn,
        'rn': rn,
        'brn': brn,
        'pn': pn,
        'sendBoot': sendBoot,
        'meSeed': base64Encode(meSeed),
        'mePub': base64Encode(mePub),
        'te': te == null ? null : base64Encode(te!),
        'teb': teb == null ? null : base64Encode(teb!),
        if (isPostQuantum) 'pq': 1,
        'pqEpoch': pqEpoch,
        'recvPqEpoch': recvPqEpoch,
        'pqSent': pqSent,
        'pqPub': pqPub == null ? null : base64Encode(pqPub!),
        'pKem': pendingKemCt == null ? null : base64Encode(pendingKemCt!),
        'pHyb': pendingHybrid == null ? null : base64Encode(pendingHybrid!),
        'pRk': rkPreEpoch == null ? null : base64Encode(rkPreEpoch!),
        'skipped': skipped,
      };

  static RatchetState? fromJson(Map<String, dynamic> j) {
    try {
      Uint8List? dec(dynamic v) =>
          v is String ? Uint8List.fromList(base64Decode(v)) : null;
      final rk = dec(j['rk']);
      final meSeed = dec(j['meSeed']);
      final mePub = dec(j['mePub']);
      if (rk == null || meSeed == null || mePub == null) return null;
      final s = RatchetState(rk: rk, meSeed: meSeed, mePub: mePub)
        ..sck = dec(j['sck'])
        ..rck = dec(j['rck'])
        ..brck = dec(j['brck'])
        ..sn = (j['sn'] as num?)?.toInt() ?? 0
        ..rn = (j['rn'] as num?)?.toInt() ?? 0
        ..brn = (j['brn'] as num?)?.toInt() ?? 0
        ..pn = (j['pn'] as num?)?.toInt() ?? 0
        ..sendBoot = j['sendBoot'] == true
        ..te = dec(j['te'])
        ..teb = dec(j['teb'])
        ..isPostQuantum = j['pq'] == 1
        ..pqEpoch = (j['pqEpoch'] as num?)?.toInt() ?? 0
        ..recvPqEpoch = (j['recvPqEpoch'] as num?)?.toInt() ?? 0
        ..pqSent = (j['pqSent'] as num?)?.toInt() ?? 0
        ..pqPub = dec(j['pqPub'])
        ..pendingKemCt = dec(j['pKem'])
        ..pendingHybrid = dec(j['pHyb'])
        ..rkPreEpoch = dec(j['pRk']);
      final sk = j['skipped'];
      if (sk is Map) {
        sk.forEach((k, v) {
          if (k is String && v is String) s.skipped[k] = v;
        });
      }
      return s;
    } catch (_) {
      return null;
    }
  }

  /// Deep copy used for transactional decrypt: every mutable buffer is
  /// copied so in-place zeroing and chain advancement on the clone can
  /// never touch the live session.
  RatchetState clone() {
    Uint8List? cp(Uint8List? v) => v == null ? null : Uint8List.fromList(v);
    final c = RatchetState(
      rk: Uint8List.fromList(rk),
      meSeed: Uint8List.fromList(meSeed),
      mePub: Uint8List.fromList(mePub),
    )
      ..sck = cp(sck)
      ..rck = cp(rck)
      ..brck = cp(brck)
      ..sn = sn
      ..rn = rn
      ..brn = brn
      ..pn = pn
      ..sendBoot = sendBoot
      ..te = cp(te)
      ..teb = cp(teb)
      ..isPostQuantum = isPostQuantum
      ..pqEpoch = pqEpoch
      ..recvPqEpoch = recvPqEpoch
      ..pqSent = pqSent
      ..pqPub = cp(pqPub)
      ..pendingKemCt = cp(pendingKemCt)
      ..pendingHybrid = cp(pendingHybrid)
      ..rkPreEpoch = cp(rkPreEpoch);
    c.skipped.addAll(skipped);
    return c;
  }
}

/// Pure per-peer ratchet engine — no GetX, no storage. Fully unit-testable.
///
/// Protocol (Signal-inspired, simplified to what identity keys allow):
///  - rootKey = HKDF(X25519(myId, peerId)) — computed by the caller.
///  - Until the peer's ephemeral is known, messages ride a directional
///    bootstrap chain derived from the root key ('vant-boot-a' / 'vant-boot-b'
///    chosen by lexical device-id order so reflections can't authenticate).
///  - Every reply ratchets: receiver of a new ephemeral E computes
///    (rk, recvCK) = HKDF(rk, DH(myEph, E)); the next send rotates the local
///    ephemeral and derives (rk, sendCK) = HKDF(rk, DH(newEph, E)).
///  - Chain step: nextCK = HMAC-SHA256(ck, 0x02), mk = HMAC-SHA256(ck, 0x01).
///  - Skipped message keys cached (bounded) for out-of-order delivery.
class RatchetCore {
  RatchetCore._(this.s,
      {required this.iAmLow, this.ssX25519, this.myPqSecretKey});

  /// Session state — swapped atomically to a clone on decrypt commit.
  RatchetState s;

  /// True when our device id sorts before the peer's — selects the bootstrap
  /// chain tag so send/recv directions never collide.
  final bool iAmLow;

  /// Injected on create/restore — X25519(myIdentity, peerIdentity) shared
  /// secret, needed to recombine every inbound PQ epoch.
  final Future<Uint8List?> Function()? ssX25519;

  /// Injected on create/restore — our long-term ML-KEM-768 decapsulation
  /// key (2400B), needed to decapsulate peer epochs. Never persisted inside
  /// ratchet state; the identity store owns it.
  final Future<Uint8List?> Function()? myPqSecretKey;

  static const int maxSkippedKeys = 50;

  /// Sent messages between post-quantum epoch rotations.
  static const int pqEpochLength = 100;

  static final _x25519 = X25519();
  static final _aes = AesGcm.with256bits();
  static final _hmac = Hmac.sha256();
  static final _hkdf32 = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _hkdf64 = Hkdf(hmac: Hmac.sha256(), outputLength: 64);

  /// FIPS 203 hybrid combiner: confidential if EITHER X25519 OR
  /// ML-KEM-768 remains unbroken.
  static Future<Uint8List> deriveHybridRootKey(
      Uint8List ssX25519, Uint8List ssPq) async {
    final key = await _hkdf32.deriveKey(
      secretKey: SecretKey(Uint8List.fromList([...ssX25519, ...ssPq])),
      nonce: utf8.encode('vant-chat-pq-hybrid-salt-v3'),
      info: utf8.encode('vant-chat-x25519-mlkem768-rk-v3'),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// New session: fresh local ephemeral, bootstrap send chain derived now so
  /// the root key is never needed again for bootstrap derivations.
  ///
  /// For [isPostQuantum] sessions the classical [rootKey] is the base the
  /// first epoch applies onto — there are NO bootstrap chains; the KEM
  /// epoch mechanism is the bootstrap.
  static Future<RatchetCore> create({
    required Uint8List rootKey,
    required bool iAmLow,
    bool isPostQuantum = false,
    Uint8List? peerPqPub,
    Future<Uint8List?> Function()? ssX25519,
    Future<Uint8List?> Function()? myPqSecretKey,
  }) async {
    final eph = await _x25519.newKeyPair();
    final data = await eph.extract();
    final s = RatchetState(
      // Copy — the state zeroes rk on ratchet and must never alias a
      // caller-owned buffer.
      rk: Uint8List.fromList(rootKey),
      meSeed: Uint8List.fromList(data.bytes),
      mePub: Uint8List.fromList(data.publicKey.bytes),
    )
      ..isPostQuantum = isPostQuantum
      ..pqPub = peerPqPub == null ? null : Uint8List.fromList(peerPqPub);
    if (isPostQuantum) {
      s.sendBoot = false;
    } else {
      // Both directional bootstrap chains are derived eagerly: once a DH
      // ratchet advances rk, the original root key is unrecoverable, so a
      // bootstrap straggler arriving after a ratcheted frame could never be
      // decrypted if this were lazy.
      s.sck = await _hkdfExpand(rootKey, _bootTag(iAmLow));
      s.brck = await _hkdfExpand(rootKey, _bootTag(!iAmLow));
      s.sendBoot = true;
    }
    return RatchetCore._(s,
        iAmLow: iAmLow, ssX25519: ssX25519, myPqSecretKey: myPqSecretKey);
  }

  static RatchetCore? restore(
    Map<String, dynamic> json, {
    required bool iAmLow,
    Future<Uint8List?> Function()? ssX25519,
    Future<Uint8List?> Function()? myPqSecretKey,
  }) {
    final s = RatchetState.fromJson(json);
    return s == null
        ? null
        : RatchetCore._(s,
            iAmLow: iAmLow, ssX25519: ssX25519, myPqSecretKey: myPqSecretKey);
  }

  Map<String, dynamic> dumpState() => s.toJson();

  static Uint8List _bootTag(bool low) =>
      Uint8List.fromList(utf8.encode(low ? 'vant-boot-a' : 'vant-boot-b'));

  static Future<Uint8List> _hkdfExpand(Uint8List ikm, List<int> info) async {
    final key = await _hkdf32.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: const <int>[],
      info: info,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// Signal KDF_RK: (rk', ck) = HKDF-64(ikm=dh, salt=rk, info='vant-rk').
  static Future<(Uint8List, Uint8List)> _kdfRk(
      Uint8List rk, SecretKey dh) async {
    final key = await _hkdf64.deriveKey(
      secretKey: dh,
      nonce: rk,
      info: utf8.encode('vant-rk'),
    );
    final out = await key.extractBytes();
    return (
      Uint8List.fromList(out.sublist(0, 32)),
      Uint8List.fromList(out.sublist(32, 64)),
    );
  }

  static Future<Uint8List> _mac(Uint8List ck, int tag) async {
    final mac = await _hmac.calculateMac(
      [tag],
      secretKey: SecretKey(ck),
    );
    return Uint8List.fromList(mac.bytes);
  }

  static Future<Uint8List> _dh(Uint8List mySeed, Uint8List peerPub) async {
    final kp = await _x25519.newKeyPairFromSeed(mySeed);
    final secret = await _x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey: SimplePublicKey(peerPub, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await secret.extractBytes());
  }

  static Uint8List _aad(String ephB64, int n, int pn,
          [int? pqEpoch, String? kemCtB64, int? kemAck]) =>
      Uint8List.fromList(utf8.encode(pqEpoch == null
          ? 'v2|$ephB64|$n|$pn'
          : 'v3|$ephB64|$n|$pn|$pqEpoch|${kemCtB64 ?? '-'}|${kemAck ?? 0}'));

  void _cacheSkipped(RatchetState st, String ephB64, int n, Uint8List mk) {
    if (st.skipped.length >= maxSkippedKeys) {
      st.skipped.remove(st.skipped.keys.first);
    }
    st.skipped['$ephB64:$n'] = base64Encode(mk);
  }

  Future<void> _rotateLocalEphemeral() async {
    final eph = await _x25519.newKeyPair();
    final data = await eph.extract();
    s.meSeed = Uint8List.fromList(data.bytes);
    s.mePub = Uint8List.fromList(data.publicKey.bytes);
  }

  /// Begin a new outbound PQ epoch: encapsulate to the peer's ML-KEM-768
  /// key, mix the hybrid secret into the root chain, and start a fresh send
  /// chain. The ciphertext rides every outbound frame until the peer's
  /// `ka` (kem-ack) proves delivery.
  Future<bool> startPqEpoch() async {
    if (!s.isPostQuantum || s.pqPub == null || ssX25519 == null) return false;
    try {
      final enc = await PqKemService.encapsulate(s.pqPub!);
      final ssX = await ssX25519!();
      if (ssX == null) {
        PqKemService.zero(enc.sharedSecret);
        return false;
      }
      final hybrid = await deriveHybridRootKey(ssX, enc.sharedSecret);
      PqKemService.zero(enc.sharedSecret);

      await _rotateLocalEphemeral();
      final preRk = s.rk;
      final (rk, ck) = await _kdfRk(preRk, SecretKey(hybrid));
      if (s.sck != null) _zero(s.sck!);
      s
        ..rkPreEpoch = preRk
        ..pendingHybrid = hybrid
        ..rk = rk
        ..sck = ck
        ..pn = s.sn
        ..sn = 0
        ..pqEpoch = s.pqEpoch + 1
        ..pendingKemCt = enc.ciphertext
        ..pqSent = 0;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Encrypt [plain] (already ISO7816-padded) into a `v2:`/`v3:` envelope
  /// string. Mutates chain state — callers must persist [dumpState].
  Future<String?> encrypt(Uint8List plain) async {
    if (s.isPostQuantum) {
      // Epoch rotation every pqEpochLength sent messages, but never while
      // a previous epoch ciphertext is still awaiting its ack — overlapping
      // own-rotations would make the merge order ambiguous.
      if (s.sck == null && s.te == null) {
        // No usable chain yet — we must be the session initiator.
        if (!await startPqEpoch()) return null;
      } else if (s.sck == null && s.te != null) {
        // Responder's first send — plain DH ratchet step.
        await _dhRatchetSend();
      } else if (s.pqSent >= pqEpochLength &&
          s.pendingKemCt == null &&
          s.pqPub != null) {
        await startPqEpoch();
      }
    } else if ((s.sendBoot && s.te != null) || s.sck == null) {
      // Leaving the bootstrap chain the moment the peer's ephemeral is
      // known gives every reply a fresh DH ratchet step.
      if (s.te != null) {
        await _dhRatchetSend();
      } else if (s.sck == null) {
        s.sck = await _hkdfExpand(s.rk, _bootTag(iAmLow));
        s.sendBoot = true;
      }
    }

    final ephB64 = base64Encode(s.mePub);
    final n = s.sn;
    final mk = await _mac(s.sck!, 0x01);
    final next = await _mac(s.sck!, 0x02);
    _zero(s.sck!);
    s.sck = next;
    s.sn = n + 1;
    s.pqSent += 1;

    final kctB64 =
        s.pendingKemCt == null ? null : base64Encode(s.pendingKemCt!);
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      plain,
      secretKey: SecretKey(mk),
      nonce: nonce,
      aad: _aad(ephB64, n, s.pn, s.isPostQuantum ? s.pqEpoch : null, kctB64,
          s.isPostQuantum ? s.recvPqEpoch : null),
    );
    _zero(mk);
    _zero(plain);

    final prefix = s.isPostQuantum ? kV3Prefix : kV2Prefix;
    return prefix +
        base64UrlEncode(utf8.encode(jsonEncode({
          'e': ephB64,
          'n': n,
          'pn': s.pn,
          if (s.sendBoot) 'b': 1,
          if (s.isPostQuantum) 'pq': s.pqEpoch,
          if (s.isPostQuantum) 'ka': s.recvPqEpoch,
          if (kctB64 != null) 'kct': kctB64,
          'ct': base64Encode(box.concatenation()),
        })));
  }

  /// Shared DH-ratchet send step used by both v2 and v3 (same-epoch) sends.
  Future<void> _dhRatchetSend() async {
    await _rotateLocalEphemeral();
    final dh = SecretKey(await _dh(s.meSeed, s.te!));
    final (rk, ck) = await _kdfRk(s.rk, dh);
    _zero(s.rk);
    if (s.sck != null) _zero(s.sck!);
    s
      ..rk = rk
      ..sck = ck
      ..pn = s.sn
      ..sn = 0
      ..sendBoot = false;
  }

  /// Decrypt a `v2:`/`v3:` envelope. Returns the padded plaintext (caller
  /// unpads) or null on authentication failure / malformed input.
  Future<Uint8List?> decrypt(String envelope) async {
    final expectedPrefix = s.isPostQuantum ? kV3Prefix : kV2Prefix;
    if (!envelope.startsWith(expectedPrefix)) return null;
    Map<String, dynamic> env;
    try {
      env = jsonDecode(utf8.decode(base64Url.decode(
          envelope.substring(expectedPrefix.length))))
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final ephStr = env['e'];
    final nRaw = env['n'];
    final pn = (env['pn'] as num?)?.toInt() ?? 0;
    final ctStr = env['ct'];
    final boot = env['b'] == 1;
    final pq = (env['pq'] as num?)?.toInt() ?? 0;
    final ka = (env['ka'] as num?)?.toInt() ?? 0;
    final kctStr = env['kct'];
    if (ephStr is! String || nRaw is! num || ctStr is! String) {
      return null;
    }
    // PQ sessions never send bootstrap frames; v2 sessions never send
    // epoch headers — cross-protocol fields are malformed.
    if (s.isPostQuantum ? boot : (pq != 0 || kctStr != null)) return null;
    final n = nRaw.toInt();
    final Uint8List eph;
    try {
      eph = Uint8List.fromList(base64Decode(ephStr));
      if (eph.length != 32) return null;
    } catch (_) {
      return null;
    }

    // Reflected own-ephemeral frames can never be authentic.
    if (_eq(eph, s.mePub)) return null;

    final aad = _aad(
        ephStr,
        n,
        pn,
        s.isPostQuantum ? pq : null,
        kctStr is String ? kctStr : null,
        s.isPostQuantum ? ka : null);

    // 1. Skipped-key fast path (out-of-order delivery). The key is only
    // consumed AFTER its frame authenticates — a forged frame cannot burn
    // a cached key for a message still in flight.
    final skippedKey = '$ephStr:$n';
    final skipped = s.skipped[skippedKey];
    if (skipped != null) {
      final mk = Uint8List.fromList(base64Decode(skipped));
      final out = await _open(mk, ctStr, aad);
      _zero(mk);
      if (out != null) {
        s.skipped.remove(skippedKey);
        _ackPendingEpoch(ka);
      }
      return out;
    }

    // 2. All ratchet advancement happens on a clone — a forged frame that
    // fails AEAD must leave the live session byte-for-byte untouched so
    // the next genuine frame still decrypts.
    final w = s.clone();

    Uint8List mk;
    if (boot) {
      // Bootstrap chain — directional, derived eagerly at session create.
      if (w.brck == null) return null; // restored state without boot chain
      w.teb ??= eph;
      w.te ??= eph;
      // Skip bound — the counter is attacker-controlled and this loop runs
      // before AEAD verification. An unbounded claim (n=999999) would burn
      // ~1M HMACs per forged frame: CPU exhaustion via one packet.
      if (n - w.brn > maxSkippedKeys) return null;
      while (w.brn < n) {
        _cacheSkipped(w, ephStr, w.brn, await _mac(w.brck!, 0x01));
        w.brck = await _mac(w.brck!, 0x02);
        w.brn++;
      }
      if (n < w.brn) return null; // already consumed, no skipped key → replay
      mk = await _mac(w.brck!, 0x01);
      w.brck = await _mac(w.brck!, 0x02);
      w.brn++;
    } else {
      final newPeerEpoch = w.isPostQuantum && pq > w.recvPqEpoch;
      if (w.te == null || !_eq(eph, w.te!) || newPeerEpoch) {
        // New remote ephemeral or new PQ epoch → ratchet step. First
        // exhaust the previous recv chains up to the sender's previous-
        // chain length so delayed deliveries still decrypt.
        await _exhaust(w, w.te, w.rck, w.rn, pn, false);
        await _exhaust(w, w.teb, w.brck, w.brn, pn, true);
        if (newPeerEpoch) {
          if (!await _applyPeerEpoch(
              w, eph, pq, ka, kctStr is String ? kctStr : null)) {
            return null;
          }
        } else {
          final dh = SecretKey(await _dh(w.meSeed, eph));
          final (rk, ck) = await _kdfRk(w.rk, dh);
          _zero(w.rk);
          w
            ..rk = rk
            ..rck = ck
            ..te = eph
            ..rn = 0
            // Peer rotated on reply — our next send must rotate too.
            ..sck = null;
        }
        if (w.sendBoot) w.sendBoot = false;
      }
      while (w.rn < n) {
        _cacheSkipped(w, ephStr, w.rn, await _mac(w.rck!, 0x01));
        w.rck = await _mac(w.rck!, 0x02);
        w.rn++;
      }
      if (n < w.rn) return null;
      mk = await _mac(w.rck!, 0x01);
      w.rck = await _mac(w.rck!, 0x02);
      w.rn++;
    }

    final out = await _open(mk, ctStr, aad);
    _zero(mk);
    if (out == null) return null; // discard the clone — live state intact
    s = w; // commit only after AEAD authentication succeeded
    _ackPendingEpoch(ka);
    return out;
  }

  /// Apply an inbound post-quantum epoch: decapsulate the KEM ciphertext,
  /// recombine the hybrid root key, and move the peer's recv chain onto a
  /// fresh kdfRk output.
  ///
  /// Simultaneous-rotation merge: if our own epoch is still un-acked (the
  /// peer's `ka` hasn't caught up to [RatchetState.pqEpoch]), the peer
  /// rotated before seeing our ciphertext — so both epoch secrets must
  /// apply in canonical order (lexically-low device id's hybrid first) and
  /// both sides converge on the same root key. The peer's frame itself is
  /// always authenticated on the chain they derived from THEIR pre-epoch
  /// root, so its recv chain is `kdfRk(preRk, hPeer)` regardless of merge
  /// order.
  ///
  /// `sck` is left null in every epoch path — the next send takes a plain
  /// DH ratchet step, which converges identically on both sides.
  Future<bool> _applyPeerEpoch(
      RatchetState st, Uint8List eph, int pq, int ka, String? kctStr) async {
    if (kctStr == null || myPqSecretKey == null || ssX25519 == null) {
      return false;
    }
    final Uint8List kct;
    try {
      kct = Uint8List.fromList(base64Decode(kctStr));
    } catch (_) {
      return false;
    }
    final Uint8List? mySk = await myPqSecretKey!();
    final Uint8List? ssX = await ssX25519!();
    if (mySk == null || ssX == null) return false;
    final Uint8List ssPq;
    try {
      ssPq = await PqKemService.decapsulate(kct, mySk);
    } catch (_) {
      return false;
    }
    final hybrid = await deriveHybridRootKey(ssX, ssPq);
    PqKemService.zero(ssPq);

    final simultaneous = st.pendingKemCt != null &&
        st.pendingHybrid != null &&
        st.rkPreEpoch != null &&
        ka < st.pqEpoch;

    if (simultaneous && !iAmLow) {
      // Peer (low side) applies first: hPeer → then our own hMine.
      final (rk1, ckPeer) =
          await _kdfRk(st.rkPreEpoch!, SecretKey(hybrid));
      final (rk2, _) =
          await _kdfRk(rk1, SecretKey(st.pendingHybrid!));
      _zero(st.rk);
      st
        ..rk = rk2
        ..rck = ckPeer
        ..te = eph
        ..rn = 0
        ..recvPqEpoch = pq
        ..sck = null;
      return true;
    }

    if (simultaneous) {
      // We are the low side — our pending material already applied first.
      // Peer's chain still derives from the shared pre-epoch root.
      final (rkPeerBase, ckPeer) =
          await _kdfRk(st.rkPreEpoch!, SecretKey(hybrid));
      _zero(rkPeerBase);
      final (rk2, _) = await _kdfRk(st.rk, SecretKey(hybrid));
      _zero(st.rk);
      st
        ..rk = rk2
        ..rck = ckPeer
        ..te = eph
        ..rn = 0
        ..recvPqEpoch = pq
        ..sck = null;
      return true;
    }

    // Sequential epoch — the peer had already merged (or never saw) our
    // prior rotation, so apply their hybrid onto the current root.
    final (rk, ck) = await _kdfRk(st.rk, SecretKey(hybrid));
    _zero(st.rk);
    st
      ..rk = rk
      ..rck = ck
      ..te = eph
      ..rn = 0
      ..recvPqEpoch = pq
      // Peer ratcheted — our next send must rotate off the new base.
      ..sck = null;
    return true;
  }

  /// A peer frame authenticating `ka >= our sent epoch` proves they
  /// decapsulated our pending KEM ciphertext — stop re-attaching it.
  void _ackPendingEpoch(int ka) {
    if (s.pendingKemCt != null && ka >= s.pqEpoch) {
      s.pendingKemCt = null;
      if (s.pendingHybrid != null) _zero(s.pendingHybrid!);
      s.pendingHybrid = null;
      s.rkPreEpoch = null;
    }
  }

  Future<void> _exhaust(RatchetState st, Uint8List? eph, Uint8List? ck,
      int count, int upto, bool bootChain) async {
    if (eph == null || ck == null) return;
    final ephB64 = base64Encode(eph);
    var c = count;
    var chain = ck;
    // Bound the exhaust so a hostile pn can't burn the cache/CPU.
    final limit = upto.clamp(0, maxSkippedKeys);
    while (c < limit) {
      _cacheSkipped(st, ephB64, c, await _mac(chain, 0x01));
      chain = await _mac(chain, 0x02);
      c++;
    }
    if (bootChain) {
      st.brck = chain;
      st.brn = c;
    } else {
      st.rck = chain;
      st.rn = c;
    }
  }

  /// [ctB64] is the AES-GCM concatenation nonce+ciphertext+mac produced by
  /// SecretBox.concatenation().
  Future<Uint8List?> _open(Uint8List mk, String ctB64, List<int> aad) async {
    try {
      final pt = await _aes.decrypt(
        SecretBox.fromConcatenation(
          base64Decode(ctB64),
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

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }

  static void _zero(List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = 0;
    }
  }
}

/// Sealed-sender + ratchet message crypto.
///
/// Wire formats:
///   v2:  base64url({e,ephB64,n,pn,b?,nonce,ct}) — ratcheted AES-256-GCM
///   v2s: base64url({e,sealEphB64,nonce,ct})    — AES-256-GCM of
///        {s,senderDeviceId,sig,m:v2-envelope} sealed to the peer's
///        identity X25519 key, sig = Ed25519 over the v2 envelope bound
///        to the recipient id.
class MessageCryptoService extends GetxService {
  IdentityService get _identity => Get.find<IdentityService>();
  LocalStorageService get _storage => Get.find<LocalStorageService>();

  static const _storeKey = 'vant_ratchet_v1';

  final FlutterSecureStorage _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      keyCipherAlgorithm: KeyCipherAlgorithm.RSA_ECB_PKCS1Padding,
      storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
      resetOnError: false,
    ),
    iOptions: IOSOptions(
      accountName: 'VantRatchetStore',
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );

  final Map<String, RatchetCore> _cores = {};
  final Map<String, Future<void>> _locks = {};

  /// Capability strings announced via the signed identity-announce channel.
  static const String capabilityE2eMsg = 'e2e_msg';
  static const String capabilityPqMlKem = 'pq_mlkem768';

  /// True when we can send sealed v2 to this peer: identity loaded, bundle
  /// pinned, and the peer signed the e2e_msg capability.
  bool canSealTo(String peerDeviceId) {
    if (!_identity.hasIdentity.value) return false;
    if (_storage.getPeerBundle(peerDeviceId) == null) return false;
    return _storage.peerHasCapability(peerDeviceId, capabilityE2eMsg);
  }

  /// True when the peer can receive hybrid `v3s:` (X25519 + ML-KEM-768):
  /// e2e_msg + pq_mlkem768 capabilities, a signature-verified cached PQ
  /// key, and our own PQ identity materialized.
  bool canSealPqTo(String peerDeviceId) {
    if (!canSealTo(peerDeviceId)) return false;
    if (!_identity.hasPqIdentity) return false;
    if (!_storage.peerHasCapability(peerDeviceId, capabilityPqMlKem)) {
      return false;
    }
    final pqPub = _storage.getPeerPqPublicKey(peerDeviceId);
    return pqPub != null && pqPub.length == PqKemService.publicKeyBytes;
  }

  /// Serialize all ratchet ops for a peer — concurrent send/receive must not
  /// interleave chain mutations.
  Future<T> _locked<T>(String peer, Future<T> Function() op) {
    final prev = _locks[peer] ?? Future.value();
    final run = prev.then((_) => op());
    _locks[peer] = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Identity X25519 shared secret against the peer's pinned bundle —
  /// injected into PQ cores so every inbound epoch can re-derive the
  /// hybrid combiner input.
  Future<Uint8List?> _ssXProvider(String peer) async {
    final bundle = _storage.getPeerBundle(peer);
    final parsed = bundle == null ? null : IdentityService.parseBundle(bundle);
    if (parsed == null) return null;
    try {
      final dh = await _identity.identitySharedSecret(parsed.x25519Pub);
      return Uint8List.fromList(await dh.extractBytes());
    } catch (_) {
      return null;
    }
  }

  /// [wantPostQuantum] is the session type the caller requires — from the
  /// outbound capability gate on send, or the inbound envelope prefix.
  Future<RatchetCore?> _coreFor(String peer,
      {bool wantPostQuantum = false}) async {
    final cached = _cores[peer];
    if (cached != null && cached.s.isPostQuantum == wantPostQuantum) {
      return cached;
    }
    if (cached != null) {
      // Protocol version changed mid-session (peer upgrade) — rebuild.
      _cores.remove(peer);
    }

    final myId = _storage.deviceId;
    final iAmLow = myId != null && myId.compareTo(peer) < 0;

    // Restore persisted state first.
    try {
      final raw = await _secure.read(key: '$_storeKey:$peer');
      if (raw != null) {
        final restored = RatchetCore.restore(
            jsonDecode(raw) as Map<String, dynamic>,
            iAmLow: iAmLow,
            ssX25519: () => _ssXProvider(peer),
            myPqSecretKey: () async => _identity.mlkemSecretKey);
        if (restored != null) {
          if (restored.s.isPostQuantum == wantPostQuantum) {
            _cores[peer] = restored;
            return restored;
          }
        }
      }
    } catch (e) {
      debugPrint('⚠️ Ratchet state read failed for $peer: $e');
    }

    // Fresh session: rootKey = HKDF(X25519(identity, peerIdentityPub)).
    final bundle = _storage.getPeerBundle(peer);
    final parsed = bundle == null ? null : IdentityService.parseBundle(bundle);
    if (parsed == null) {
      debugPrint('⚠️ No pinned identity bundle for $peer — cannot init E2E');
      return null;
    }
    try {
      final dh = await _identity.identitySharedSecret(parsed.x25519Pub);
      final dhBytes = Uint8List.fromList(await dh.extractBytes());
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final rk = Uint8List.fromList(await (await hkdf.deriveKey(
        secretKey: SecretKey(dhBytes),
        nonce: const <int>[],
        info: utf8.encode('vant-msg-rk'),
      ))
          .extractBytes());
      RatchetCore._zero(dhBytes);
      final pqPub =
          wantPostQuantum ? _storage.getPeerPqPublicKey(peer) : null;
      final core = await RatchetCore.create(
        rootKey: rk,
        iAmLow: iAmLow,
        isPostQuantum: wantPostQuantum,
        peerPqPub: pqPub,
        ssX25519: () => _ssXProvider(peer),
        myPqSecretKey: () async => _identity.mlkemSecretKey,
      );
      _cores[peer] = core;
      await _persist(peer, core);
      return core;
    } catch (e) {
      debugPrint('⚠️ Ratchet session init failed for $peer: $e');
      return null;
    }
  }

  Future<void> _persist(String peer, RatchetCore core) async {
    try {
      await _secure.write(
          key: '$_storeKey:$peer', value: jsonEncode(core.dumpState()));
    } catch (e) {
      debugPrint('⚠️ Ratchet state persist failed for $peer: $e');
    }
  }

  /// Build the inner padded JSON payload and ratchet-encrypt it.
  /// Returns the `v2:`/`v3:` envelope, or null when no session can be
  /// built.
  Future<String?> encryptForPeer(
      String peerDeviceId, Map<String, dynamic> payload) {
    return _locked(peerDeviceId, () async {
      final core = await _coreFor(peerDeviceId,
          wantPostQuantum: canSealPqTo(peerDeviceId));
      if (core == null) return null;
      final padded = padToBucket(
          Uint8List.fromList(utf8.encode(jsonEncode(payload))));
      final env = await core.encrypt(padded);
      await _persist(peerDeviceId, core);
      return env;
    });
  }

  /// Wrap a ratchet envelope in a sealed-sender `v2s:`/`v3s:` envelope
  /// addressed to [recipientDeviceId]'s pinned identity key. `v3s:` is
  /// selected when the peer advertises a verified pq_mlkem768 capability.
  Future<String?> sealForPeer(
      String recipientDeviceId, Map<String, dynamic> payload) async {
    final myId = _storage.deviceId;
    final bundle = _storage.getPeerBundle(recipientDeviceId);
    final parsed = bundle == null ? null : IdentityService.parseBundle(bundle);
    if (myId == null || parsed == null) return null;

    final inner = await encryptForPeer(recipientDeviceId, payload);
    if (inner == null) return null;

    return sealEnvelope(
      senderId: myId,
      recipientId: recipientDeviceId,
      recipientX25519Pub: parsed.x25519Pub,
      recipientPqPub: canSealPqTo(recipientDeviceId)
          ? _storage.getPeerPqPublicKey(recipientDeviceId)
          : null,
      innerV2: inner,
      signFn: (message) =>
          _identity.signBytes(IdentityService.domainMsgSeal, message),
    );
  }

  /// Pure sealed-sender wrap — injectable deps so tests drive it without
  /// GetX/secure-storage. Returns the `v2s:` envelope, or `v3s:` when
  /// [recipientPqPub] is supplied (hybrid X25519 + ML-KEM-768 seal).
  static Future<String?> sealEnvelope({
    required String senderId,
    required String recipientId,
    required Uint8List recipientX25519Pub,
    required String innerV2,
    required Future<Uint8List> Function(List<int> message) signFn,
    Uint8List? recipientPqPub,
  }) async {
    try {
      final sealEph = await X25519().newKeyPair();
      final ephData = await sealEph.extract();
      final shared = await X25519().sharedSecretKey(
        keyPair: sealEph,
        remotePublicKey:
            SimplePublicKey(recipientX25519Pub, type: KeyPairType.x25519),
      );
      // Reject low-order points — an all-zero shared secret means the
      // recipient pubkey was malformed/low-order and the seal is unsafe.
      final sharedBytes =
          Uint8List.fromList(await shared.extractBytes());
      var acc = 0;
      for (final b in sharedBytes) {
        acc |= b;
      }
      if (acc == 0) return null;

      // Hybrid seal: ML-KEM-768 encapsulation adds a post-quantum shared
      // secret so the seal stays confidential even if X25519 falls.
      PqEncapsulation? enc;
      Uint8List sealInput = sharedBytes;
      if (recipientPqPub != null) {
        enc = await PqKemService.encapsulate(recipientPqPub);
        sealInput = await RatchetCore.deriveHybridRootKey(
            sharedBytes, enc.sharedSecret);
        PqKemService.zero(enc.sharedSecret);
      }
      final sealKey = await _sealKey(SecretKey(sealInput));
      final sig = await signFn(utf8.encode('$recipientId|$innerV2'));
      final innerJson = utf8.encode(jsonEncode({
        's': senderId,
        'sig': base64Encode(sig),
        'm': innerV2,
      }));
      final nonce = AesGcm.with256bits().newNonce();
      final ephPubB64 = base64Encode(ephData.publicKey.bytes);
      final kemCtB64 =
          enc == null ? null : base64Encode(enc.ciphertext);
      final aad = kemCtB64 == null
          ? utf8.encode('v2s|$ephPubB64')
          : utf8.encode('v3s|$ephPubB64|$kemCtB64');
      final box = await AesGcm.with256bits().encrypt(
        innerJson,
        secretKey: sealKey,
        nonce: nonce,
        aad: aad,
      );
      final prefix = enc == null ? kV2sPrefix : kV3sPrefix;
      return prefix +
          base64UrlEncode(utf8.encode(jsonEncode({
            'e': ephPubB64,
            if (kemCtB64 != null) 'kct': kemCtB64,
            'ct': base64Encode(box.concatenation()),
          })));
    } catch (e) {
      debugPrint('⚠️ Sealed-sender wrap failed: $e');
      return null;
    }
  }

  /// Pure sealed-sender open — returns the inner {senderId, ratchet
  /// envelope} after signature verification, or null on any failure.
  /// `v3s:` envelopes additionally carry `kct` — the ML-KEM-768 ciphertext
  /// decapsulated via [pqDecapsFn] into the hybrid seal key.
  static Future<({String senderId, String innerV2})?> openSealedEnvelope({
    required String envelope,
    required String myId,
    required Future<SecretKey> Function(Uint8List ephemeralPub) dhFn,
    required Future<bool> Function(
            String senderId, List<int> message, String sigB64)
        verifyFn,
    Future<Uint8List> Function(Uint8List kemCiphertext)? pqDecapsFn,
  }) async {
    final isV3 = envelope.startsWith(kV3sPrefix);
    final prefix = isV3 ? kV3sPrefix : kV2sPrefix;
    Map<String, dynamic> env;
    try {
      env = jsonDecode(utf8.decode(base64Url.decode(
          envelope.substring(prefix.length)))) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final ephStr = env['e'];
    final ctStr = env['ct'];
    final kctStr = env['kct'];
    if (ephStr is! String || ctStr is! String) {
      return null;
    }
    // Protocol-version mismatch: v3s requires a KEM ciphertext and a
    // decapsulator; v2s must not carry one.
    if (isV3 && (kctStr is! String || pqDecapsFn == null)) return null;
    if (!isV3 && kctStr != null) return null;
    try {
      final ephPub = base64Decode(ephStr);
      if (ephPub.length != 32) return null;
      final shared = await dhFn(Uint8List.fromList(ephPub));
      final sharedBytes =
          Uint8List.fromList(await shared.extractBytes());
      var acc = 0;
      for (final b in sharedBytes) {
        acc |= b;
      }
      if (acc == 0) return null; // low-order sender ephemeral
      Uint8List sealInput = sharedBytes;
      if (isV3) {
        final kct = Uint8List.fromList(base64Decode(kctStr as String));
        if (kct.length != PqKemService.ciphertextBytes) return null;
        final ssPq = await pqDecapsFn!(kct);
        sealInput =
            await RatchetCore.deriveHybridRootKey(sharedBytes, ssPq);
        PqKemService.zero(ssPq);
      }
      final sealKey = await _sealKey(SecretKey(sealInput));
      final aad = isV3
          ? utf8.encode('v3s|$ephStr|$kctStr')
          : utf8.encode('v2s|$ephStr');
      final pt = await AesGcm.with256bits().decrypt(
        SecretBox.fromConcatenation(
          base64Decode(ctStr),
          nonceLength: 12,
          macLength: 16,
        ),
        secretKey: sealKey,
        aad: aad,
      );
      final inner = jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
      final sender = inner['s'];
      final sigStr = inner['sig'];
      final innerEnv = inner['m'];
      if (sender is! String || sigStr is! String || innerEnv is! String) {
        return null;
      }
      final ok = await verifyFn(
          sender, utf8.encode('$myId|$innerEnv'), sigStr);
      if (!ok) return null;
      return (senderId: sender, innerV2: innerEnv);
    } catch (_) {
      return null;
    }
  }

  static Future<SecretKey> _sealKey(SecretKey shared) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: shared,
      nonce: const <int>[],
      info: utf8.encode('vant-seal'),
    );
  }

  /// Unified intake: legacy XOR, `v2:`/`v2s:`, or `v3:`/`v3s:` envelope →
  /// payload map. Dispatch order v3s → v2s → v2/v3 → legacy XOR read-only.
  /// Returns null for malformed/undecryptable envelopes — callers skip.
  Future<DecryptedEnvelope?> decryptIncoming(
      {String? claimedSenderId, required String payload}) async {
    if (payload.startsWith(kV3sPrefix) || payload.startsWith(kV2sPrefix)) {
      return _openSealed(payload);
    }
    if (payload.startsWith(kV2Prefix) || payload.startsWith(kV3Prefix)) {
      final sender = claimedSenderId;
      if (sender == null) return null;
      return _openInner(sender, payload);
    }
    // Legacy XOR — read-only backward compatibility for history and
    // peers that haven't upgraded.
    return DecryptedEnvelope(
      senderId: claimedSenderId ?? '',
      payload: {'t': EncryptionService.decryptMessage(payload)},
    );
  }

  Future<DecryptedEnvelope?> _openInner(String sender, String envelope) {
    return _locked(sender, () async {
      final core = await _coreFor(sender,
          wantPostQuantum: envelope.startsWith(kV3Prefix));
      if (core == null) return null;
      final padded = await core.decrypt(envelope);
      await _persist(sender, core);
      if (padded == null) return null;
      final plain = unpadBucket(padded);
      RatchetCore._zero(padded);
      if (plain == null) return null;
      try {
        final map = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
        return DecryptedEnvelope(senderId: sender, payload: map);
      } catch (_) {
        return null;
      }
    });
  }

  Future<DecryptedEnvelope?> _openSealed(String envelope) async {
    final myId = _storage.deviceId;
    if (myId == null) return null;
    final opened = await openSealedEnvelope(
      envelope: envelope,
      myId: myId,
      dhFn: (ephPub) => _identity.identitySharedSecret(ephPub),
      verifyFn: (sender, message, sigB64) async {
        // Verify the Ed25519 sender signature against the pinned bundle.
        final bundle = _storage.getPeerBundle(sender);
        if (bundle == null) {
          debugPrint('⚠️ Sealed message from unpinned sender $sender');
          return false;
        }
        return _identity.verifyDomainSignature(
          domain: IdentityService.domainMsgSeal,
          peerBundleBase64: bundle,
          message: message,
          signatureBase64: sigB64,
        );
      },
      pqDecapsFn: (kemCt) async {
        final sk = _identity.mlkemSecretKey;
        if (sk == null) {
          throw StateError('no PQ identity for v3s open');
        }
        return PqKemService.decapsulate(kemCt, sk);
      },
    );
    if (opened == null) {
      debugPrint('⚠️ Sealed envelope open/verify failed');
      return null;
    }
    if (!opened.innerV2.startsWith(kV2Prefix) &&
        !opened.innerV2.startsWith(kV3Prefix)) {
      return null;
    }
    return _openInner(opened.senderId, opened.innerV2);
  }
}
