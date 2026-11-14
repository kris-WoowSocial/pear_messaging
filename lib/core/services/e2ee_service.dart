import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';

/// End-to-End Encryption Service
///
/// Implements real E2EE using:
/// - X25519 (ECDH) for per-contact key agreement
/// - HKDF-SHA256 to derive a 256-bit symmetric key from the shared secret
/// - AES-256-GCM for authenticated message encryption
///
/// Each device holds one long-lived X25519 keypair. The PRIVATE key never
/// leaves the device (stored in Keychain/Keystore via flutter_secure_storage).
/// The PUBLIC key is shared freely (via the relay server and attached to each
/// message), so a shared secret can be derived without any secret ever
/// touching the server.
///
/// Encrypted payload format (base64 after the "E2:" prefix):
///   [version(1)][nonce(12)][ciphertext][tag(16)]
///
/// Messages that do not start with "E2:" are treated as legacy (XOR) payloads
/// by the caller, so older clients and pre-upgrade messages keep working.
class E2EEService extends GetxService {
  static const String _privateKeyStorageKey = 'e2ee_x25519_private_v1';
  static const String _publicKeyStorageKey = 'e2ee_x25519_public_v1';
  static const String e2eePrefix = 'E2:';
  static const int _version = 1;
  static const int _nonceLength = 12;
  static const int _tagLength = 16;

  final X25519 _x25519 = X25519();
  final AesGcm _aesGcm = AesGcm.with256bits();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  late final FlutterSecureStorage _secureStorage;

  SimpleKeyPair? _keyPair;
  String? _myPublicKeyBase64;

  /// Cache of derived symmetric keys, keyed by the contact's public key (base64).
  /// Derivation is deterministic, so caching is purely a performance optimization.
  final Map<String, SecretKey> _derivedKeyCache = {};

  /// Cache of known contact public keys, keyed by deviceId.
  final Map<String, String> _contactPublicKeys = {};

  bool _initialized = false;

  String? get myPublicKeyBase64 => _myPublicKeyBase64;
  bool get isInitialized => _initialized;

  Future<E2EEService> init() async {
    _secureStorage = const FlutterSecureStorage(
      aOptions: AndroidOptions(
        encryptedSharedPreferences: true,
        keyCipherAlgorithm: KeyCipherAlgorithm.RSA_ECB_PKCS1Padding,
        storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
      ),
      iOptions: IOSOptions(
        accountName: 'PearMessagingE2EEKey',
        accessibility: KeychainAccessibility.unlocked_this_device,
      ),
    );
    await _loadOrCreateKeyPair();
    _initialized = true;
    debugPrint(
      '🔐 E2EEService initialized (publicKey: ${_myPublicKeyBase64?.substring(0, 12)}...)',
    );
    return this;
  }

  /// Load the device keypair from secure storage, or generate a new one.
  Future<void> _loadOrCreateKeyPair() async {
    try {
      final storedPrivate = await _secureStorage.read(
        key: _privateKeyStorageKey,
      );
      final storedPublic = await _secureStorage.read(key: _publicKeyStorageKey);

      if (storedPrivate != null && storedPublic != null) {
        final seed = base64Decode(storedPrivate);
        _keyPair = await _x25519.newKeyPairFromSeed(seed);
        _myPublicKeyBase64 = storedPublic;
        debugPrint('🔐 E2EE keypair loaded from secure storage');
        return;
      }

      await _generateAndStoreKeyPair();
    } catch (e) {
      debugPrint('❌ E2EE keypair load failed, regenerating: $e');
      await _generateAndStoreKeyPair();
    }
  }

  Future<void> _generateAndStoreKeyPair() async {
    final keyPair = await _x25519.newKeyPair();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    final publicBase64 = base64Encode(publicKey.bytes);

    await _secureStorage.write(
      key: _privateKeyStorageKey,
      value: base64Encode(privateBytes),
    );
    await _secureStorage.write(key: _publicKeyStorageKey, value: publicBase64);

    _keyPair = keyPair;
    _myPublicKeyBase64 = publicBase64;
    debugPrint('🔐 New E2EE keypair generated and stored');
  }

