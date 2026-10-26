import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/features/call/call_controller.dart';
import 'package:pear_messaging/features/call/video_call_screen.dart';

void main() {
  group('PiP entry gate — shouldEnterPip', () {
    const base = true;

    bool call({
      bool isVideoCall = true,
      bool callConnected = true,
      bool flagOn = true,
      int apiLevel = 34,
      bool cameraPermission = true,
      bool inCallUiVisible = true,
      bool incomingRinging = false,
    }) =>
        CallController.shouldEnterPip(
          isVideoCall: isVideoCall,
          callConnected: callConnected,
          flagOn: flagOn,
          apiLevel: apiLevel,
          cameraPermission: cameraPermission,
          inCallUiVisible: inCallUiVisible,
          incomingRinging: incomingRinging,
        );

    test('all conditions hold -> enters PiP', () {
      expect(call(), isTrue);
    });

    test('flag off -> never enters (old behavior preserved)', () {
      expect(call(flagOn: false), isFalse);
    });

    test('voice call -> never enters', () {
      expect(call(isVideoCall: false), isFalse);
    });

    test('not yet connected (ringing/dialing) -> no PiP', () {
      expect(call(callConnected: false), isFalse);
      expect(call(incomingRinging: true), isFalse);
    });

    test('API < 26 -> no PiP', () {
      expect(call(apiLevel: 24), isFalse);
      expect(call(apiLevel: 25), isFalse);
      expect(call(apiLevel: 26), base);
    });

    test('no camera permission -> no PiP', () {
      expect(call(cameraPermission: false), isFalse);
    });

    test('call UI not visible (minimized/chat open) -> no PiP', () {
      expect(call(inCallUiVisible: false), isFalse);
    });
  });

  group('PiP-aware camera pause — shouldPauseCameraOnBackground', () {
    bool call(
      AppLifecycleState state, {
      bool nativeCallHeld = false,
      bool isInPip = false,
      bool pipEntering = false,
    }) =>
        CallController.shouldPauseCameraOnBackground(
          state,
          nativeCallHeld: nativeCallHeld,
          isInPip: isInPip,
          pipEntering: pipEntering,
        );

    test('paused outside PiP pauses (old behavior)', () {
      expect(call(AppLifecycleState.paused), isTrue);
      expect(call(AppLifecycleState.paused, nativeCallHeld: true), isTrue);
    });

    test('paused while in PiP keeps camera running', () {
      expect(call(AppLifecycleState.paused, isInPip: true), isFalse);
      expect(
        call(AppLifecycleState.paused, isInPip: true, nativeCallHeld: true),
        isFalse,
      );
    });

    test('paused during the pipEntering window keeps camera running', () {
      expect(call(AppLifecycleState.paused, pipEntering: true), isFalse);
    });

    test('inactive pauses only on native hold — and never inside PiP', () {
      expect(call(AppLifecycleState.inactive), isFalse);
      expect(call(AppLifecycleState.inactive, nativeCallHeld: true), isTrue);
      expect(
        call(AppLifecycleState.inactive, nativeCallHeld: true, isInPip: true),
        isFalse,
      );
    });

    test('resumed/detached never pause', () {
      expect(call(AppLifecycleState.resumed), isFalse);
      expect(call(AppLifecycleState.detached), isFalse);
    });
  });

  group('250ms debounce decision — resolveBackgroundCameraPause', () {
    test('native reports in-PiP after debounce -> no pause', () async {
      final result = await CallController.resolveBackgroundCameraPause(
        state: AppLifecycleState.paused,
        nativeCallHeld: false,
        pipEntering: false,
        delay: Duration.zero,
        isInPipMode: () async => true,
      );
      expect(result, isFalse);
    });

    test('native reports not-in-PiP after debounce -> pause', () async {
      final result = await CallController.resolveBackgroundCameraPause(
        state: AppLifecycleState.paused,
        nativeCallHeld: false,
        pipEntering: false,
        delay: Duration.zero,
        isInPipMode: () async => false,
      );
      expect(result, isTrue);
    });

    test('pipEntering flag wins even if isInPipMode query returns false',
        () async {
      final result = await CallController.resolveBackgroundCameraPause(
        state: AppLifecycleState.paused,
        nativeCallHeld: false,
        pipEntering: true,
        delay: Duration.zero,
        isInPipMode: () async => false,
      );
      expect(result, isFalse);
    });

    test('the query is deferred until after the debounce window', () async {
      var queried = false;
      final future = CallController.resolveBackgroundCameraPause(
        state: AppLifecycleState.paused,
        nativeCallHeld: false,
        pipEntering: false,
        delay: const Duration(milliseconds: 50),
        isInPipMode: () async {
          queried = true;
          return true;
        },
      );
      expect(queried, isFalse); // not queried synchronously
      expect(await future, isFalse);
      expect(queried, isTrue);
    });
  });

  group('PiP layout — VideoCallPipLayout', () {
    Widget wrap(Widget child, Size size) {
      return WidgetsApp(
        color: const Color(0xFF000000),
        builder: (context, _) => MediaQuery(
          data: MediaQueryData(size: size),
          child: SizedBox(width: size.width, height: size.height, child: child),
        ),
      );
    }

    testWidgets('camera-off placeholder never overflows at tiny PiP sizes',
        (tester) async {
      // ~90dp-tall landscape PiP window (smallest realistic Android PiP).
      await tester.pumpWidget(
        wrap(
          const VideoCallPipLayout(
            remoteRenderer: null,
            hasRemoteVideo: false,
            statusText: 'Camera off',
          ),
          const Size(220, 90),
        ),
      );
      expect(tester.takeException(), isNull);

      // Portrait 9:16 PiP.
      await tester.pumpWidget(
        wrap(
          const VideoCallPipLayout(
            remoteRenderer: null,
            hasRemoteVideo: false,
            statusText: 'Camera off',
          ),
          const Size(160, 285),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
