import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/features/call/fsi_prompt_decision.dart';

String source(String path) => File(path).readAsStringSync();

void main() {
  group('decideFsiPrompt', () {
    test('granted permission never shows the dialog', () {
      expect(
        decideFsiPrompt(canUseFullScreenIntent: true, dontAskAgain: false),
        FsiPromptDecision.granted,
      );
    });

    test('granted permission wins over dontAskAgain', () {
      expect(
        decideFsiPrompt(canUseFullScreenIntent: true, dontAskAgain: true),
        FsiPromptDecision.granted,
      );
    });

    test('granted permission wins over a pending missed-call prompt', () {
      expect(
        decideFsiPrompt(
          canUseFullScreenIntent: true,
          dontAskAgain: false,
          missedCallPromptPending: true,
        ),
        FsiPromptDecision.granted,
      );
    });

    test('denied permission prompts when user has not opted out', () {
      expect(
        decideFsiPrompt(canUseFullScreenIntent: false, dontAskAgain: false),
        FsiPromptDecision.showDialog,
      );
    });

    test('denied permission stays silent after "Don\'t ask again"', () {
      expect(
        decideFsiPrompt(canUseFullScreenIntent: false, dontAskAgain: true),
        FsiPromptDecision.skipDontAskAgain,
      );
    });

    test(
      'a pending missed-call prompt re-arms the dialog once even after '
      '"Don\'t ask again" — the user just lost a call to the suppressed UI',
      () {
        expect(
          decideFsiPrompt(
            canUseFullScreenIntent: false,
            dontAskAgain: true,
            missedCallPromptPending: true,
          ),
          FsiPromptDecision.showDialog,
        );
      },
    );

    test(
      'the dialog is reachable again after denial — unlike the old '
      'fsi_prompt_shown flag, "Later" is not persisted',
      () {
        // The decision is stateless: only an explicit dontAskAgain suppresses
        // the prompt. Each new check with dontAskAgain=false must decide
        // showDialog again.
        for (var i = 0; i < 3; i++) {
          expect(
            decideFsiPrompt(canUseFullScreenIntent: false, dontAskAgain: false),
            FsiPromptDecision.showDialog,
          );
        }
      },
    );
  });

  group('native integration (source checks)', () {
    const fcmService =
        'android/app/src/main/kotlin/com/vant/chat/VantFirebaseMessagingService.kt';
    const mainActivity =
        'android/app/src/main/kotlin/com/vant/chat/MainActivity.kt';

    test(
      'missed and cancelled calls flag the prompt via the Flutter '
      'SharedPreferences backend',
      () {
        final src = source(fcmService);
        for (final marker in [
          'handleMissedCall',
          'handleCallCancelled',
        ]) {
          final fnStart = src.indexOf('fun $marker');
          expect(fnStart, greaterThanOrEqualTo(0), reason: marker);
          final body = src.substring(
            fnStart,
            fnStart + 1500,
          );
          expect(
            body.contains('markMissedCallForFsiPrompt()'),
            isTrue,
            reason: '$marker must set the flag',
          );
        }
        expect(src, contains('"FlutterSharedPreferences"'));
        expect(src, contains('"flutter.fsi_prompt_after_missed_call"'));
      },
    );

    test(
      'Dart reads and consumes the one-shot missed-call flag',
      () {
        final src = source('lib/features/call/call_controller.dart');
        expect(src, contains("prefs.getBool('fsi_prompt_after_missed_call')"));
        expect(src, contains("prefs.remove('fsi_prompt_after_missed_call')"));
        expect(src, contains('missedCallPromptPending'));
      },
    );

    test(
      'settings button resolves the API 34 page and falls back to app '
      'notification settings when unresolvable',
      () {
        final src = source(mainActivity);
        expect(src, contains('resolveActivity(packageManager)'));
        expect(
          src,
          contains('Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT'),
        );
        expect(
          src,
          contains('Settings.ACTION_APP_NOTIFICATION_SETTINGS'),
        );
        expect(
          src,
          contains('Settings.ACTION_APPLICATION_DETAILS_SETTINGS'),
        );
        // The dedicated intent must be tried before the fallback — check order.
        final dedicated = src.indexOf(
          'Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT',
        );
        final fallback = src.indexOf('Settings.ACTION_APP_NOTIFICATION_SETTINGS');
        expect(dedicated, greaterThanOrEqualTo(0));
        expect(fallback, greaterThan(dedicated));
      },
    );
  });

  group('native call-UX fixes (source checks)', () {
    const callManager =
        'android/app/src/main/kotlin/com/vant/chat/VantCallManager.kt';
    const fcmService =
        'android/app/src/main/kotlin/com/vant/chat/VantFirebaseMessagingService.kt';
    const mainActivity =
        'android/app/src/main/kotlin/com/vant/chat/MainActivity.kt';
    const mainApplication =
        'android/app/src/main/kotlin/com/vant/chat/MainApplication.kt';
    const callFgService =
        'android/app/src/main/kotlin/com/vant/chat/CallForegroundService.kt';

    test(
      'PhoneAccount diagnostic reports unknown with the exception type and '
      'prefers permission-free selfManagedPhoneAccounts',
      () {
        final src = source(callManager);
        expect(src, contains('tm.selfManagedPhoneAccounts'));
        expect(src, contains('"unknown(\${e.javaClass.simpleName})"'));
        expect(src, isNot(contains('"error"')));
      },
    );

    test(
      'call channels are created at Application.onCreate, not only at first '
      'call',
      () {
        final app = source(mainApplication);
        expect(app, contains('CallForegroundService.createNotificationChannels(this)'));
        final svc = source(callFgService);
        // Single definition lives in the companion so both entry points share it.
        expect(
          svc,
          contains('fun createNotificationChannels(context: Context)'),
        );
      },
    );

    test(
      'background engine start and channel invoke run on the main thread',
      () {
        final src = source(fcmService);
        expect(src, contains('Handler(Looper.getMainLooper()).post'));
        final postIdx = src.indexOf('Handler(Looper.getMainLooper()).post');
        final engineIdx = src.indexOf(
          'startFlutterBackgroundEngine(callbackHandle)',
          postIdx,
        );
        final invokeIdx = src.indexOf(
          'channel.invokeMethod("MessagingBackground#onMessage"',
          postIdx,
        );
        expect(engineIdx, greaterThan(postIdx));
        expect(invokeIdx, greaterThan(postIdx));
      },
    );

    test(
      'cold-start answer shows a connect overlay until the Dart call screen '
      'reports visible, with a timeout safeguard',
      () {
        final src = source(mainActivity);
        expect(src, contains('showCallTransitionOverlay()'));
        expect(
          src,
          contains('removeCallTransitionOverlay("call-screen-visible")'),
        );
        expect(src, contains('removeCallTransitionOverlay("timeout")'));
        // Overlay only on the ANSWER_CALL cold start.
        final guard = src.indexOf('"com.vant.chat.ANSWER_CALL"');
        final show = src.indexOf('showCallTransitionOverlay()');
        expect(guard, greaterThanOrEqualTo(0));
        expect(show, greaterThan(guard));
      },
    );

    test(
      'audio routing uses availableCommunicationDevices (never TYPE_TELEPHONY '
      'as a setCommunicationDevice target)',
      () {
        final src = source(callManager);
        expect(src, contains('availableCommunicationDevices'));
        expect(src, contains('AudioDeviceInfo.TYPE_BUILTIN_EARPIECE'));
        expect(src, isNot(contains('AudioDeviceInfo.TYPE_TELEPHONY')));
      },
    );
  });
}
