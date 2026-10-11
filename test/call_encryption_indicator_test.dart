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

  testWidgets('shows securing state while the encrypted handshake runs',
      (tester) async {
    await tester.pumpWidget(subject(CallEncryptionState.securing));

    expect(find.byIcon(Icons.lock_outline), findsOne);
    expect(find.text('Securing encrypted call…'), findsOne);
  });

  testWidgets('shows sticky encrypted text for verified calls', (tester) async {
    await tester.pumpWidget(subject(CallEncryptionState.encryptedVerified));

    expect(find.byKey(const ValueKey('call_encryption_indicator')), findsOne);
    expect(find.byIcon(Icons.lock), findsOne);
    expect(
      find.text(CallEncryptionIndicator.directEncryptionMessage),
      findsOne,
    );
  });

  testWidgets('shows sticky encrypted text for unverified calls',
      (tester) async {
    await tester.pumpWidget(subject(CallEncryptionState.encryptedUnverified));

    expect(find.byIcon(Icons.lock), findsOne);
    expect(
      find.text(CallEncryptionIndicator.directEncryptionMessage),
      findsOne,
    );
  });

  testWidgets('shows warning for legacy unencrypted calls', (tester) async {
    await tester.pumpWidget(subject(CallEncryptionState.legacyUnencrypted));

    expect(find.byIcon(Icons.lock_open), findsOne);
    expect(
      find.textContaining('Not end-to-end encrypted'),
      findsOne,
    );
  });
}
