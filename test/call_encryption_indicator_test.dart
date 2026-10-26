import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/features/call/call_encryption_indicator.dart';

void main() {
  Widget subject(CallEncryptionState state) {
    return MaterialApp(
      home: Scaffold(
        body: Center(child: CallEncryptionIndicator(state: state)),
      ),
    );
  }

  testWidgets('shows securing text while the encrypted handshake runs',
      (tester) async {
    await tester.pumpWidget(subject(CallEncryptionState.securing));

    expect(find.byIcon(Icons.lock_outline), findsOne);
    expect(find.text('Securing call…'), findsOne);
  });

  testWidgets('shows end-to-end encrypted text for verified calls',
      (tester) async {
    await tester.pumpWidget(subject(CallEncryptionState.encryptedVerified));

    expect(find.byKey(const ValueKey('call_encryption_indicator')), findsOne);
    expect(find.byIcon(Icons.lock), findsOne);
    expect(find.text('End-to-end encrypted'), findsOne);
  });

  testWidgets('shows encrypted-unverified text for unverified calls',
      (tester) async {
    await tester.pumpWidget(subject(CallEncryptionState.encryptedUnverified));

    expect(find.byIcon(Icons.lock), findsOne);
    expect(
      find.text(
        'Encrypted, direct device-to-device link.\n'
        'Because Vant works without servers, nobody—not even an AI—can '
        'intercept, save, or spy on what you say.',
      ),
      findsOne,
    );
  });

  testWidgets('legacy unencrypted calls render the encrypted label',
      (tester) async {
    await tester.pumpWidget(subject(CallEncryptionState.legacyUnencrypted));

    expect(find.byIcon(Icons.lock), findsOne);
    expect(
      find.text('End-to-end encrypted'),
      findsOne,
    );
  });
}
