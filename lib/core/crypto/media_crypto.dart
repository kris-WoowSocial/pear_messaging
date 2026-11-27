import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../services/encryption_service.dart';

/// Per-file media encryption for S3 blobs.
///
/// Every uploaded image / voice note / document gets a fresh random
/// 256-bit AES-GCM key and 12-byte nonce. The server only ever stores
/// `nonce || ciphertext || tag` — the key and a SHA-256 integrity digest
/// of that ciphertext travel inside the sealed `v3s:`/`v2s:` (or `v2g:`/
/// `v3g:`) message payload, so the relay can neither read nor tamper
/// with the media. Static-XOR blobs sent by older builds still decode
/// for history via [decryptBlob] when the ref carries no key material.
class MediaCrypto {
  MediaCrypto._();

  static final _aes = AesGcm.with256bits();
  static final _sha256 = Sha256();

  /// Wire prefix in the message payload for key-carrying media refs:
  /// `MEDIA:<token>|<keyB64>|<digestB64>` (same for FILE:/AUDIO:/IMAGE:).
  /// A bare `MEDIA:<token>` (no `|`) is a legacy XOR blob.
  static const String refSeparator = '|';

  /// Encrypt [plainBytes] for upload. Returns the opaque base64 blob to
  /// POST plus the key/digest that must be carried inside the sealed
  /// message payload — never in S3 metadata or plaintext socket fields.
  static Future<MediaEncryption> encryptBlob(Uint8List plainBytes) async {
    final key = await _aes.newSecretKey();
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      plainBytes,
      secretKey: key,
      nonce: nonce,
    );
    // concatenation() = nonce(12) || ciphertext || mac(16)
    final packed = box.concatenation();
    final digest = await _sha256.hash(packed);
    final keyBytes = await key.extractBytes();
    return MediaEncryption(
      blob: base64Encode(packed),
      key: base64Encode(keyBytes),
      digest: base64Encode(digest.bytes),
    );
  }

  /// Decrypt a downloaded blob. Verifies the SHA-256 digest of the
  /// ciphertext BEFORE opening the AEAD — a tampered/foreign blob is
  /// rejected before any plaintext is produced. Returns null when the
  /// blob is structurally invalid.
  static Future<Uint8List?> decryptBlob({
    required String blob,
    required String key,
    required String digest,
  }) async {
    try {
      final packed = Uint8List.fromList(base64Decode(blob));
      final expected = base64Decode(digest);
      final actual = await _sha256.hash(packed);
      if (!_constTimeEquals(actual.bytes, expected)) return null;
      final keyBytes = Uint8List.fromList(base64Decode(key));
      final plain = await _aes.decrypt(
        SecretBox.fromConcatenation(
          packed,
          nonceLength: 12,
          macLength: 16,
        ),
        secretKey: SecretKey(keyBytes),
      );
      return Uint8List.fromList(plain);
    } catch (_) {
      return null;
    }
  }

  /// Unified download decrypt: AES-256-GCM when [ref] carries key
  /// material, legacy XOR otherwise.
  static Future<Uint8List?> decryptForRef(String blob, MediaRef ref) {
    if (ref.hasKey) {
      return decryptBlob(blob: blob, key: ref.key!, digest: ref.digest!);
    }
    return Future.value(decryptLegacyBlob(blob));
  }

  /// Decrypt a legacy XOR blob sent by a pre-AES build. Used only for
  /// media that arrived without key material in the message payload.
  static Uint8List? decryptLegacyBlob(String blob) {
    try {
      return Uint8List.fromList(
          base64Decode(EncryptionService.decryptMessage(blob)));
    } catch (_) {
      return null;
    }
  }

  /// Extract a [MediaRef] from decrypted message content.
  /// Accepts `MEDIA:`/`IMAGE:`/`FILE:`/`AUDIO:` prefixes; returns null
  /// for non-media content or the `*:`/`pending` upload placeholder.
  static MediaRef? extractRef(String content) {
    String body;
    if (content.startsWith('MEDIA:')) {
      body = content.substring(6);
    } else if (content.startsWith('IMAGE:')) {
      body = content.substring(6);
    } else if (content.startsWith('FILE:')) {
      body = content.substring(5);
    } else if (content.startsWith('AUDIO:')) {
      body = content.substring(6);
    } else {
      return null;
    }
    if (body.isEmpty || body == 'pending') return null;
    final parts = body.split(refSeparator);
    final token = parts[0];
    if (token.isEmpty) return null;
    if (parts.length >= 3 &&
        parts[1].isNotEmpty &&
        parts[2].isNotEmpty) {
      return MediaRef(token: token, key: parts[1], digest: parts[2]);
    }
    return MediaRef(token: token);
  }

  /// Raw S3 token inside [content] (no key material) — used for server
  /// lifecycle tracking fields where only the token may appear.
  static String? tokenFromContent(String content) =>
      extractRef(content)?.token;

  static bool _constTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Result of [MediaCrypto.encryptBlob].
class MediaEncryption {
  MediaEncryption({
    required this.blob,
    required this.key,
    required this.digest,
  });

  /// base64(nonce || ciphertext || tag) — uploaded to S3.
  final String blob;

  /// base64(32-byte AES-256-GCM key) — sealed payload only.
  final String key;

  /// base64(SHA-256 of the packed blob) — sealed payload only.
  final String digest;

  /// `token|key|digest` for the message payload's media prefix.
  String refFor(String token) => '$token${MediaCrypto.refSeparator}$key'
      '${MediaCrypto.refSeparator}$digest';
}

/// Parsed media reference from decrypted message content.
class MediaRef {
  MediaRef({required this.token, this.key, this.digest});

  final String token;

  /// Present only for new AES-GCM blobs; null means legacy XOR.
  final String? key;
  final String? digest;

  bool get hasKey => key != null && digest != null;

  /// Full `token|key|digest` wire form (legacy refs encode bare token).
  String encode() => hasKey
      ? '$token${MediaCrypto.refSeparator}$key'
          '${MediaCrypto.refSeparator}$digest'
      : token;
}
