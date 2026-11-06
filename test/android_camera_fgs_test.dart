import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String source(String path) => File(path).readAsStringSync();

/// Cold-start/locked video accept: the camera-type foreground service must be
/// running BEFORE getUserMedia opens the camera, or Android can deliver zero
/// frames from a still-backgrounded app (remote video shows, self-view stays
/// empty). These tests pin the ordering and the guards that keep audio-only
/// and outgoing calls untouched.
void main() {
  group('camera-type FGS starts before getUserMedia on video accepts', () {
    final webrtc = source('lib/core/services/webrtc_call_service.dart');
    final controller = source('lib/features/call/call_controller.dart');
    final service = source(
      'android/app/src/main/kotlin/com/vant/chat/CallForegroundService.kt',
    );
    final activity = source(
      'android/app/src/main/kotlin/com/vant/chat/MainActivity.kt',
    );

    test('WebRTC service exposes an injectable pre-media hook', () {
      expect(
        webrtc,
        contains('Future<void> Function()? onEnsureMediaForegroundService'),
      );
    });

    test('acceptCall awaits the hook before getUserMedia, video-only', () {
      final acceptStart = webrtc.indexOf('Future<bool> acceptCall({');
      expect(acceptStart, greaterThan(-1));
      final body = webrtc.substring(acceptStart);
      final hookIdx = body.indexOf('await onEnsureMediaForegroundService!()');
      final gumIdx = body.indexOf('_getUserMedia(video:');
      expect(hookIdx, greaterThan(-1));
      expect(gumIdx, greaterThan(-1));
      expect(hookIdx, lessThan(gumIdx));
      // Guard must be present and video-only (audio accepts skip it).
      expect(
        body.substring(0, hookIdx),
        contains('if (_isVideoCall && onEnsureMediaForegroundService != null)'),
      );
    });

    test('outgoing startCall path does not touch the hook', () {
      final startIdx = webrtc.indexOf('Future<bool> startCall');
      final acceptIdx = webrtc.indexOf('Future<bool> acceptCall({');
      expect(startIdx, greaterThan(-1));
      expect(acceptIdx, greaterThan(startIdx));
      final startBody = webrtc.substring(startIdx, acceptIdx);
      expect(startBody, isNot(contains('onEnsureMediaForegroundService')));
    });

    test('controller wires the hook to an early startOngoingCall with isVideo',
        () {
      expect(
        controller,
        contains(
          '_webrtcService.onEnsureMediaForegroundService = '
          '_startEarlyVideoCallFgs',
        ),
      );
      final fnStart = controller.indexOf('_startEarlyVideoCallFgs() async');
      expect(fnStart, greaterThan(-1));
      final body = controller.substring(fnStart, fnStart + 1600);
      expect(body, contains('if (!Platform.isAndroid) return'));
      expect(body, contains("invokeMethod('startOngoingCall'"));
      expect(body, contains("'isVideo': true"));
    });

    test('early-FGS failure must not abort the accept (errors swallowed)', () {
      final fnStart = controller.indexOf('_startEarlyVideoCallFgs() async');
      final body = controller.substring(fnStart, fnStart + 1600);
      expect(body, contains('} catch (e) {'));
      expect(body, isNot(contains('rethrow')));
    });

    test('local first-frame watchdog: 2s budget, cleaned up on dispose', () {
      expect(controller, contains('onFirstFrameRendered = ()'));
      expect(controller, contains('Timer(const Duration(seconds: 2)'));
      // Watchdog state must be torn down with the renderers.
      final disposeStart = controller.indexOf('_disposeVideoRenderers() async');
      final disposeBody = controller.substring(disposeStart, disposeStart + 900);
      expect(disposeBody, contains('_localFirstFrameWatchdog?.cancel()'));
      expect(disposeBody, contains('_watchedLocalStream = null'));
      expect(disposeBody, contains('local.onFirstFrameRendered = null'));
    });

    test('native service only adds camera type when CAMERA is granted', () {
      expect(service, contains('checkSelfPermission'));
      expect(service, contains('Manifest.permission.CAMERA'));
      expect(
        service,
        contains(
          'if (ongoingIsVideo && hasCameraPermission)',
        ),
      );
      expect(
        service,
        contains('ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA'),
      );
      // Timestamped diagnostics for the start path.
      expect(service, contains('SystemClock.elapsedRealtime()'));
    });

    test('MainActivity logs the early dispatch with timestamp', () {
      expect(
        activity,
        contains('dispatch START_ONGOING_CALL callId='),
      );
      expect(activity, contains('SystemClock.elapsedRealtime()'));
      expect(activity, contains('import android.os.SystemClock'));
    });
  });

  group('early FGS is torn down on every accept-failure path', () {
    final controller = source('lib/features/call/call_controller.dart');
    final manager = source(
      'android/app/src/main/kotlin/com/vant/chat/VantCallManager.kt',
    );

    test('acceptCall failure and throw both reach _resetCallState', () {
      final acceptStart = controller.indexOf('Future<bool> acceptCall(');
      // acceptCall ends before '/// Reject an incoming call' — slice to there.
      final acceptEnd = controller.indexOf('/// Reject an incoming call');
      final body = controller.substring(acceptStart, acceptEnd);
      // !success branch and catch branch must both reset.
      final noSuccessIdx = body.indexOf('if (!success)');
      expect(noSuccessIdx, greaterThan(-1));
      expect(
        body.substring(noSuccessIdx),
        contains('_resetCallState();'),
      );
      final catchIdx = body.indexOf('} catch (e) {');
      expect(catchIdx, greaterThan(-1));
      expect(body.substring(catchIdx), contains('_resetCallState();'));
    });

    test('resync accept failure reaches _resetCallState', () {
      final resyncStart =
          controller.indexOf('_acceptIncomingCallResync(Map<String, dynamic>');
      expect(resyncStart, greaterThan(-1));
      final body = controller.substring(resyncStart);
      expect(body, contains('_resetCallState();'));
    });

    test('caller-cancel mid-accept reaches _resetCallState via _handleCallEnded',
        () {
      final endedStart = controller.indexOf('_handleCallEnded(String callId)');
      final body = controller.substring(endedStart, endedStart + 800);
      expect(body, contains('_resetCallState();'));
    });

    test('_resetCallState tears down the native call (stops the FGS)', () {
      final resetStart = controller.indexOf('void _resetCallState()');
      final body = controller.substring(resetStart, resetStart + 2500);
      expect(body, contains('_teardownAndroidCall(callId)'));
      // The channel call lands in VantCallManager.teardownCall →
      // releaseCallResources → stopService(CallForegroundService).
      expect(manager, contains('context.stopService'));
      expect(manager, contains('releaseCallResources(context, callId)'));
    });
  });
}
