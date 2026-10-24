import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/features/call/call_controller.dart';

void main() {
  group('iOS incoming-call UI ownership (hotfix 1.9.2)', () {
    test('foreground states show the Flutter incoming screen', () {
      // A socket-delivered incoming_call on a visible app must ring + show the
      // Flutter screen — this is the 1.6.7 behavior the hotfix restores after
      // the fail-closed guard made foregrounded iPhones silent.
      expect(
        CallController.isBackgroundedForIncomingCall(AppLifecycleState.resumed),
        isFalse,
      );
      expect(
        CallController.isBackgroundedForIncomingCall(AppLifecycleState.inactive),
        isFalse,
      );
    });

    test('background states defer to the PushKit/CallKit path', () {
      // When the app is not visible, CallKit owns the incoming-call UI; showing
      // the Flutter copy too would produce double screens and double ringtones.
      for (final state in [
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.detached,
        null,
      ]) {
        expect(
          CallController.isBackgroundedForIncomingCall(state),
          isTrue,
          reason: '$state must defer the call UI to CallKit',
        );
      }
    });

    test('_isAppInBackground derives iOS from lifecycle, not fail-closed', () {
      final source =
          File('lib/features/call/call_controller.dart').readAsStringSync();
      final fnStart = source.indexOf('Future<bool> _isAppInBackground()');
      expect(fnStart, isNot(-1));
      final fnBody = source.substring(fnStart, fnStart + 1400);
      // The iOS branch must consult the real lifecycle state...
      expect(
        fnBody,
        contains('isBackgroundedForIncomingCall'),
        reason: 'iOS must derive background state from the app lifecycle',
      );
      expect(
        fnBody,
        contains('WidgetsBinding.instance.lifecycleState'),
      );
      // ...and must NOT be the fail-closed `return true` that made a
      // foregrounded iPhone drop every socket-delivered incoming call.
      final tryIndex = fnBody.indexOf('try {');
      final iosBranch = fnBody.substring(
        0,
        tryIndex == -1 ? fnBody.length : tryIndex,
      );
      expect(
        iosBranch.contains('return true;'),
        isFalse,
        reason: 'iOS branch must not unconditionally return true',
      );
    });

    test('_isScreenLocked returns false on iOS (lifecycle covers lock)', () {
      final source =
          File('lib/features/call/call_controller.dart').readAsStringSync();
      final fnStart = source.indexOf('Future<bool> _isScreenLocked()');
      expect(fnStart, isNot(-1));
      final fnBody = source.substring(fnStart, fnStart + 400);
      expect(
        fnBody,
        contains('if (!Platform.isAndroid) return false;'),
        reason:
            'On iOS the screen lock drops the app out of resumed, so '
            '_isAppInBackground covers it — this must not also fail closed',
      );
    });

    test('Android channel behaviour is unchanged', () {
      final source =
          File('lib/features/call/call_controller.dart').readAsStringSync();
      // Android still uses the native MethodChannel for both checks and still
      // fails closed when the channel cannot answer (headless engine).
      final bgStart = source.indexOf('Future<bool> _isAppInBackground()');
      final bgBody = source.substring(bgStart, bgStart + 1400);
      expect(
        bgBody,
        contains("invokeMethod<bool>('isAppInBackground')"),
      );
      expect(
        bgBody,
        contains('return true;'),
        reason: 'Android catch path must still fail closed',
      );

      final lockStart = source.indexOf('Future<bool> _isScreenLocked()');
      final lockBody = source.substring(lockStart, lockStart + 900);
      expect(
        lockBody,
        contains("invokeMethod<bool>('isScreenLocked')"),
      );

      // The incoming-call early return still requires background/locked —
      // the gating logic itself is untouched.
      expect(
        source,
        contains('if (appInBackground || screenLocked)'),
      );
    });
  });
}