  /// Remember a contact's public key (learned from server or an inbound message).
  void cacheContactPublicKey(String deviceId, String? publicKeyBase64) {
    if (publicKeyBase64 == null || publicKeyBase64.isEmpty) return;
    _contactPublicKeys[deviceId] = publicKeyBase64;
  }

  /// Get a contact's known public key, if any.
  String? getContactPublicKey(String deviceId) => _contactPublicKeys[deviceId];

  bool hasContactKey(String deviceId) =>
      _contactPublicKeys[deviceId]?.isNotEmpty ?? false;

  /// Derive (and cache) the shared AES key for a given contact public key.
  Future<SecretKey> _deriveKey(String contactPublicKeyBase64) async {
    final cached = _derivedKeyCache[contactPublicKeyBase64];
    if (cached != null) return cached;

    if (_keyPair == null) {
      throw StateError('E2EEService not initialized');
    }

    final remotePublicKey = SimplePublicKey(
      base64Decode(contactPublicKeyBase64),
      type: KeyPairType.x25519,
    );

    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: _keyPair!,
      remotePublicKey: remotePublicKey,
    );

    // HKDF with a fixed app-specific info string for domain separation.
    final derived = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: const <int>[], // no salt; both sides must match
      info: utf8.encode('vant-chat-e2ee-v1'),
    );

    _derivedKeyCache[contactPublicKeyBase64] = derived;
    return derived;
  }

  /// Encrypt [plainText] for the contact identified by [contactPublicKeyBase64].
  /// Returns an "E2:"-prefixed base64 string. Throws if no public key.
  Future<String> encryptFor(
    String contactPublicKeyBase64,
    String plainText,
  ) async {
    final key = await _deriveKey(contactPublicKeyBase64);
    final nonce = _aesGcm.newNonce();
    final secretBox = await _aesGcm.encrypt(
      utf8.encode(plainText),
      secretKey: key,
      nonce: nonce,
    );

    final result = Uint8List(
      1 + _nonceLength + secretBox.cipherText.length + _tagLength,
    );
    result[0] = _version;
    result.setRange(1, 1 + _nonceLength, secretBox.nonce);
    result.setRange(
      1 + _nonceLength,
      1 + _nonceLength + secretBox.cipherText.length,
      secretBox.cipherText,
    );
    result.setRange(
      1 + _nonceLength + secretBox.cipherText.length,
      result.length,
      secretBox.mac.bytes,
    );

    return e2eePrefix + base64Encode(result);
  }

  /// Decrypt an "E2:"-prefixed payload using the sender's public key.
  Future<String> decryptFrom(
    String senderPublicKeyBase64,
    String payload,
  ) async {
    if (!payload.startsWith(e2eePrefix)) {
      throw ArgumentError('Not an E2EE payload');
    }
    final raw = base64Decode(payload.substring(e2eePrefix.length));
    if (raw.length < 1 + _nonceLength + _tagLength) {
      throw ArgumentError('E2EE payload too short');
    }
    if (raw[0] != _version) {
      throw ArgumentError('Unsupported E2EE version: ${raw[0]}');
    }

    final nonce = raw.sublist(1, 1 + _nonceLength);
    final cipherEnd = raw.length - _tagLength;
    final cipherText = raw.sublist(1 + _nonceLength, cipherEnd);
    final macBytes = raw.sublist(cipherEnd);

    final key = await _deriveKey(senderPublicKeyBase64);
    final clear = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes)),
      secretKey: key,
    );
    return utf8.decode(clear);
  }

  /// Whether the given payload is an E2EE payload.
  static bool isE2EEPayload(String? payload) =>
      payload != null && payload.startsWith(e2eePrefix);
}
