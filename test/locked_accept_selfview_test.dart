import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String source(String path) => File(path).readAsStringSync();

/// Bug: cold-start + locked-screen video accept shows remote video but never
/// the self-view tile — the one-shot onLocalStream binding can be missed on
/// that path, so localVideoStream/isCameraOn stay stale for the whole call.
void main() {
  group('local video stream binding is healable, not one-shot', () {
    final webrtc = source('lib/core/services/webrtc_call_service.dart');
    final controller = source('lib/features/call/call_controller.dart');
    final screen = source('lib/features/call/video_call_screen.dart');

    test('WebRTC service exposes the live local stream', () {
      expect(webrtc, contains('MediaStream? get localStream => _localStream'));
    });

    test('controller heals a missed onLocalStream binding', () {
      final helperStart = controller.indexOf('_ensureLocalVideoStateBound()');
      expect(helperStart, greaterThan(-1));
      final body = controller.substring(
        helperStart,
        controller.indexOf('/// Toggle mute'),
      );
      expect(body, contains('_webrtcService.localStream'));
      expect(body, contains('localVideoStream.value = stream'));
      expect(body, contains('_webrtcService.isCameraEnabled'));
    });

    test('heal runs on connect, post-accept, and resume', () {
      expect(
        controller,
        contains(
          "case 'connected':\n        _cancelDialWatchdog();\n        _ringtoneService.stopRingtone(reason: 'connected');",
        ),
      );
      final occurrences =
          '_ensureLocalVideoStateBound()'.allMatches(controller).length;
      expect(
        occurrences,
        greaterThanOrEqualTo(4),
        reason: 'definition + connected + resume + at least one accept path',
      );
    });

    test('video screen re-binds renderers on resume/unlock', () {
      expect(screen, contains('with WidgetsBindingObserver'));
      expect(
        screen,
        contains('void didChangeAppLifecycleState(AppLifecycleState state)'),
      );
      final lifecycle = screen.substring(
        screen.indexOf('didChangeAppLifecycleState'),
      );
      expect(lifecycle, contains('AppLifecycleState.resumed'));
      expect(lifecycle, contains('rebindVideoStreams'));
    });
  });
}
