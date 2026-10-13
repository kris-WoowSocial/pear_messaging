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

  testWidgets('shows unverified text while the encrypted handshake runs',
      (tester) async {
    await tester.pumpWidget(subject(CallEncryptionState.securing));

    expect(find.byIcon(Icons.lock_outline), findsOne);
    expect(find.text('Encrypted, contact not verified'), findsOne);
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

    expect(find.byIcon(Icons.lock_outline), findsOne);
    expect(find.text('Encrypted, contact not verified'), findsOne);
  });

  testWidgets('shows warning for legacy unencrypted calls', (tester) async {
    await tester.pumpWidget(subject(CallEncryptionState.legacyUnencrypted));

    expect(find.byIcon(Icons.lock_open), findsOne);
    expect(
      find.text('Not end-to-end encrypted'),
      findsOne,
    );
  });
}
