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

  testWidgets('shows encrypted and verified state', (tester) async {
    await tester.pumpWidget(subject(CallEncryptionState.encryptedVerified));

    expect(find.byKey(const ValueKey('call_encryption_indicator')), findsOne);
    expect(find.byIcon(Icons.verified_user), findsOne);
    expect(find.text('Encrypted and verified'), findsOne);
  });

  testWidgets('shows encrypted but unverified state', (tester) async {
    await tester.pumpWidget(subject(CallEncryptionState.encryptedUnverified));

    expect(find.byIcon(Icons.lock), findsOne);
    expect(find.text('Encrypted — not verified'), findsOne);
  });

  testWidgets('shows warning for legacy unencrypted calls', (tester) async {
    await tester.pumpWidget(subject(CallEncryptionState.legacyUnencrypted));

    expect(find.byIcon(Icons.lock_open), findsOne);
    expect(find.text('Not end-to-end encrypted'), findsOne);
  });
}
