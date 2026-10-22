import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/features/call/call_controller.dart';

void main() {
  group('iOS video call fixes', () {
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
  });
}
