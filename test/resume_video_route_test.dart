import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String source(String path) => File(path).readAsStringSync();

void main() {
  group('resume/startup must restore the VIDEO route for video calls', () {
    final app = source('lib/app.dart');

    test('app-resume path navigates to activeCallRoute, not hardcoded audio', () {
      // Regression: _onAppResumed hardcoded Get.offAllNamed('/call/active'),
      // so a video call that was minimized/backgrounded and then resumed
      // came back on the audio screen. It must use CallController's
      // activeCallRoute (which resolves /call/video for video calls).
      final resumeBlock = RegExp(
        r'void _onAppResumed\(\)[\s\S]*?// 1\.',
      ).firstMatch(app);
      expect(resumeBlock, isNotNull, reason: '_onAppResumed must exist');
      final code = resumeBlock!.group(0)!;
      expect(code, contains('callController.activeCallRoute'));
      expect(
        code,
        isNot(contains("Get.offAllNamed('/call/active')")),
        reason: 'resume path must not hardcode the audio call route',
      );
    });

    test('startup path navigates to activeCallRoute, not hardcoded audio', () {
      // Same regression on cold/warm start with an in-progress call.
      final startupBlock = RegExp(
        r'Active call detected, navigating to call screen[\s\S]*?\}\);',
      ).firstMatch(app);
      expect(startupBlock, isNotNull, reason: 'startup call-restore must exist');
      final code = startupBlock!.group(0)!;
      expect(code, contains('callController.activeCallRoute'));
      expect(
        code,
        isNot(contains("Get.offAllNamed('/call/active')")),
        reason: 'startup path must not hardcode the audio call route',
      );
    });

    test('no remaining hardcoded /call/active navigation in app.dart', () {
      expect(
        app,
        isNot(contains("offAllNamed('/call/active')")),
        reason: 'all call-restore paths must go through activeCallRoute',
      );
    });
  });

  group('activeCallRoute resolves per call type', () {
    final controller = source('lib/features/call/call_controller.dart');

    test('activeCallRoute returns /call/video for video calls', () {
      expect(
        controller,
        contains(
          RegExp(
            r"String get activeCallRoute[\s\S]*?'/call/video'[\s\S]*?'/call/active'",
          ),
        ),
        reason: 'video calls must resolve to the video call screen',
      );
    });
  });
}
