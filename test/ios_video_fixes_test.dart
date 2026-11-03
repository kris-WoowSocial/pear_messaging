import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/features/call/call_controller.dart';
import 'package:pear_messaging/core/services/webrtc_call_service.dart';

void main() {
  group('iOS video call fixes', () {
    test('recording configuration is applied only at iOS connect before routing', () {
      final source = File('lib/core/services/webrtc_call_service.dart').readAsStringSync();
      final connected = source.substring(
        source.indexOf('case RTCPeerConnectionState.RTCPeerConnectionStateConnected:'),
        source.indexOf('case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:'),
      );
      expect(connected, contains('if (Platform.isIOS)'));
      expect(connected, contains('await Helper.setAppleAudioIOMode('));
      expect(connected, contains('AppleAudioIOMode.localAndRemote'));
      expect(connected, contains('preferSpeakerOutput: false'));
      final configure = connected.indexOf('await Helper.setAppleAudioIOMode(');
      for (final operation in [
        "onCallStateChange?.call('connected')",
        '_startDurationTimer()',
        '_startStatsLogger()',
      ]) {
        expect(connected.indexOf(operation), allOf(greaterThanOrEqualTo(0), lessThan(configure)));
      }
      expect(connected, contains('revision != connectionStateRevision'));
      expect(connected, contains('!identical(_peerConnection, connection)'));
      expect(connected.indexOf('await Helper.setAppleAudioIOMode('),
          lessThan(connected.indexOf('_configureAudioSession(')));
      expect('Helper.setAppleAudioIOMode('.allMatches(source).length, 1);
      expect(source.substring(source.indexOf('Future<void> _endCall()')),
          isNot(contains('Helper.setAppleAudioIOMode(')));
    });

    testWidgets('second call starts its duration timer after completed cleanup', (tester) async {
      const channel = MethodChannel('FlutterWebRTC.Method');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel, (call) async => null,
      );
      final service = WebRTCCallService();
      var completed = 0;
      service.onCallEnded = (_) => completed++;
      try {
        service.startDurationTimerForTesting();
        await tester.pump(const Duration(seconds: 2));
        expect(service.getCallDuration(), '00:02');
        service.endCall();
        await tester.pump();
        expect(completed, 1);
        expect(service.getCallDuration(), '00:00');
        await tester.pump(const Duration(seconds: 2));
        expect(service.getCallDuration(), '00:00');
        service.startDurationTimerForTesting();
        await tester.pump(const Duration(seconds: 1));
        expect(service.getCallDuration(), '00:01');
        service.endCall();
        await tester.pump();
        expect(completed, 2);
      } finally {
        service.endCall();
        await tester.pump();
        service.onCallEnded = null;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    });

    test('camera pause lifecycle rule: paused always pauses; inactive only on hold', () {
      expect(
        CallController.shouldPauseCameraForLifecycle(
          AppLifecycleState.paused,
          nativeCallHeld: false,
        ),
        isTrue,
      );
      expect(
        CallController.shouldPauseCameraForLifecycle(
          AppLifecycleState.paused,
          nativeCallHeld: true,
        ),
        isTrue,
      );
      expect(
        CallController.shouldPauseCameraForLifecycle(
          AppLifecycleState.inactive,
          nativeCallHeld: true,
        ),
        isTrue,
      );
      expect(
        CallController.shouldPauseCameraForLifecycle(
          AppLifecycleState.inactive,
          nativeCallHeld: false,
        ),
        isFalse,
      );
      expect(
        CallController.shouldPauseCameraForLifecycle(
          AppLifecycleState.resumed,
          nativeCallHeld: true,
        ),
        isFalse,
      );
      expect(
        CallController.shouldPauseCameraForLifecycle(
          AppLifecycleState.detached,
          nativeCallHeld: false,
        ),
        isFalse,
      );
    });

    test('isVideoCall is synced from WebRTC after startCall and acceptCall', () {
      final source =
          File('lib/features/call/call_controller.dart').readAsStringSync();
      // Both the outgoing and incoming success paths must mirror the actual
      // WebRTC video state so a denied camera permission doesn't leave the UI
      // claiming a video call while only audio is flowing.
      expect(
        source,
        contains('isVideoCall.value = _webrtcService.isVideoCall'),
      );
      final occurrences =
          'isVideoCall.value = _webrtcService.isVideoCall'.allMatches(source);
      expect(occurrences.length, greaterThanOrEqualTo(2));
    });

    test('draggable video preview is clamped inside the safe area', () {
      final source =
          File('lib/features/call/video_call_screen.dart').readAsStringSync();
      expect(source, contains('MediaQuery.of(context).padding'));
      expect(source, contains('_initialPreviewOffset(size, padding)'));
      expect(source, contains('_clampedPreviewOffset('));
      expect(source, contains('EdgeInsets padding'));
      expect(source, contains('padding.left'));
      expect(source, contains('padding.bottom'));
    });

    test('capabilities are re-announced when Remote Config flags change', () {
      final source =
          File('lib/core/services/socket_service.dart').readAsStringSync();
      // Merged behavior: flag changes emit a lightweight capabilities_update
      // on the live socket instead of re-registering the device.
      expect(source, contains('onFlagsUpdated'));
      expect(source, contains('_subscribeCapabilityFlagUpdates()'));
      expect(source, contains('sendCapabilitiesUpdate()'));
      expect(source, contains("'capabilities_update'"));
      expect(source, contains('isRegistered.value'));
    });

    test('Android-only MethodChannel calls are guarded by Platform.isAndroid', () {
      final controllerSource =
          File('lib/features/call/call_controller.dart').readAsStringSync();
      final proximitySource =
          File('lib/core/services/proximity_service.dart').readAsStringSync();

      // Every Android-only channel invocation must be preceded by a platform
      // guard in the same function. We check a window of lines before each
      // invokeMethod call.
      const guardedCalls = [
        'dismissKeyguard',
        'relockDevice',
        'clearShowWhenLocked',
        'showWhenLocked',
        'acquireProximityWakeLock',
        'releaseProximityWakeLock',
        'turnScreenOff',
        'turnScreenOn',
        'checkProximitySensor',
        // Android-only incoming-call channel methods — must never reach the
        // platform layer on iOS (the channel is not registered there).
        'getPendingCallAction',
        'setCallScreenVisible',
        'stopIncomingCall',
        'canUseFullScreenIntent',
        'openFullScreenIntentSettings',
        'finishAndRemoveTask',
        // Android-only methods on the shared callState channel — iOS registers
        // the channel but only implements setInCall (which is intentionally
        // unguarded: it is the shared in-call state sync on both platforms).
        'isAppInBackground',
        'isScreenLocked',
        'startOngoingCall',
        'reportOutgoingTelecomCall',
        'ensureAudioMode',
        'markTelecomCallActive',
        'teardownAndroidCall',
      ];

      for (final method in guardedCalls) {
        final pattern = "'$method'";
        final source = controllerSource.contains(pattern)
            ? controllerSource
            : proximitySource;
        final idx = source.indexOf(pattern);
        expect(idx, isNonNegative,
            reason: 'Expected $method channel call to exist');
        final invokeIdx =
            idx >= 0 ? source.lastIndexOf('invokeMethod', idx) : -1;
        expect(invokeIdx, isNonNegative,
            reason: '$method must be invoked through a MethodChannel');
        final guardStart = invokeIdx - 400 < 0 ? 0 : invokeIdx - 400;
        final context = source.substring(guardStart, invokeIdx);
        expect(
          context.contains('Platform.isAndroid') ||
              context.contains('!Platform.isAndroid'),
          isTrue,
          reason: '$method must be guarded by Platform.isAndroid',
        );
      }

      // The native call-event broadcast stream (com.vant.chat/call_events) is
      // Android Telecom only — the EventChannel is not registered on iOS, so
      // subscribing must be platform-guarded.
      final eventListenerIdx =
          controllerSource.indexOf('receiveBroadcastStream');
      expect(eventListenerIdx, isNonNegative);
      final eventContext = controllerSource.substring(
        eventListenerIdx - 600 < 0 ? 0 : eventListenerIdx - 600,
        eventListenerIdx,
      );
      expect(
        eventContext.contains('!Platform.isAndroid'),
        isTrue,
        reason: 'call_events EventChannel subscription must be Android-only',
      );
    });

    test('audio session re-activation is guarded against post-teardown race', () {
      final source =
          File('ios/Runner/AppDelegate.swift').readAsStringSync();

      // State markers exist
      expect(source, contains('private var interruptedWhileInCall = false'));
      expect(source, contains('private var lastCallEndedAt: Date?'));
      expect(source, contains('func canReactivateAudioSession() -> Bool'));

      // Call-end transition records the teardown timestamp (inside setInCall)
      expect(source, contains('self?.lastCallEndedAt = Date()'));
      expect(source, contains('self?.interruptedWhileInCall = false'));

      // Every setActive(true) re-activation must pass through the guard.
      final setActiveCalls =
          'setActive(true)'.allMatches(source).map((m) => m.start).toList();
      expect(setActiveCalls.length, greaterThanOrEqualTo(2),
          reason: 'expected interruption + route-change re-activation sites');
      for (final idx in setActiveCalls) {
        final context = source.substring(
          idx - 500 < 0 ? 0 : idx - 500,
          idx,
        );
        expect(
          context.contains('canReactivateAudioSession()'),
          isTrue,
          reason:
              'setActive(true) must be gated by canReactivateAudioSession()',
        );
      }

      // The interruption path additionally requires the interruption to have
      // begun while actually in a call.
      final interruptionStart =
          source.indexOf('func handleAudioSessionInterruption');
      final routeChangeStart =
          source.indexOf('func handleAudioSessionRouteChange');
      final interruptionBody = source.substring(
        interruptionStart,
        routeChangeStart > interruptionStart
            ? routeChangeStart
            : source.length,
      );
      expect(
        interruptionBody,
        contains('interruptedWhileInCall && options.contains(.shouldResume)'),
        reason: 'resume must require an interruption that began in-call',
      );
      expect(
        interruptionBody,
        contains('interruptedWhileInCall = true'),
        reason: 'interruption .began must mark in-call interruption',
      );
    });
  });
}
