import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../crypto/pq_kem_service.dart';

/// Identity Service — per-device cryptographic identity for E2EE calls/messages.
///
/// Each device holds an X25519 key pair (key agreement) and an Ed25519 key pair
/// (signing). The public halves are published as an "identity bundle" which
/// contacts pin (TOFU) or verify out-of-band (QR). Private keys live only in
/// platform secure storage and are never exported, logged, or sent.
///
/// Lifecycle rule (item 13): the deviceId in SharedPreferences and the identity
/// keys in secure storage must exist together. If the ID survived but the keys
/// did not (e.g. iOS Keychain wipe with prefs intact), the device can no longer
/// prove ownership of the ID — [requiresNewDeviceId] is set so the caller can
/// route to the new-ID flow instead of silently generating mismatched keys.
/// Outcome of the secure-storage read at startup.
enum IdentityStorageState { loading, loaded, missing, unreadable }

class IdentityService extends GetxService {
  // Secure storage keys — kept separate from SecureKeyService (which uses a
  // different account name and default accessibility).
  static const String _kX25519Private = 'vant_identity_x25519_sk';
  static const String _kEd25519Private = 'vant_identity_ed25519_sk';
  static const String _kIdentityBundle = 'vant_identity_bundle';
  static const String _kMlKemPublic = 'vant_identity_mlkem768_pub';
  static const String _kMlKemPrivate = 'vant_identity_mlkem768_sk';

  /// Flag in SharedPreferences (NOT secure storage) so we can tell
  /// "never generated" from "generated then lost".
  static const String _prefsIdentityInitialized = 'identity_initialized';
  static const String _prefsCapabilitySeq = 'identity_capability_seq';

  /// Bundle wire format (65 bytes):
  ///   [version:1][x25519 public:32][ed25519 public:32]
  static const int bundleVersion = 1;
  static const int bundleLength = 65;

  // Signature domains — a signature made for one purpose is invalid for any
  // other. deviceId inside the payload blocks cross-ID replay.
  static const String domainBind = 'vant-bind';
  static const String domainRegister = 'vant-reg';
  static const String domainAnnounce = 'vant-announce';
  static const String domainCapabilities = 'vant-caps';
  static const String domainCall = 'vant-call';
  static const String domainCallFingerprintCaller = 'vant-call-fp-caller';
  static const String domainCallFingerprintCallee = 'vant-call-fp-callee';
  static const String domainMsgSeal = 'vant-msg';
  static const String domainPqKey = 'vant-pqkey';
  static const Set<String> signingDomainAllowList = {
    domainCapabilities,
    domainCallFingerprintCaller,
    domainCallFingerprintCallee,
    domainMsgSeal,
    domainPqKey,
  };

  /// Canonical domain-bound signing bytes: 4-byte domain length, domain, then
  /// the caller's already-framed message bytes.
  static Uint8List domainBoundMessage(String domain, List<int> message) {
    final domainBytes = utf8.encode(domain);
    final b = BytesBuilder()
      ..add([
        (domainBytes.length >> 24) & 0xff,
        (domainBytes.length >> 16) & 0xff,
        (domainBytes.length >> 8) & 0xff,
        domainBytes.length & 0xff,
      ])
      ..add(domainBytes)
      ..add(message);
    return b.toBytes();
  }

