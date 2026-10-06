import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/utils/safety_code.dart';

void main() {
  // Fixed vector — any algorithm change breaks verification between phones.
  const PINNED_VECTOR =
      '154702673582100778847841941472302324368199280690078805027088';

  // Deterministic test inputs — both sides must compute the SAME code.
  final bundleA = base64Encode(Uint8List.fromList([1, ...List.filled(32, 0xAA), ...List.filled(32, 0xBB)]));
  final bundleB = base64Encode(Uint8List.fromList([1, ...List.filled(32, 0xCC), ...List.filled(32, 0xDD)]));

  group('SafetyCode.compute', () {
    test('is symmetric — argument order does not matter', () async {
      final ab = await SafetyCode.compute(
        idA: '1111111111',
        bundleA: bundleA,
        idB: '2222222222',
        bundleB: bundleB,
      );
      final ba = await SafetyCode.compute(
        idA: '2222222222',
        bundleA: bundleB,
        idB: '1111111111',
        bundleB: bundleA,
      );
      expect(ab, ba);
      expect(ab!.length, 60);
    });

    test('different key material yields a different code', () async {
      final bundleC = base64Encode(
          Uint8List.fromList([1, ...List.filled(32, 0xEE), ...List.filled(32, 0xFF)]));
      final ab = await SafetyCode.compute(
        idA: '1111111111', bundleA: bundleA, idB: '2222222222', bundleB: bundleB);
      final ac = await SafetyCode.compute(
        idA: '1111111111', bundleA: bundleA, idB: '2222222222', bundleB: bundleC);
      expect(ab, isNot(ac));
    });

    test('rejects invalid ids and malformed bundles', () async {
      expect(
        await SafetyCode.compute(idA: 'abc', bundleA: bundleA, idB: '2', bundleB: bundleB),
        isNull,
      );
      expect(
        await SafetyCode.compute(
            idA: '1', bundleA: 'not-base64!', idB: '2', bundleB: bundleB),
        isNull,
      );
      expect(
        await SafetyCode.compute(idA: '1', bundleA: bundleA, idB: '1', bundleB: bundleB),
        isNull, // same id both sides
      );
    });

    test('is deterministic — fixed vector must not drift', () async {
      // Pinned output: if this value changes, the algorithm changed and
      // already-verified safety codes would no longer match.
      final code = await SafetyCode.compute(
        idA: '1111111111', bundleA: bundleA, idB: '2222222222', bundleB: bundleB);
      expect(code, PINNED_VECTOR);
    });
  });

  test('formatGroups renders 12 groups of 5', () {
    final code = '1234567890' * 6; // 60 digits
    final groups = SafetyCode.formatGroups(code);
    expect(groups.split('  ').length, 12);
    expect(groups.replaceAll('  ', ''), code);
  });
}
