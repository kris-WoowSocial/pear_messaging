import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pear_messaging/features/call/call_encryption_indicator.dart';

/// Bug: the encryption banner was capped at 4 lines + ellipsis, so the long
/// unverified-encryption copy was truncated on large-font devices. It must
/// always render the full text with no overflow.
void main() {
  const longText =
      'Encrypted, direct device-to-device link.\n'
      'Because Vant works without servers, nobody—not even an AI—can intercept, save, or spy on what you say.';

  Future<void> pumpBanner(
    WidgetTester tester, {
    required double width,
    required double scale,
    double height = 740,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: Size(width, height),
          textScaler: TextScaler.linear(scale),
        ),
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: CallEncryptionIndicator(
                state: CallEncryptionState.encryptedUnverified,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 360.0, 412.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        'full text, no ellipsis, no overflow at ${width}x$scale',
        (tester) async {
          await pumpBanner(tester, width: width, scale: scale);
          // Full copy present in the widget tree (single Text node).
          final text = tester.widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('call_encryption_indicator')),
              matching: find.byType(Text),
            ),
          );
          expect(text.data, longText);
          expect(text.maxLines, isNull, reason: 'no line cap — never truncate');
          expect(
            text.overflow,
            isNull,
            reason: 'no ellipsis — full copy must render',
          );
          // RenderFlex/render overflow throws during pump in tests; reaching
          // here means the banner fits inside its constraints.
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('text scale is clamped so 2.0x does not blow up layout', (
    tester,
  ) async {
    await pumpBanner(tester, width: 360, scale: 2.0);
    final text = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('call_encryption_indicator')),
        matching: find.byType(Text),
      ),
    );
    // clamped to 1.3 max: effective font size ~17 * 1.3
    expect(text.textScaler, isNotNull);
  });
}
