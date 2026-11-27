import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Safety code — the 60-digit "security number" both phones display during
/// contact verification (WhatsApp-style).
///
/// Deterministic and symmetric: both sides hash the same canonical input.
///   SHA-512("vant-verify" | idLow | bundleLow | idHigh | bundleHigh)
/// where (id, bundle) pairs are sorted by NUMERIC device id and bundles are
/// raw 65-byte wire values — never base64.
///
/// Post-quantum mode: when BOTH sides supply their verified ML-KEM-768
/// encapsulation key, each side's commitment becomes
///   SHA-256(deviceId | x25519Pub | ed25519Pub | mlKem768Pub)
/// and the pairwise hash runs over the two digests — the code then binds
/// the post-quantum identity keys too. Mixed peers fall back to the
/// classical formula so a v2s-only peer still matches.
///
/// Output: 12 chunks of 5 bytes each, each chunk interpreted big-endian and
/// reduced mod 100000, zero-padded to 5 digits → 60 digits total (~199 bits).
class SafetyCode {
  static const String domain = 'vant-verify';
  static const int chunks = 12;
  static const int chunkBytes = 5;
  static const int _pqPublicKeyBytes = 1184;

  /// Compute the 60-digit code for two peers. Returns null on malformed
  /// input — callers must handle, never throw.
  ///
  /// [pqPubA]/[pqPubB] are the sides' ML-KEM-768 public keys (1184B). The
  /// post-quantum commitment only engages when BOTH are present.
  static Future<String?> compute({
    required String idA,
    required String bundleA,
    required String idB,
    required String bundleB,
    Uint8List? pqPubA,
    Uint8List? pqPubB,
  }) async {
    final a = int.tryParse(idA);
    final b = int.tryParse(idB);
    if (a == null || b == null || a == b) return null;
    late final Uint8List rawA, rawB;
    try {
      rawA = base64Decode(bundleA);
      rawB = base64Decode(bundleB);
    } catch (_) {
      return null;
    }
    if (rawA.length != 65 || rawB.length != 65) return null;

    final aIsLow = a < b;
    final idLow = aIsLow ? idA : idB;
    final idHigh = aIsLow ? idB : idA;
    final bundleLow = aIsLow ? rawA : rawB;
    final bundleHigh = aIsLow ? rawB : rawA;

    final usePq = pqPubA != null &&
        pqPubB != null &&
        pqPubA.length == _pqPublicKeyBytes &&
        pqPubB.length == _pqPublicKeyBytes;

    final Uint8List input;
    if (usePq) {
      final pqLow = aIsLow ? pqPubA : pqPubB;
      final pqHigh = aIsLow ? pqPubB : pqPubA;
      final digestLow = await _pqCommitment(idLow, bundleLow, pqLow);
      final digestHigh = await _pqCommitment(idHigh, bundleHigh, pqHigh);
      input = (BytesBuilder()
            ..add(utf8.encode(domain))
            ..add(digestLow)
            ..add(digestHigh))
          .toBytes();
    } else {
      input = (BytesBuilder()
            ..add(utf8.encode(domain))
            ..add(utf8.encode(idLow))
            ..add(bundleLow)
            ..add(utf8.encode(idHigh))
            ..add(bundleHigh))
          .toBytes();
    }

    final digest = await Sha512().hash(input);
    final bytes = digest.bytes;
    if (bytes.length < chunks * chunkBytes) return null;

    final out = StringBuffer();
    for (var i = 0; i < chunks; i++) {
      var v = 0;
      for (var j = 0; j < chunkBytes; j++) {
        v = (v << 8) | bytes[i * chunkBytes + j];
      }
      out.write((v % 100000).toString().padLeft(5, '0'));
    }
    return out.toString();
  }

  /// Per-side post-quantum commitment: bundle layout is
  /// `[tag | x25519(32) | ed25519(32)]` — split it, then
  /// SHA-256(deviceId | x25519Pub | ed25519Pub | mlKem768Pub).
  static Future<Uint8List> _pqCommitment(
      String deviceId, Uint8List bundle, Uint8List pqPub) async {
    final d = await Sha256().hash((BytesBuilder()
          ..add(utf8.encode(deviceId))
          ..add(bundle.sublist(1, 33))
          ..add(bundle.sublist(33, 65))
          ..add(pqPub))
        .toBytes());
    return Uint8List.fromList(d.bytes);
  }

  /// Format a 60-digit code as 12 groups of 5 for display.
  static String formatGroups(String code) {
    final b = StringBuffer();
    for (var i = 0; i < code.length; i += 5) {
      if (i > 0) b.write('  ');
      b.write(code.substring(i, i + 5));
    }
    return b.toString();
  }
}
