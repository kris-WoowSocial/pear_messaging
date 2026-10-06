import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Flag in SharedPreferences (NOT secure storage) so we can tell
  /// "never generated" from "generated then lost".
  static const String _prefsIdentityInitialized = 'identity_initialized';

  /// Bundle wire format (65 bytes):
  ///   [version:1][x25519 public:32][ed25519 public:32]
  static const int bundleVersion = 1;
  static const int bundleLength = 65;

  // Signature domains — a signature made for one purpose is invalid for any
  // other. deviceId inside the payload blocks cross-ID replay.
  static const String domainBind = 'vant-bind';
  static const String domainRegister = 'vant-reg';
  static const String domainAnnounce = 'vant-announce';
  static const String domainCall = 'vant-call';

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
    final allAbsent =
        xPrivB64 == null && ePrivB64 == null && bundleB64 == null;

    if (allPresent) {
      final ok = await _loadKeys(xPrivB64!, ePrivB64!, bundleB64!);
      if (!ok) {
        // Stored bundle doesn't match the seeds, or data is corrupt — treat
        // as unreadable rather than trusting it.
        storageState.value = IdentityStorageState.unreadable;
        hasIdentity.value = false;
        return;
      }
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
  Future<bool> _loadKeys(String xPrivB64, String ePrivB64, String bundleB64) async {
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

    hasIdentity.value = true;
    requiresNewDeviceId.value = false;
  }

  /// Generates a brand-new identity AND signals the caller to mint a new
  /// deviceId. Called from the new-ID flow after [requiresNewDeviceId] fired.
  Future<void> regenerateIdentity() async {
    await _storage.delete(key: _kX25519Private);
    await _storage.delete(key: _kEd25519Private);
    await _storage.delete(key: _kIdentityBundle);
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

  /// Internal accessors for crypto subsystems (call signaling, message
  /// encryption). The KeyPair objects stay in-process — never serialize or
  /// transmit them.
  KeyPair? get internalX25519KeyPair => _x25519KeyPair;
  KeyPair? get internalEd25519KeyPair => _ed25519KeyPair;

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
          publicKey: SimplePublicKey(parsed.ed25519Pub,
              type: KeyPairType.ed25519),
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
          publicKey: SimplePublicKey(parsed.ed25519Pub,
              type: KeyPairType.ed25519),
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
      remotePublicKey:
          SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
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
