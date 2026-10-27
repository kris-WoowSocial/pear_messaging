import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String source(String path) => File(path).readAsStringSync();

/// Bug: minimizing the video call to the chat and restoring recreated the
/// RTCVideoRenderer, so the remote decoder discarded state and painted black
/// until the next keyframe (~3-4 s). Renderers must live for the call.
void main() {
  group('video renderers live for the call, not the screen', () {
    final controller = source('lib/features/call/call_controller.dart');
    final screen = source('lib/features/call/video_call_screen.dart');

    test('controller owns the renderers with call-lifetime init', () {
      expect(controller, contains('RTCVideoRenderer? _remoteRenderer'));
      expect(controller, contains('RTCVideoRenderer? _localRenderer'));
      expect(controller, contains('RTCVideoRenderer? get remoteRenderer'));
      expect(controller, contains('RTCVideoRenderer? get localRenderer'));
      expect(
        controller,
        contains('_renderersInitFuture ??= _initVideoRenderers()'),
        reason: 'ensureVideoRenderers must be idempotent (single init)',
      );
    });

    test('rebinding is a separate step so late streams always attach', () {
      expect(controller, contains('void rebindVideoStreams()'));
      expect(controller, contains('rebindVideoStreams();'));
      // stream callbacks must kick renderer ensure so a stream arriving
      // before the screen exists still binds
      final onLocal = controller.substring(
        controller.indexOf('_webrtcService.onLocalStream'),
        controller.indexOf('_webrtcService.onRemoteStream'),
      );
      expect(onLocal, contains('ensureVideoRenderers'));
    });

    test('renderers are disposed on call end, not screen pop', () {
      expect(controller, contains('_disposeVideoRenderers'));
      final start = controller.indexOf('void _resetCallState()');
      final end = controller.indexOf('\n  ///', start + 10);
      final reset = controller.substring(start, end > start ? end : null);
      expect(
        reset,
        contains('_disposeVideoRenderers'),
        reason: '_resetCallState is the single funnel for call end',
      );
    });

    test('screen creates and disposes no renderers itself', () {
      expect(
        screen,
        isNot(contains('RTCVideoRenderer()')),
        reason: 'per-screen renderers caused the black-frame regression',
      );
      final dispose = screen.substring(
        screen.indexOf('void dispose()'),
        screen.indexOf('Widget build('),
      );
      expect(dispose, isNot(contains('_remoteRenderer')));
      expect(dispose, isNot(contains('_localRenderer')));
      expect(dispose, isNot(contains('srcObject = null')));
      expect(screen, contains('_controller.rebindVideoStreams()'));
    });

    test('no remote frame shows the gradient placeholder, never bare black', () {
      final surface = screen.substring(
        screen.indexOf('Widget _buildVideoSurface()'),
        screen.indexOf('Widget _buildCenterStatus()'),
      );
      expect(surface, contains('remoteRenderer != null'));
      expect(surface, contains('RTCVideoView'));
      expect(
        surface,
        contains('LinearGradient'),
        reason: 'while the renderer/stream is not ready the UI must show '
            'the gradient placeholder instead of a black RTCVideoView',
      );
    });
  });
}
