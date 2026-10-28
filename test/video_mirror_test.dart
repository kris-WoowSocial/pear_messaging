import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:pear_messaging/features/call/call_video_view.dart';

String source(String path) => File(path).readAsStringSync();

/// Bug: remote video appeared horizontally mirrored (text backwards) for
/// Android viewing an iPhone front-camera feed. The remote feed must never
/// be mirrored; only the local self-view may mirror (front camera only).
void main() {
  group('mirror flag contract', () {
    test('RemoteCallVideoView never mirrors', () {
      final view = RemoteCallVideoView(RTCVideoRenderer());
      final rtcView = view.build(_FakeContext()) as RTCVideoView;
      expect(rtcView.mirror, isFalse);
    });

    test('LocalCallVideoView mirrors only the front camera', () {
      final renderer = RTCVideoRenderer();
      expect(
        (LocalCallVideoView(renderer, isFrontCamera: true)
                .build(_FakeContext()) as RTCVideoView)
            .mirror,
        isTrue,
      );
      expect(
        (LocalCallVideoView(renderer, isFrontCamera: false)
                .build(_FakeContext()) as RTCVideoView)
            .mirror,
        isFalse,
      );
    });
  });

  group('widget: mirror flag on the built RTCVideoView', () {
    // An uninitialized renderer has renderVideo == false, so RTCVideoView
    // builds without touching the platform texture — safe to pump headlessly.
    Future<bool> pumpMirror(WidgetTester tester, Widget view) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
      return tester.widget<RTCVideoView>(find.byType(RTCVideoView)).mirror;
    }

    testWidgets('remote view builds with mirror false', (tester) async {
      expect(
        await pumpMirror(tester, RemoteCallVideoView(RTCVideoRenderer())),
        isFalse,
      );
    });

    testWidgets('local front-camera view is mirrored', (tester) async {
      expect(
        await pumpMirror(
          tester,
          LocalCallVideoView(RTCVideoRenderer(), isFrontCamera: true),
        ),
        isTrue,
      );
    });

    testWidgets('local rear-camera view is not mirrored', (tester) async {
      expect(
        await pumpMirror(
          tester,
          LocalCallVideoView(RTCVideoRenderer(), isFrontCamera: false),
        ),
        isFalse,
      );
    });
  });

  group('call screen uses the safe views', () {
    final screen = source('lib/features/call/video_call_screen.dart');

    test('remote surface and PiP use RemoteCallVideoView', () {
      expect(
        screen,
        contains('RemoteCallVideoView(remoteRenderer'),
        reason: 'remote feed must never inherit the local mirror flag',
      );
      // No raw RTCVideoView left on any remote path.
      expect(screen, isNot(contains('RTCVideoView(\n          remoteRenderer')));
      expect(
        RegExp(r'RTCVideoView\(\s*remoteRenderer')
            .hasMatch(screen),
        isFalse,
      );
    });

    test('self-view binds mirror to isFrontCamera, not a stale bool', () {
      expect(
        screen,
        contains('isFrontCamera: _controller.isFrontCamera.value'),
      );
      // Every remaining RTCVideoView in the screen must carry an explicit
      // mirror decision — nothing may rely on a default.
      expect(screen, isNot(contains('mirror:')));
    });
  });

  group('camera-switch state contract', () {
    final service = source('lib/core/services/webrtc_call_service.dart');
    final controller = source('lib/features/call/call_controller.dart');

    test('facing flag only flips after a successful switch', () {
      final start = service.indexOf('Future<bool> switchCamera()');
      final end = service.indexOf('///', start + 10);
      final body = service.substring(start, end > start ? end : null);
      expect(
        body,
        contains('if (switched) _isFrontCamera = !_isFrontCamera'),
        reason: 'front->rear must clear the mirror flag, never go stale',
      );
      expect(body, contains('return false;'));
    });

    test('front flag resets on each new capture and on call end', () {
      expect(service, contains('if (video) _isFrontCamera = true;'));
      expect(controller, contains('isFrontCamera.value = true;'));
    });
  });

  group('iOS sent frames are unmirrored', () {
    final guard = source('ios/Runner/CaptureSessionMirrorGuard.swift');
    final appDelegate = source('ios/Runner/AppDelegate.swift');

    test('guard forces every capture connection unmirrored', () {
      expect(guard, contains('automaticallyAdjustsVideoMirroring = false'));
      expect(guard, contains('isVideoMirrored = false'));
      // Covers camera switch mid-call: connections recreated during
      // commitConfiguration are un-mirrored again.
      expect(guard, contains('vant_commitConfiguration'));
      expect(guard, contains('AVCaptureSessionDidStartRunning'));
    });

    test('guard is installed at launch', () {
      expect(appDelegate, contains('CaptureSessionMirrorGuard.install()'));
    });
  });
}

class _FakeContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