  /// Secure storage dedicated to identity keys. iOS accessibility is
  /// first_unlock_this_device: readable while locked after first unlock
  /// (required for answering calls from a locked phone / killed app) and
  /// excluded from backups and device transfers.
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      keyCipherAlgorithm: KeyCipherAlgorithm.RSA_ECB_PKCS1Padding,
      storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
      // Never wipe stored keys on a decrypt error — a wiped key looks like
      // "missing" and would wrongly mint a new device ID.
      resetOnError: false,
    ),
    iOptions: IOSOptions(
      accountName: 'VantIdentityKeys',
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );

  final X25519 _x25519 = X25519();
  final Ed25519 _ed25519 = Ed25519();

  // In-memory private key pairs. Loaded lazily; never logged or serialized out.
  KeyPair? _x25519KeyPair;
  KeyPair? _ed25519KeyPair;

  // Long-term ML-KEM-768 post-quantum identity (FIPS 203).
  Uint8List? _mlkemPublicKey; // 1184B encapsulation key
  Uint8List? _mlkemSecretKey; // 2400B decapsulation key

  /// Public identity bundle (65 bytes) as base64 — safe to transmit.
  String? _bundleBase64;
  Uint8List? _bundleBytes;

  /// True when this device has valid identity material.
  final RxBool hasIdentity = false.obs;

  /// True when the deviceId survived but its identity keys did not — the
  /// server-side binding can no longer be proven and the caller must route to
  /// the new-ID flow.
  final RxBool requiresNewDeviceId = false.obs;

  /// Three-state outcome of the secure-storage read:
  ///  - [IdentityStorageState.loaded] — keys read and bundle verified
  ///  - [IdentityStorageState.missing] — reads SUCCEEDED, keys absent (orphan)
  ///  - [IdentityStorageState.unreadable] — read threw / data corrupt:
  ///    surface an error, NEVER mint a new ID for this state
  final Rx<IdentityStorageState> storageState =
      IdentityStorageState.loading.obs;

  Future<IdentityService> init() async {
    await _loadOrDetectOrphan();
    return this;
  }

  // ---------------------------------------------------------------------------
  // Key material
  // ---------------------------------------------------------------------------

  Future<void> _loadOrDetectOrphan() async {
    final prefs = await SharedPreferences.getInstance();
    final deviceId = prefs.getString('device_id');
    final wasInitialized = prefs.getBool(_prefsIdentityInitialized) ?? false;

    String? xPrivB64, ePrivB64, bundleB64;
    try {
      xPrivB64 = await _storage.read(key: _kX25519Private);
      ePrivB64 = await _storage.read(key: _kEd25519Private);
      bundleB64 = await _storage.read(key: _kIdentityBundle);
    } catch (e) {
      // Read FAILED (keystore/keychain error, backup-restore corruption).
      // This is NOT "missing" — keys may still exist. Never mint a new ID.
      debugPrint('❌ IdentityService: secure storage read failed: $e');
      storageState.value = IdentityStorageState.unreadable;
      hasIdentity.value = false;
      requiresNewDeviceId.value = false;
      return;
    }

    final allPresent =
        xPrivB64 != null && ePrivB64 != null && bundleB64 != null;
    final allAbsent = xPrivB64 == null && ePrivB64 == null && bundleB64 == null;

    if (allPresent) {
      final ok = await _loadKeys(xPrivB64!, ePrivB64!, bundleB64!);
      if (!ok) {
        // Stored bundle doesn't match the seeds, or data is corrupt — treat
        // as unreadable rather than trusting it.
        storageState.value = IdentityStorageState.unreadable;
        hasIdentity.value = false;
        return;
      }
      await _loadOrMigratePqIdentity();
      storageState.value = IdentityStorageState.loaded;
      hasIdentity.value = true;
      return;
    }

    if (!allAbsent) {
      // Partial key material = corrupt state — unreadable, never auto-heal.
      debugPrint('⚠️ IdentityService: partial identity material found');
      storageState.value = IdentityStorageState.unreadable;
      hasIdentity.value = false;
      return;
    }

    if (deviceId != null && wasInitialized) {
      // ID + flag survived but key material is confirmed ABSENT (reads
      // succeeded and returned nothing) — orphaned.
      debugPrint(
        '⚠️ IdentityService: deviceId exists but identity keys are missing — '
        'cannot prove ownership of this ID',
      );
      storageState.value = IdentityStorageState.missing;
      requiresNewDeviceId.value = true;
      hasIdentity.value = false;
      return;
    }

    // Fresh install or first launch after the identity feature shipped.
    await _generateAndStoreIdentity();
    storageState.value = IdentityStorageState.loaded;
  }

  /// Load key pairs and verify the stored bundle byte-matches the public
  /// keys derived from the seeds. Returns false on any mismatch/corruption.
  Future<bool> _loadKeys(
      String xPrivB64, String ePrivB64, String bundleB64) async {
    try {
      final xPriv = base64Decode(xPrivB64);
      final ePriv = base64Decode(ePrivB64);
      final storedBundle = base64Decode(bundleB64);

      _x25519KeyPair = await _x25519.newKeyPairFromSeed(xPriv);
      _ed25519KeyPair = await _ed25519.newKeyPairFromSeed(ePriv);

      // Derive public keys from the seeds and compare — never trust the
      // stored bundle on its own.
      final xData = await _x25519KeyPair!.extract() as SimpleKeyPairData;
      final eData = await _ed25519KeyPair!.extract() as SimpleKeyPairData;
      final derived = Uint8List.fromList(
        [bundleVersion, ...xData.publicKey.bytes, ...eData.publicKey.bytes],
      );
      if (storedBundle.length != derived.length) return false;
      for (var i = 0; i < derived.length; i++) {
        if (storedBundle[i] != derived[i]) {
          debugPrint('❌ IdentityService: stored bundle does not match seeds');
          return false;
        }
      }

      _bundleBytes = storedBundle;
      _bundleBase64 = bundleB64;
      return true;
    } catch (e) {
      debugPrint('❌ IdentityService: key load failed: $e');
      return false;
    }
  }

  Future<void> _generateAndStoreIdentity() async {
    final prefs = await SharedPreferences.getInstance();

    _x25519KeyPair = await _x25519.newKeyPair();
    _ed25519KeyPair = await _ed25519.newKeyPair();

    // SimpleKeyPairData exposes .bytes (private) and .publicKey (.bytes).
    final xData = await _x25519KeyPair!.extract() as SimpleKeyPairData;
    final eData = await _ed25519KeyPair!.extract() as SimpleKeyPairData;
    final xPriv = xData.bytes;
    final ePriv = eData.bytes;
    final xPub = xData.publicKey;
    final ePub = eData.publicKey;

    _bundleBytes = Uint8List.fromList(
      [bundleVersion, ...xPub.bytes, ...ePub.bytes],
    );
    _bundleBase64 = base64Encode(_bundleBytes!);

    await _storage.write(key: _kX25519Private, value: base64Encode(xPriv));
    await _storage.write(key: _kEd25519Private, value: base64Encode(ePriv));
    await _storage.write(key: _kIdentityBundle, value: _bundleBase64);
    await prefs.setBool(_prefsIdentityInitialized, true);

    await _generateAndStorePqIdentity();

    hasIdentity.value = true;
    requiresNewDeviceId.value = false;
  }

  /// Long-term ML-KEM-768 identity — generated alongside the classical keys
  /// on fresh installs and lazily migrated on upgrade for existing installs.
  /// PQ material missing while the classical identity is intact is NOT an
  /// unreadable state: it just means the install predates PQ support.
  Future<void> _loadOrMigratePqIdentity() async {
    try {
      final pubB64 = await _storage.read(key: _kMlKemPublic);
      final skB64 = await _storage.read(key: _kMlKemPrivate);
      if (pubB64 != null && skB64 != null) {
        final pub = base64Decode(pubB64);
        final sk = base64Decode(skB64);
        if (pub.length == PqKemService.publicKeyBytes &&
            sk.length == PqKemService.secretKeyBytes) {
          _mlkemPublicKey = Uint8List.fromList(pub);
          _mlkemSecretKey = Uint8List.fromList(sk);
          return;
        }
        debugPrint('⚠️ IdentityService: corrupt ML-KEM keys — regenerating');
      }
      // Missing or partial → (re)generate the pair. The PQ key is certified
      // by the Ed25519 identity key at announce time, so regenerating here is
      // safe even if only one half survived.
      await _generateAndStorePqIdentity();
    } catch (e) {
      // Read failure is non-fatal: PQ capability simply stays unannounced.
      debugPrint('⚠️ IdentityService: ML-KEM load failed: $e');
    }
  }

  Future<void> _generateAndStorePqIdentity() async {
    final kp = await PqKemService.generateKeyPair();
    _mlkemPublicKey = kp.publicKey;
    _mlkemSecretKey = kp.secretKey;
    await _storage.write(
        key: _kMlKemPublic, value: base64Encode(kp.publicKey));
    await _storage.write(
        key: _kMlKemPrivate, value: base64Encode(kp.secretKey));
  }

  /// Generates a brand-new identity AND signals the caller to mint a new
  /// deviceId. Called from the new-ID flow after [requiresNewDeviceId] fired.
  Future<void> regenerateIdentity() async {
    await _storage.delete(key: _kX25519Private);
    await _storage.delete(key: _kEd25519Private);
    await _storage.delete(key: _kIdentityBundle);
    await _storage.delete(key: _kMlKemPublic);
    await _storage.delete(key: _kMlKemPrivate);
    _mlkemPublicKey = null;
    _mlkemSecretKey = null;
    await _generateAndStoreIdentity();
  }

  // ---------------------------------------------------------------------------
  // Public accessors (public material only)
  // ---------------------------------------------------------------------------

  /// Base64 identity bundle — safe to send in `register`/`identityBundle`.
  String? get identityBundleBase64 => _bundleBase64;

  /// Raw 65-byte bundle.
  Uint8List? get identityBundle =>
      _bundleBytes == null ? null : Uint8List.fromList(_bundleBytes!);

  /// Operations for crypto subsystems — the KeyPair objects never leave
  /// this service. Both throw [IdentityUnavailableException] when keys are
  /// absent (unreadable/degraded storage) instead of a null crash.
  Future<SecretKey> x25519SharedSecret(List<int> peerPublicKey) async {
    final kp = _x25519KeyPair;
    if (kp == null) {
      throw const IdentityUnavailableException();
    }
    return _x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
    );
  }

  /// Ed25519-sign a payload with the identity key.
  Future<Uint8List> signBytes(String domain, List<int> message) async {
    if (!signingDomainAllowList.contains(domain)) {
      throw ArgumentError.value(domain, 'domain', 'unsupported signing domain');
    }
    final kp = _ed25519KeyPair;
    if (kp == null) {
      throw const IdentityUnavailableException();
    }
    final sig = await _ed25519.sign(
      domainBoundMessage(domain, message),
      keyPair: kp,
    );
    return Uint8List.fromList(sig.bytes);
  }

  /// Parse a peer bundle: [version][x25519 pub][ed25519 pub].
  /// Returns null on malformed input — callers must handle, never throw.
  static ({Uint8List x25519Pub, Uint8List ed25519Pub})? parseBundle(
      String bundleBase64) {
    try {
      final bytes = base64Decode(bundleBase64);
      if (bytes.length != bundleLength || bytes[0] != bundleVersion) {
        return null;
      }
      return (
        x25519Pub: Uint8List.fromList(bytes.sublist(1, 33)),
        ed25519Pub: Uint8List.fromList(bytes.sublist(33, 65)),
      );
    } catch (_) {
      return null;
    }
  }

  /// Canonical capability list for the signed announcement. Ordering and
  /// validation must match the server verifier exactly.
  static List<String> canonicalCapabilities(Iterable<String>? capabilities) {
    final values = <String>{};
    for (final capability in capabilities ?? const <String>[]) {
      final normalized = capability.trim().toLowerCase();
      if (normalized.isEmpty || normalized.length > 64) continue;
      if (!RegExp(r'^[a-z0-9_.:-]+$').hasMatch(normalized)) continue;
      values.add(normalized);
      if (values.length >= 16) break;
    }
    return values.toList()..sort();
  }

  /// Length-prefixed target, unsigned 64-bit sequence, then length-prefixed
  /// capabilities. Binding the target blocks a signed announcement made for
  /// one contact from being replayed to another contact.
  static Uint8List capabilityMaterial(
    String targetDeviceId,
    int sequence,
    Iterable<String> capabilities,
  ) {
    final targetBytes = utf8.encode(targetDeviceId);
    if (targetBytes.isEmpty || targetBytes.length > 0xffff || sequence < 0) {
      return Uint8List(0);
    }
    final sequenceBytes = Uint8List(8);
    ByteData.view(sequenceBytes.buffer).setUint64(0, sequence);
    final material = BytesBuilder()
      ..add([(targetBytes.length >> 8) & 0xff, targetBytes.length & 0xff])
      ..add(targetBytes)
      ..add(sequenceBytes);
    for (final capability in canonicalCapabilities(capabilities)) {
      final encoded = utf8.encode(capability);
      material.add([(encoded.length >> 8) & 0xff, encoded.length & 0xff]);
      material.add(encoded);
    }
    return material.toBytes();
  }

  /// Next signed capability sequence. Persisted so reconnects and app
  /// restarts always announce a value newer than every previous one.
  Future<int> nextCapabilitySequence() async {
    final prefs = await SharedPreferences.getInstance();
    final next = (prefs.getInt(_prefsCapabilitySeq) ?? 0) + 1;
    await prefs.setInt(_prefsCapabilitySeq, next);
    return next;
  }

  // ---------------------------------------------------------------------------
  // Signing — private keys never leave this service
  // ---------------------------------------------------------------------------

  Uint8List _payload(String domain, String deviceId,
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

  Future<String?> _sign(List<int> payload) async {
    if (_ed25519KeyPair == null) return null;
    final sig = await _ed25519.sign(payload, keyPair: _ed25519KeyPair!);
    return base64Encode(sig.bytes);
  }

  /// Binding proof-of-possession: Ed25519("vant-bind"|deviceId|bundle|nonce).
  Future<String?> signBinding(String deviceId, String nonce) {
    if (_bundleBytes == null) return Future.value(null);
    return _sign(_payload(domainBind, deviceId, _bundleBytes!, nonce));
  }

  /// Register/login signature: Ed25519("vant-reg"|deviceId|nonce).
  Future<String?> signRegistration(String deviceId, String nonce) {
    return _sign(_payload(domainRegister, deviceId, const [], nonce));
  }

  /// Self-signed announcement: Ed25519("vant-announce"|deviceId|bundle).
  /// Recipients verify this before pinning.
  Future<String?> signAnnouncement(String deviceId) {
    if (_bundleBytes == null) return Future.value(null);
    return _sign(_payload(domainAnnounce, deviceId, _bundleBytes!));
  }

  /// Signed call-capability announcement:
  /// Ed25519("vant-caps"|deviceId|targetId|sequence|capabilities).
  Future<String?> signCapabilities(
    String deviceId,
    String targetDeviceId,
    int sequence,
    Iterable<String> capabilities,
  ) {
    if (targetDeviceId.isEmpty || sequence < 0) return Future.value(null);
    return _sign(
      _payload(
        domainCapabilities,
        deviceId,
        capabilityMaterial(targetDeviceId, sequence, capabilities),
      ),
    );
  }

  /// Per-call signing: Ed25519("vant-call"|deviceId|material).
  Future<String?> signCallMaterial(String deviceId, List<int> material) {
    return _sign(_payload(domainCall, deviceId, material));
  }

  /// Verify an announcement signature against a claimed bundle + sender ID.
  /// Used before pinning a bundle received over the (untrusted) socket.
  Future<bool> verifyAnnouncement({
    required String senderDeviceId,
    required String bundleBase64,
    required String signatureBase64,
  }) async {
    final parsed = parseBundle(bundleBase64);
    if (parsed == null) return false;
    try {
      final bundleBytes = base64Decode(bundleBase64);
      final payload = _payload(domainAnnounce, senderDeviceId, bundleBytes);
      return await _ed25519.verify(
        payload,
        signature: Signature(
          base64Decode(signatureBase64),
          publicKey:
              SimplePublicKey(parsed.ed25519Pub, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Verify a signed capability announcement against the Ed25519 key inside
  /// the announced identity bundle. The caller still applies the monotonic
  /// sequence check before updating stored capability state.
  Future<bool> verifyCapabilities({
    required String senderDeviceId,
    required String targetDeviceId,
    required String bundleBase64,
    required int sequence,
    required Iterable<String> capabilities,
    required String signatureBase64,
  }) async {
    if (targetDeviceId.isEmpty || sequence < 0) return false;
    final parsed = parseBundle(bundleBase64);
    if (parsed == null) return false;
    try {
      final payload = _payload(
        domainCapabilities,
        senderDeviceId,
        capabilityMaterial(targetDeviceId, sequence, capabilities),
      );
      return await _ed25519.verify(
        payload,
        signature: Signature(
          base64Decode(signatureBase64),
          publicKey:
              SimplePublicKey(parsed.ed25519Pub, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Verify a domain-bound signature against the Ed25519 key inside a
  /// claimed peer bundle. Used by sealed-sender verification — the message
  /// bytes must already be framed by the caller (recipient binding included).
  Future<bool> verifyDomainSignature({
    required String domain,
    required String peerBundleBase64,
    required List<int> message,
    required String signatureBase64,
  }) async {
    if (!signingDomainAllowList.contains(domain)) return false;
    final parsed = parseBundle(peerBundleBase64);
    if (parsed == null) return false;
    try {
      return await _ed25519.verify(
        domainBoundMessage(domain, message),
        signature: Signature(
          base64Decode(signatureBase64),
          publicKey:
              SimplePublicKey(parsed.ed25519Pub, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Verify a peer's call signature: Ed25519("vant-call"|peerId|material)
  /// against the ed25519 key inside their pinned bundle.
  Future<bool> verifyCallSignature({
    required String peerDeviceId,
    required String peerBundleBase64,
    required List<int> material,
    required String signatureBase64,
  }) async {
    final parsed = parseBundle(peerBundleBase64);
    if (parsed == null) return false;
    try {
      final payload = _payload(domainCall, peerDeviceId, material);
      return await _ed25519.verify(
        payload,
        signature: Signature(
          base64Decode(signatureBase64),
          publicKey:
              SimplePublicKey(parsed.ed25519Pub, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Ephemeral X25519 for per-call key agreement (Phase 2 uses this)
  // ---------------------------------------------------------------------------

  /// Generate an ephemeral X25519 pair for one call. Caller must discard it
  /// when the call ends.
  Future<KeyPair> generateEphemeralKeyPair() => _x25519.newKeyPair();

  /// X25519 shared secret with a peer's ephemeral/identity public key.
  Future<SecretKey> sharedSecret({
    required KeyPair myKeyPair,
    required Uint8List peerPublicKey,
  }) {
    return _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
    );
  }

  /// Long-lived identity X25519 shared secret against a peer's public key.
  /// The private pair is never exposed — only this operation.
  Future<SecretKey> identitySharedSecret(Uint8List peerPublicKey) {
    if (_x25519KeyPair == null) {
      throw StateError('identity keys not loaded');
    }
    return sharedSecret(
      myKeyPair: _x25519KeyPair!,
      peerPublicKey: peerPublicKey,
    );
  }

  /// Our ML-KEM-768 encapsulation key (1184B) — safe to transmit once
  /// signed under the Ed25519 identity key.
  Uint8List? get mlkemPublicKey =>
      _mlkemPublicKey == null ? null : Uint8List.fromList(_mlkemPublicKey!);

  /// Our ML-KEM-768 decapsulation key (2400B) — stays in-process for
  /// inbound epoch decapsulation; never serialized out of this service.
  Uint8List? get mlkemSecretKey =>
      _mlkemSecretKey == null ? null : Uint8List.fromList(_mlkemSecretKey!);

  /// True when the long-term post-quantum identity is available — gates the
  /// `pq_mlkem768` capability announcement.
  bool get hasPqIdentity =>
      _mlkemPublicKey != null && _mlkemSecretKey != null;

  /// Ed25519 signature certifying our ML-KEM-768 public key:
  /// domainBoundMessage(domainPqKey, deviceId || pqPublicKey).
  /// Peers verify it against the ed25519 half of our pinned identity bundle.
  Future<Uint8List?> signPqKey(String deviceId) async {
    final pub = _mlkemPublicKey;
    if (pub == null) return null;
    final message = BytesBuilder()
      ..add(utf8.encode(deviceId))
      ..add(pub);
    return signBytes(domainPqKey, message.toBytes());
  }

  /// Verify a peer's ML-KEM-768 key certification against the Ed25519 key in
  /// their pinned identity bundle. [pqPublicKeyB64] must decode to exactly
  /// [PqKemService.publicKeyBytes] bytes.
  Future<bool> verifyPeerPqKey({
    required String peerDeviceId,
    required String peerBundleBase64,
    required String pqPublicKeyB64,
    required String signatureBase64,
  }) async {
    try {
      final pub = base64Decode(pqPublicKeyB64);
      if (pub.length != PqKemService.publicKeyBytes) return false;
      var acc = 0;
      for (final b in pub) {
        acc |= b;
      }
      if (acc == 0) return false; // zero key
      final message = BytesBuilder()
        ..add(utf8.encode(peerDeviceId))
        ..add(pub);
      return await verifyDomainSignature(
        domain: domainPqKey,
        peerBundleBase64: peerBundleBase64,
        message: message.toBytes(),
        signatureBase64: signatureBase64,
      );
    } catch (_) {
      return false;
    }
  }

  /// Only these server rejections may trigger the new-ID recovery flow —
  /// and only after a user confirmation. Everything else (missing_challenge,
  /// rate_limited, bad_*_signature, identity_unavailable, ...) must leave
  /// the device ID untouched.
  static bool shouldTriggerIdentityRecovery(String? reason) =>
      reason == 'identity_required' || reason == 'identity_conflict';

  /// Debug metadata — key bytes are never returned.
  Map<String, dynamic> describe() => {
        'hasIdentity': hasIdentity.value,
        'requiresNewDeviceId': requiresNewDeviceId.value,
        'bundleVersion': bundleVersion,
      };
}

/// Thrown when identity operations are invoked with no usable keys
/// (unreadable or degraded secure storage). Callers must fail closed.
class IdentityUnavailableException implements Exception {
  const IdentityUnavailableException();
  @override
  String toString() => 'IdentityUnavailableException: keys unavailable';
}
