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
/// Output: 12 chunks of 5 bytes each, each chunk interpreted big-endian and
/// reduced mod 100000, zero-padded to 5 digits → 60 digits total (~199 bits).
class SafetyCode {
  static const String domain = 'vant-verify';
  static const int chunks = 12;
  static const int chunkBytes = 5;

  /// Compute the 60-digit code for two peers. Returns null on malformed
  /// input — callers must handle, never throw.
  static Future<String?> compute({
    required String idA,
    required String bundleA,
    required String idB,
    required String bundleB,
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

    final input = BytesBuilder()
      ..add(utf8.encode(domain))
      ..add(utf8.encode(idLow))
      ..add(bundleLow)
      ..add(utf8.encode(idHigh))
      ..add(bundleHigh);

    final digest = await Sha512().hash(input.toBytes());
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
