import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

// Swift-independent source test: verify that the UserDefaults key written by
// AppDelegate.swift is exactly "flutter." + the SharedPreferences key read by
// Dart's CallKitService. This prevents the two sides from drifting out of sync.
void main() {
  test('Swift-written UserDefaults key matches Dart-read SharedPreferences key',
      () {
    final swiftSource =
        File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final dartSource =
        File('lib/core/services/callkit_service.dart').readAsStringSync();

    final swiftKeyMatch = RegExp(
      r'forKey:\s*"([^"]*apns_environment[^"]*)"',
    ).firstMatch(swiftSource);
    final dartKeyMatch = RegExp(
      r"getString\('([^']*apns_environment[^']*)'\)",
    ).firstMatch(dartSource);

    final swiftKey = swiftKeyMatch?.group(1);
    final dartKey = dartKeyMatch?.group(1);

    expect(swiftKey, isNotNull,
        reason: 'AppDelegate.swift must set an apns_environment UserDefaults key');
    expect(dartKey, isNotNull,
        reason: 'CallKitService must read an apns_environment SharedPreferences key');
    expect(swiftKey, equals('flutter.$dartKey'),
        reason: 'Swift must write "flutter." prefix that Dart SharedPreferences resolves');
  });
}
