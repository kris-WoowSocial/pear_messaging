import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String source(String path) => File(path).readAsStringSync();

String section(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex);
  expect(startIndex, greaterThanOrEqualTo(0));
  expect(endIndex, greaterThan(startIndex));
  return source.substring(startIndex, endIndex);
}

void main() {
  group('immediate video UX', () {
    test('caller opens the video route while startCall is still preparing', () {
      final startVideo = section(
        source('lib/features/chat/chat_screen.dart'),
        'Future<void> _startVideoCall() async',
        '/// Build the WhatsApp-style message input',
      );

      expect(startVideo, contains('final started = callController.startCall('));
      expect(startVideo, contains("Get.toNamed('/call/video')"));
      expect(
        startVideo.indexOf('final started = callController.startCall('),
        lessThan(startVideo.indexOf("Get.toNamed('/call/video')")),
      );
    });

    test('accepted video calls open the video route before accept completes',
        () {
      final accept = section(
        source('lib/features/call/incoming_call_screen.dart'),
        'Future<void> _acceptCall',
        'Future<void> _declineCall',
      );

      expect(accept, contains('acceptFuture = controller.acceptCall'));
      expect(accept, contains("Get.offNamed('/call/video')"));
      expect(
        accept.indexOf("Get.offNamed('/call/video')"),
        lessThan(accept.indexOf('acceptFuture = controller.acceptCall')),
      );
      expect(accept,
          contains('Get.find<FeatureFlagService>().videoCalling.value'));
    });

    test(
        'active route follows a video request before camera permission resolves',
        () {
      final controller = source('lib/features/call/call_controller.dart');
      final route = section(
        controller,
        'String get activeCallRoute',
        'void restoreCallScreen()',
      );

      expect(route, contains('_videoRequested || isVideoCall.value'));
      expect(route, contains("'/call/video'"));
    });

    test('video screen owns local full-screen preview until remote arrives',
        () {
      final screen = source('lib/features/call/video_call_screen.dart');

      expect(screen, contains('_buildVideoSurface'));
      expect(
          screen, contains('RTCVideoViewObjectFit.RTCVideoViewObjectFitCover'));
      expect(screen, contains('_controller.localVideoStream.value != null'));
      expect(screen, contains('_buildLocalPreview'));
      expect(screen, contains('onPanUpdate'));
    });
  });

  group('camera release contract', () {
    test('call cleanup stops and disposes the local preview stream', () {
      final cleanup = section(
        source('lib/core/services/webrtc_call_service.dart'),
        'Future<void> _endCall() async',
        '/// Configure audio session',
      );

      expect(cleanup, contains('_deferredVideoRequested = false'));
      expect(cleanup, contains('_localVideoPreviewStream?.getTracks()'));
      expect(cleanup, contains('track.stop()'));
      expect(cleanup, contains('_localVideoPreviewStream?.dispose()'));
      expect(cleanup, contains('_localVideoPreviewStream = null'));
    });

    test('caller cancel and remote timeout release video media', () {
      final controller = source('lib/features/call/call_controller.dart');
      final cancel = section(
        controller,
        'void endCall()',
        '/// Minimize the call screen',
      );
      final timeout = section(
        controller,
        'void _handleCallTerminated',
        '/// Handle local ICE candidate',
      );

      expect(cancel, contains('_webrtcService.endCall()'));
      expect(timeout, contains('_webrtcService.endCall()'));
    });

    test('callee decline releases any in-flight video setup', () {
      final decline = section(
        source('lib/features/call/call_controller.dart'),
        'void rejectCall(',
        '/// End the current call',
      );

      expect(decline, contains('_webrtcService.endCall()'));
    });

    test('remote rejection and crypto failures release video media', () {
      final controller = source('lib/features/call/call_controller.dart');
      final rejected = section(
        controller,
        'void _handleCallRejected',
        '/// Handle call terminated',
      );
      final rejectCrypto = section(
        controller,
        'void _rejectCryptoCall',
        'void _failCryptoCall',
      );
      final failCrypto = section(
        controller,
        'void _failCryptoCall',
        'void _resetCryptoState',
      );

      expect(rejected, contains('_webrtcService.endCall()'));
      expect(rejectCrypto, contains('_webrtcService.endCall()'));
      expect(failCrypto, contains('_webrtcService.endCall()'));
    });
  });

  test('incoming video calls use the requested label', () {
    final screen = source('lib/features/call/incoming_call_screen.dart');
    final native = source(
      'android/app/src/main/kotlin/com/vant/chat/IncomingCallActivity.kt',
    );

    expect(screen, contains("'Incoming video call'"));
    expect(native, contains('"Incoming video call"'));
  });
}
