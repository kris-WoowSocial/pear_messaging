import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Structure tests for the AppDelegate notification-repost loop fix (221).
///
/// Root cause of "You have N new Vant Chat notifications": willPresent reposts
/// any notification carrying senderDeviceId to swap in the saved contact name —
/// but the repost itself still carried senderDeviceId, so its own willPresent
/// reposted it again forever while the app was foreground. The fix marks every
/// repost vantCorrected, skips marked notifications, gates the background-path
/// repost to non-active states, and only suppresses the original banner once
/// the corrected repost is known to have been scheduled.
void main() {
  final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();

  String section(String startMarker, String endMarker) {
    final start = source.indexOf(startMarker);
    if (start == -1) throw StateError('missing section: $startMarker');
    final end = source.indexOf(endMarker, start);
    return end == -1 ? source.substring(start) : source.substring(start, end);
  }

  final willPresent = section(
    'func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent',
    'func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive',
  );
  final didReceiveRemote = section(
    'func application(_ application: UIApplication, didReceiveRemoteNotification',
    'func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent',
  );

  group('willPresent corrected-repost loop guard', () {
    test('marks every reposted notification vantCorrected', () {
      expect(willPresent, contains('correctedInfo["vantCorrected"] = true'));
      // The repost's userInfo must carry the marker — a plain `userInfo`
      // copy would let the repost re-trigger this handler forever.
      expect(willPresent, contains('updatedContent.userInfo = correctedInfo'));
      expect(
        willPresent,
        isNot(contains('updatedContent.userInfo = userInfo')),
        reason:
            'reposting raw userInfo (with senderDeviceId, no marker) recreates the loop',
      );
    });

    test('skips notifications already marked vantCorrected', () {
      expect(
        willPresent,
        contains('(userInfo["vantCorrected"] as? Bool) != true'),
      );
    });

    test('suppresses the original only after the repost add succeeds', () {
      // Inside the add() completion: success -> suppress ([]), failure ->
      // original banner still shows. There must be no suppression decided
      // before the add completes.
      final addCall =
          willPresent.indexOf('UNUserNotificationCenter.current().add(newRequest)');
      expect(addCall, isNot(-1));
      final completion = willPresent.substring(addCall);
      final successSuppress = completion.indexOf('completionHandler([])');
      final errorBanner =
          completion.indexOf('completionHandler([.banner, .sound, .badge])');
      expect(
        successSuppress,
        isNot(-1),
        reason: 'corrected repost success must suppress the original',
      );
      expect(
        errorBanner,
        isNot(-1),
        reason: 'corrected repost failure must still show the original',
      );
      expect(
        errorBanner,
        lessThan(successSuppress),
        reason: 'error branch must precede the success suppress in the closure',
      );
    });

    test('unhandled notifications still present normally', () {
      expect(
        willPresent,
        contains('completionHandler([.banner, .sound, .badge])'),
      );
    });
  });

  group('didReceiveRemoteNotification background corrected post', () {
    test('marks its repost vantCorrected', () {
      expect(didReceiveRemote, contains('correctedInfo["vantCorrected"] = true'));
      expect(didReceiveRemote, contains('content.userInfo = correctedInfo'));
    });

    test('only posts while the app is not active', () {
      // willPresent already handles foreground presentation — posting the
      // corrected copy here too would give two banners for one push.
      expect(
        didReceiveRemote,
        contains('application.applicationState != .active'),
      );
      final gate = didReceiveRemote
          .indexOf('application.applicationState != .active');
      final post = didReceiveRemote
          .indexOf('UNUserNotificationCenter.current().add(request)');
      expect(post, isNot(-1));
      expect(
        gate,
        lessThan(post),
        reason: 'the .active gate must precede the corrected post',
      );
    });
  });
}
