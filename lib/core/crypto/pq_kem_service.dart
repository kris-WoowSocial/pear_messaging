import 'dart:typed_data';

import 'package:cipherlib/cipherlib.dart';

/// ML-KEM-768 (NIST FIPS 203) key-encapsulation primitive.
///
/// Backend note: the original design called for `mlkem_native` (C/assembly
/// via Dart native-assets hooks). That package requires Dart >=3.8.1 and this
/// project ships on Dart 3.6 / Flutter 3.27, so per spec we fall back to the
/// pure-Dart FIPS 203 implementation in `cipherlib` (reference-ported from
/// pq-crystals/kyber with the §7.2 modulus check and §implicit-rejection
/// semantics intact).
///
/// Pure Dart cannot guarantee constant-time execution — acceptable for the
/// KEM path here because the decapsulation key lives alongside the identity
/// keys and the shared secret is further mixed into the hybrid root key.
class PqKemService {
  PqKemService._();

  static const int publicKeyBytes = 1184;
  static const int secretKeyBytes = 2400;
  static const int ciphertextBytes = 1088;
  static const int sharedSecretBytes = 32;

  static final MLKEM _kem = MLKEM.kem768();

  /// Fresh ML-KEM-768 keypair: `publicKey` (ek, 1184B) + `secretKey`
  /// (dk, 2400B). The dk is in FIPS 203 expanded form — store it whole.
  static Future<PqKeyPair> generateKeyPair() async {
    final kp = _kem.keygen();
    return PqKeyPair(
      publicKey: Uint8List.fromList(kp.encapsulationKey),
      secretKey: Uint8List.fromList(kp.decapsulationKey),
    );
  }

  /// Encapsulate to a peer's 1184-byte encapsulation key.
  /// Throws ArgumentError on malformed/zero keys (the all-zero ek fails
  /// the FIPS 203 §7.2 modulus check inside the library as well, but we
  /// reject it up-front to keep the error deterministic).
  static Future<PqEncapsulation> encapsulate(
      Uint8List peerMlKemPublicKey) async {
    if (peerMlKemPublicKey.length != publicKeyBytes) {
      throw ArgumentError.value(
        peerMlKemPublicKey.length,
        'peerMlKemPublicKey',
        'must be $publicKeyBytes bytes',
      );
    }
    var acc = 0;
    for (final b in peerMlKemPublicKey) {
      acc |= b;
    }
    if (acc == 0) {
      throw ArgumentError.value(
          peerMlKemPublicKey, 'peerMlKemPublicKey', 'zero key rejected');
    }
    final secret = _kem.encaps(peerMlKemPublicKey);
    return PqEncapsulation(
      ciphertext: Uint8List.fromList(secret.cipherText),
      sharedSecret: Uint8List.fromList(secret.sharedSecret.bytes),
    );
  }

  /// Decapsulate a 1088-byte ciphertext with our 2400-byte secret key.
  /// Per FIPS 203 implicit rejection a well-formed but foreign ciphertext
  /// yields a pseudo-random secret (never throws) — callers detect the
  /// mismatch downstream via AEAD authentication failure.
  static Future<Uint8List> decapsulate(
      Uint8List ciphertext, Uint8List myMlKemSecretKey) async {
    if (ciphertext.length != ciphertextBytes) {
      throw ArgumentError.value(
          ciphertext.length, 'ciphertext', 'must be $ciphertextBytes bytes');
    }
    if (myMlKemSecretKey.length != secretKeyBytes) {
      throw ArgumentError.value(
          myMlKemSecretKey.length, 'myMlKemSecretKey', 'must be $secretKeyBytes bytes');
    }
    final ss = _kem.decaps(myMlKemSecretKey, ciphertext);
    return Uint8List.fromList(ss.bytes);
  }

  /// Overwrite a sensitive buffer in place.
  static void zero(Uint8List bytes) => bytes.fillRange(0, bytes.length, 0);
}

/// ML-KEM-768 keypair (FIPS 203 ek/dk form).
class PqKeyPair {
  PqKeyPair({required this.publicKey, required this.secretKey});

  final Uint8List publicKey; // encapsulation key, 1184B
  final Uint8List secretKey; // decapsulation key, 2400B
}

/// Result of `encapsulate`: the 1088-byte ciphertext travels in the `v3s:`
/// header; the 32-byte shared secret feeds the hybrid root-key combiner.
class PqEncapsulation {
  PqEncapsulation({required this.ciphertext, required this.sharedSecret});

  final Uint8List ciphertext; // 1088B
  final Uint8List sharedSecret; // 32B
}
