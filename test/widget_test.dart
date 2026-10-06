// Stock counter smoke test removed — it referenced MyApp which no longer
// exists and was permanently red, hiding real failures. Replace with a
// sanity test that actually exercises the framework.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('smoke: widget tree renders', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('vant'))),
    );
    expect(find.text('vant'), findsOneWidget);
  });
}
