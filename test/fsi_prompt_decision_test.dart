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

    test('install prompt is one-shot — shown once, then silent', () {
      expect(
        decideFsiPrompt(
          canUseFullScreenIntent: false,
          dontAskAgain: false,
          installPromptShown: true,
        ),
        FsiPromptDecision.skipAlreadyShown,
      );
    });

    test('a missed call re-arms the dialog even after the install prompt', () {
      expect(
        decideFsiPrompt(
          canUseFullScreenIntent: false,
          dontAskAgain: false,
          installPromptShown: true,
          missedCallPromptPending: true,
        ),
        FsiPromptDecision.showDialog,
      );
    });

    test('"Don\'t ask again" still wins over the install prompt flag', () {
      expect(
        decideFsiPrompt(
          canUseFullScreenIntent: false,
          dontAskAgain: true,
          installPromptShown: true,
        ),
        FsiPromptDecision.skipDontAskAgain,
      );
    });

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
        expect(src, contains('"call-screen-visible"'));
        expect(src, contains('removeCallTransitionOverlay("timeout")'));
        // Overlay only on the ANSWER_CALL cold start.
        final guard = src.indexOf('"com.vant.chat.ANSWER_CALL"');
        final show = src.indexOf('showCallTransitionOverlay()');
        expect(guard, greaterThanOrEqualTo(0));
        expect(show, greaterThan(guard));
      },
    );

    test(
      'overlay is also removed on decline, call-screen-hidden and destroy — '
      'and only ever created under the ANSWER_CALL guard',
      () {
        final src = source(mainActivity);
        expect(src, contains('removeCallTransitionOverlay("decline")'));
        expect(src, contains('"call-screen-hidden"'));
        expect(src, contains('callOverlayHandler.removeCallbacksAndMessages'));
        // The only creation site is the onCreate ANSWER_CALL check.
        final creations = 'showCallTransitionOverlay()'.allMatches(src);
        // one call site in onCreate + the function definition itself
        expect(creations.length, lessThanOrEqualTo(2));
      },
    );

    test(
      'incoming-call notifications post on the v2 channel and are not '
      'marked silent — silent notifications are demoted from heads-up',
      () {
        for (final file in [callManager, callFgService]) {
          final src = source(file);
          expect(src, contains('"vant_chat_calls_v2"'));
          // The only permitted v1 reference is the deleteNotificationChannel
          // cleanup of the stale channel.
          final withoutCleanup = src.replaceAll(
            'deleteNotificationChannel("vant_chat_calls")',
            '',
          );
          expect(withoutCleanup, isNot(contains('"vant_chat_calls"')));
        }
        // Scope assertions to the incoming-call builders only — the ongoing-
        // call notification (ONGOING_CHANNEL_ID) legitimately stays silent.
        final mgr = source(callManager);
        final showFn = mgr.indexOf('fun showCallNotification');
        expect(showFn, greaterThanOrEqualTo(0));
        final mgrBuilder = mgr.substring(
          showFn,
          showFn + 6000 > mgr.length ? mgr.length : showFn + 6000,
        );
        expect(mgrBuilder, isNot(contains('.setSilent(')));

        final svc = source(callFgService);
        final buildFn = svc.indexOf('private fun buildCallNotification');
        expect(buildFn, greaterThanOrEqualTo(0));
        final svcBuilder = svc.substring(buildFn);
        expect(svcBuilder, isNot(contains('.setSilent(')));
      },
    );

    test(
      'the v2 call channel has no sound — the app Ringtone is the single '
      'sound source (no double ring)',
      () {
        final svc = source(callFgService);
        final createFn = svc.indexOf('fun createNotificationChannels');
        expect(createFn, greaterThanOrEqualTo(0));
        final body = svc.substring(createFn, createFn + 3000);
        expect(body, contains('setSound(null, null)'));
        // Channel vibration off — the service Vibrator is the single source.
        expect(body, contains('enableVibration(false)'));
        // The incoming-call channel (CHANNEL_ID = vant_chat_calls_v2) must
        // not carry a ringtone URI anywhere in channel creation.
        expect(body, isNot(contains('TYPE_RINGTONE')));
        // Ringtone still played by the service itself.
        expect(svc, contains('RingtoneManager.getRingtone'));
        expect(svc, contains('vibrator?.vibrate('));
        // Stale v1 channel is deleted so existing installs don't keep a
        // duplicate "Incoming Calls" entry.
        expect(
          body,
          contains('deleteNotificationChannel("vant_chat_calls")'),
        );
      },
    );

    test(
      'Dart persists the one-shot install prompt flag',
      () {
        final src = source('lib/features/call/call_controller.dart');
        expect(src, contains("prefs.getBool('fsi_install_prompt_shown')"));
        expect(src, contains("prefs.setBool('fsi_install_prompt_shown', true)"));
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

  group('forwarding guards and accept latency (source checks)', () {
    const fcmService =
        'android/app/src/main/kotlin/com/vant/chat/VantFirebaseMessagingService.kt';
    const mainActivity =
        'android/app/src/main/kotlin/com/vant/chat/MainActivity.kt';
    const callController = 'lib/features/call/call_controller.dart';

    test(
      'background forwarding is skipped while a Telecom connection exists',
      () {
        final src = source(fcmService);
        expect(
          src,
          contains('VantCallManager.activeConnection != null'),
        );
        // Guard sits before the main-thread engine start.
        final guard = src.indexOf('VantCallManager.activeConnection != null');
        final post = src.indexOf('Handler(Looper.getMainLooper()).post');
        expect(guard, greaterThanOrEqualTo(0));
        expect(guard, lessThan(post));
      },
    );

    test(
      'engine start is still gated by the flutterEngineStarted atomic inside '
      'the main-thread post (burst-safe)',
      () {
        final src = source(fcmService);
        final post = src.indexOf('Handler(Looper.getMainLooper()).post');
        final gate = src.indexOf('!flutterEngineStarted.get()', post);
        expect(gate, greaterThan(post));
      },
    );

    test(
      'handleCallIntent pushes onPendingCallAction when the engine is '
      'attached and keeps the flag for the poll fallback',
      () {
        final src = source(mainActivity);
        expect(src, contains('pushPendingCallActionToDart()'));
        expect(src, contains('"onPendingCallAction"'));
        // The unsafe getter (NPEs while the delegate is unattached) must not
        // be used in handleCallIntent.
        expect(
          src.indexOf('flutterEngine?.let', src.indexOf('handleCallIntent')),
          lessThan(0),
        );
        // The flag is only cleared inside the getPendingCallAction handler —
        // the push/retry path must never clear it first.
        final push = src.indexOf('pushPendingCallActionToDart()');
        expect(
          src.indexOf('pendingCallAction = null', push),
          lessThan(0),
        );
      },
    );

    test(
      'Dart consumes the pushed nudge through the same getPendingCallAction '
      'path (single consumption)',
      () {
        final src = source(callController);
        expect(src, contains('_incomingCallChannel.setMethodCallHandler'));
        expect(src, contains("call.method == 'onPendingCallAction'"));
        expect(src, contains('_checkPendingCallAction()'));
      },
    );

    test(
      'TURN/STUN prefetch fires during ringing and primes the ICE list',
      () {
        final src = source(callController);
        expect(src, contains('_prefetchIceServersDuringRinging()'));
        expect(src, contains('requestIceServers()'));
        expect(src, contains('primeIceServers(servers)'));
        // Fired from both incoming-call entry points.
        expect(
          '_prefetchIceServersDuringRinging()'.allMatches(src).length,
          greaterThanOrEqualTo(3), // helper body + two call sites
        );
        expect(src, contains('_iceServersPrefetched = false'));
      },
    );
  });

  group('ringing-time latency stages (source checks)', () {
    const fcmService =
        'android/app/src/main/kotlin/com/vant/chat/VantFirebaseMessagingService.kt';
    const mainActivity =
        'android/app/src/main/kotlin/com/vant/chat/MainActivity.kt';
    const callManager =
        'android/app/src/main/kotlin/com/vant/chat/VantCallManager.kt';
    const callController = 'lib/features/call/call_controller.dart';
    const webrtcService = 'lib/core/services/webrtc_call_service.dart';
    const encIndicator = 'lib/features/call/call_encryption_indicator.dart';

    test(
      'FCM pre-warms a cached engine during ringing, guarded against an '
      'active call and duplicate pushes, with a timeout destroy',
      () {
        final src = source(fcmService);
        expect(src, contains('prewarmCallEngine(callId)'));
        expect(src, contains('FlutterEngineCache.getInstance()'));
        expect(src, contains('CALL_PREWARM_ENGINE_ID'));
        expect(
          src.indexOf('VantCallManager.activeConnection != null',
              src.indexOf('private fun prewarmCallEngine')),
          greaterThanOrEqualTo(0),
        );
        expect(src, contains('DartExecutor.DartEntrypoint.createDefault()'));
        expect(src, contains('PREWARM_TIMEOUT_MS'));
        expect(src, contains('discardPrewarmEngine'));
      },
    );

    test(
      'pre-warm engine is discarded on cancel, missed call, and call '
      'teardown — and the ringing marker is cleared',
      () {
        final fcm = source(fcmService);
        final cancelIdx = fcm.indexOf('private fun handleCallCancelled');
        final missedIdx = fcm.indexOf('private fun handleMissedCall');
        expect(
          fcm.indexOf('discardPrewarmEngine()', cancelIdx),
          lessThan(fcm.indexOf('private fun handleMissedCall')),
        );
        expect(
          fcm.indexOf('discardPrewarmEngine()', missedIdx),
          greaterThan(missedIdx),
        );
        expect(fcm, contains('"flutter.ringing_call_id"'));
        // Call teardown (decline/end) also discards it.
        final mgr = source(callManager);
        expect(
          mgr,
          contains('VantFirebaseMessagingService.discardPrewarmEngine()'),
        );
      },
    );

    test(
      'MainActivity attaches the cached engine and owns its lifecycle after '
      'removal from the cache',
      () {
        final src = source(mainActivity);
        expect(src, contains('override fun getCachedEngineId()'));
        expect(
          src,
          contains('contains(VantFirebaseMessagingService.CALL_PREWARM_ENGINE_ID)'),
        );
        expect(src, contains('usedPrewarmEngine = true'));
        // The cached engine is destroyed with the host activity (the
        // framework default for cached engines is to outlive the host).
        expect(src, contains('override fun shouldDestroyEngineWithHost()'));
        // Never pre-warm while the main engine is alive — a duplicate
        // isolate re-registers the deviceId and the server kicks the
        // primary socket (killed the warm call's signaling).
        final fcm = source(fcmService);
        expect(fcm, contains('MainActivity.isMainActivityAlive'));
        expect(src, contains('liveInstanceCount'));
      },
    );

    test(
      'pending-action push retries while Dart may still be registering its '
      'handler on a pre-warmed engine',
      () {
        final src = source(mainActivity);
        expect(src, contains('fun retryPendingPush'));
        expect(src, contains('pendingPushRetries'));
        expect(src, contains('notImplemented()'));
      },
    );

    test(
      'ringing marker drives a proactive resync that only caches the offer '
      'until a pending auto-accept exists',
      () {
        final src = source(callController);
        expect(src, contains("prefs.getString('ringing_call_id')"));
        expect(src, contains('_ringingCallId'));
        expect(src, contains('requestCallResync(callId: callId)'));
        expect(src, contains('_pendingAutoAcceptCallId == callId'));
        expect(src, contains('Resync offer cached during ringing'));
      },
    );

    test(
      'PeerConnection + remote offer are prepared during ringing and reused '
      'on accept; stale prepares are cleaned up',
      () {
        final svc = source(webrtcService);
        expect(svc, contains('prepareIncomingCall'));
        expect(svc, contains('_incomingPrepared'));
        expect(svc, contains('Reusing PeerConnection prepared during ringing'));
        // acceptCall skips a duplicate remote-description set when prepared.
        expect(svc, contains('if (!prepared)'));
        // _endCall resets the flag.
        final endIdx = svc.indexOf('Future<void> _endCall()');
        expect(svc.indexOf('_incomingPrepared = false', endIdx), greaterThan(0));
        final cc = source(callController);
        expect(cc, contains('_prepareIncomingWebRtc'));
      },
    );

    test(
      'encryption indicator holds a single Connecting state until the call '
      'is connected',
      () {
        final ind = source(encIndicator);
        expect(ind, contains('CallEncryptionState.connecting'));
        expect(ind, contains("'Connecting…'"));
        // Intermediate states render nothing — only the final outcome shows.
        expect(ind, contains('Visibility('));
        expect(ind, contains('_isFinal'));
        final cc = source(callController);
        expect(cc, contains('CallEncryptionState.connecting.obs'));
        expect(
          cc.indexOf(
            'callEncryptionState.value = CallEncryptionState.connecting',
          ),
          greaterThanOrEqualTo(0),
        );
      },
    );
  });
}
