/// Structure + unit tests for the caller-side ringback feature (Commit A).
///
/// Covers: ff_call_ringback wiring, the isCaller gate, the pure
/// shouldStartCallerRingback / shouldStopOutgoingRingback decision functions,
/// direction-guarded stops (a stale reset can never kill a live incoming ring
/// or a newer call's outgoing tone), Android channel result reporting, and
/// proof that the incoming ringtone path is unchanged.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/ringtone_service.dart';

String _read(String path) => File(path).readAsStringSync();

/// Extracts the body of a function/section between [startMarker] and the first
/// occurrence of [endMarker] after it. Returns empty string if not found.
String _section(String src, String startMarker, String endMarker) {
  final start = src.indexOf(startMarker);
  if (start < 0) return '';
  final end = src.indexOf(endMarker, start);
  if (end < 0) return src.substring(start);
  return src.substring(start, end);
}

void main() {
  final root = Directory.current.path;
  final controllerSrc =
      _read('$root/lib/features/call/call_controller.dart');
  final ringtoneSrc =
      _read('$root/lib/core/services/ringtone_service.dart');
  final flagSrc =
      _read('$root/lib/core/services/feature_flag_service.dart');
  final mainActivitySrc = _read(
    '$root/android/app/src/main/kotlin/com/vant/chat/MainActivity.kt',
  );

  group('ff_call_ringback flag wiring', () {
    test('flag constant and ON default exist', () {
      expect(flagSrc.contains("kCallRingback = 'ff_call_ringback'"), isTrue);
      expect(flagSrc.contains('callRingback = true.obs'), isTrue);
      // Cached to SharedPreferences like ff_ios_push_wake_reconnect
      expect(flagSrc.contains("'ff_cache_\$kCallRingback'"), isTrue);
      expect(flagSrc.contains('kCallRingback: true'), isTrue);
    });

    test('dialing site keeps today\'s isCaller gate and passes callId', () {
      final dialing = _section(
        controllerSrc,
        "case 'dialing':",
        'break;',
      );
      // The gate is exactly today's: flag is NOT read at the call site —
      // the service selects legacy vs new internally.
      expect(dialing.contains('if (isCaller.value)'), isTrue);
      expect(dialing.contains('playOutgoingRingtone('), isTrue);
      expect(dialing.contains('callId:'), isTrue);
      expect(dialing.contains('ff_cache_ff_call_ringback'), isFalse);
    });

    test('service reads the flag cache to select legacy vs new', () {
      expect(ringtoneSrc.contains("'ff_cache_ff_call_ringback'"), isTrue);
      expect(ringtoneSrc.contains('useLegacyRingbackPath('), isTrue);
      expect(ringtoneSrc.contains('_playOutgoingRingtoneLegacy()'), isTrue);
    });
  });

  group('useLegacyRingbackPath (pure selector, real cached values)', () {
    // The cache stores the flag VALUE: true = flag ON. Legacy must be chosen
    // only for an explicit cached false; true or missing means new path.
    test('cached ON (true) → new path', () {
      expect(
        RingtoneService.useLegacyRingbackPath(cachedFlagValue: true),
        isFalse,
      );
    });

    test('explicit cached OFF (false) → legacy path', () {
      expect(
        RingtoneService.useLegacyRingbackPath(cachedFlagValue: false),
        isTrue,
      );
    });

    test('missing cache (null) → new path', () {
      expect(
        RingtoneService.useLegacyRingbackPath(cachedFlagValue: null),
        isFalse,
      );
    });
  });

  group('call-site wiring (regression for the inverted-flag bug)', () {
    test('call site passes the raw cached value, not an inverted one', () {
      // The cache read must go in unmodified — the selector decides.
      expect(
        ringtoneSrc.contains(
          'cachedFlagValue: prefs.getBool(\'ff_cache_ff_call_ringback\')',
        ),
        isTrue,
      );
      // And the selector's contract: legacy iff the value is explicitly false.
      expect(
        ringtoneSrc.contains('return cachedFlagValue == false;'),
        isTrue,
      );
      // No stale "off"-polarity parameter may remain anywhere in the file.
      expect(ringtoneSrc.contains('cachedFlagOff'), isFalse);
    });
  });

  group('ringback.wav asset is bundled', () {
    test('file exists, is git-tracked and not ignored, pubspec declares dir',
        () {
      // Exists on disk.
      expect(
        File('assets/audio/ringback.wav').existsSync(),
        isTrue,
        reason: 'assets/audio/ringback.wav missing from the working tree',
      );
      // Declared via the directory entry under flutter: assets:.
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec.contains('- assets/audio/'), isTrue);
      // Git-tracked — an ignored/untracked asset is absent from CI
      // checkouts and fails with "Unable to load asset" in release builds.
      final ls = Process.runSync(
        'git',
        ['ls-files', 'assets/audio/ringback.wav'],
        workingDirectory: Directory.current.path,
      );
      expect(
        (ls.stdout as String).trim(),
        'assets/audio/ringback.wav',
        reason: 'ringback.wav is not tracked by git',
      );
      // And no ignore rule may match it (the *.wav blanket rule regressed
      // this once — the !assets/audio/*.wav exception must stay).
      final ignored = Process.runSync(
        'git',
        ['check-ignore', 'assets/audio/ringback.wav'],
        workingDirectory: Directory.current.path,
      );
      expect(
        ignored.exitCode,
        isNot(0),
        reason: 'ringback.wav must not be matched by any gitignore rule',
      );
    });
  });

  group('shouldStopOutgoingRingback (pure direction guard)', () {
    test('stale reset vs live incoming ring → never stops it', () {
      // An incoming ringtone playing means no outgoing ringback is active:
      // the guard must refuse unconditionally.
      expect(
        RingtoneService.shouldStopOutgoingRingback(
          playingOutgoing: false,
          outgoingCallId: null,
          requestedCallId: 'old-call',
        ),
        isFalse,
      );
      expect(
        RingtoneService.shouldStopOutgoingRingback(
          playingOutgoing: false,
        ),
        isFalse,
      );
    });

    test('stale reset vs live outgoing ring of a different call → refused', () {
      // Reset for call-1 must not stop call-2's ringback.
      expect(
        RingtoneService.shouldStopOutgoingRingback(
          playingOutgoing: true,
          outgoingCallId: 'call-2',
          requestedCallId: 'call-1',
        ),
        isFalse,
      );
    });

    test('matching call id → stops', () {
      expect(
        RingtoneService.shouldStopOutgoingRingback(
          playingOutgoing: true,
          outgoingCallId: 'call-1',
          requestedCallId: 'call-1',
        ),
        isTrue,
      );
    });

    test('unknown ids degrade to allow (missing callId must not wedge tone)',
        () {
      expect(
        RingtoneService.shouldStopOutgoingRingback(
          playingOutgoing: true,
          outgoingCallId: null,
          requestedCallId: 'call-9',
        ),
        isTrue,
      );
      expect(
        RingtoneService.shouldStopOutgoingRingback(
          playingOutgoing: true,
          outgoingCallId: 'call-1',
          requestedCallId: null,
        ),
        isTrue,
      );
    });
  });

  group('stop paths in RingtoneService', () {
    test('stopOutgoingRingback never touches the incoming player', () {
      final body = _section(
        ringtoneSrc,
        'Future<void> stopOutgoingRingback',
        '/// Stop ringtone playback',
      );
      expect(body.isNotEmpty, isTrue);
      // Must not invoke FlutterRingtonePlayer — that would kill a live
      // incoming ringtone for a different call.
      expect(body.contains('FlutterRingtonePlayer()'), isFalse);
      expect(body.contains('FlutterRingtonePlayer().stop'), isFalse);
      expect(body.contains('_playingOutgoing = false'), isTrue);
      expect(body.contains('stopRingback'), isTrue);
      expect(body.contains('reason'), isTrue);
    });

    test('playOutgoingRingtone marks direction and checks Android result', () {
      final body = _section(
        ringtoneSrc,
        'Future<void> playOutgoingRingtone',
        'Future<void> _playOutgoingRingtoneLegacy',
      );
      expect(body.contains('_playingOutgoing = true'), isTrue);
      expect(body.contains("_outgoingCallId = "), isTrue);
      // Android failure must surface as the Dart-side error
      expect(body.contains("invokeMethod<bool>('playRingback')"), isTrue);
      expect(body.contains('ok == false'), isTrue);
      expect(body.contains('Error playing outgoing tone'), isTrue);
    });

    test('legacy path is byte-for-byte the pre-flag implementation', () {
      final body = _section(
        ringtoneSrc,
        'Future<void> _playOutgoingRingtoneLegacy',
        'Future<void> _logAudioSessionState',
      );
      expect(body.isNotEmpty, isTrue);
      // Android: fire-and-forget invoke, NO result check (today's behaviour)
      expect(body.contains("invokeMethod('playRingback')"), isTrue);
      expect(body.contains('invokeMethod<bool>'), isFalse);
      // iOS: the verbatim legacy player (with setAudioContext)
      expect(body.contains('await _startRingbackPlayerLegacy();'), isTrue);
      // No new machinery may leak into the legacy path
      expect(body.contains('_playingOutgoing = true'), isFalse);
      expect(body.contains('_outgoingCallId'), isFalse);
      expect(body.contains('CallPhaseLogger'), isFalse);
      expect(body.contains('print('), isFalse);
    });

    test('_resetCallState uses the guarded outgoing stop', () {
      final reset = _section(
        controllerSrc,
        'void _resetCallState()',
        'CallPhaseLogger.stop()',
      );
      expect(
        reset.contains(
          "stopOutgoingRingback(callId: callId, reason: 'error')",
        ),
        isTrue,
      );
    });

    test('reasoned stops exist for every required termination path', () {
      for (final reason in [
        "'connected'",
        "'rejected'",
        "'cancelled'",
        "'timeout'",
        "'ended'",
      ]) {
        expect(
          controllerSrc.contains('stopRingtone(reason: $reason)'),
          isTrue,
          reason: 'missing stopRingtone(reason: $reason)',
        );
      }
    });
  });

  group('Android native ringback (minimal diff, unchanged tone)', () {
    test('playRingback reports success/failure over the channel', () {
      expect(
        mainActivitySrc.contains('result.success(playRingback())'),
        isTrue,
      );
      expect(
        mainActivitySrc.contains('private fun playRingback(): Boolean'),
        isTrue,
      );
      expect(mainActivitySrc.contains('return try {'), isTrue);
    });

    test('tone type, volume and stream are unchanged', () {
      expect(
        mainActivitySrc.contains(
          'ToneGenerator(AudioManager.STREAM_VOICE_CALL, 80)',
        ),
        isTrue,
      );
      expect(
        mainActivitySrc.contains('ToneGenerator.TONE_SUP_RINGTONE'),
        isTrue,
      );
      expect(
        mainActivitySrc.contains('AudioManager.STREAM_VOICE_CALL'),
        isTrue,
      );
    });

    test('stopRingback accepts and logs a reason', () {
      expect(
        mainActivitySrc.contains(
          'stopRingback(call.argument<String>("reason"))',
        ),
        isTrue,
      );
      expect(
        mainActivitySrc.contains('private fun stopRingback(reason: String?'),
        isTrue,
      );
      expect(mainActivitySrc.contains('Ringback stopped (reason='), isTrue);
    });
  });

  group('Commit B: split iOS ringback players', () {
    test('legacy OFF player retains setAudioContext byte-for-byte', () {
      final body = _section(
        ringtoneSrc,
        'Future<void> _startRingbackPlayerLegacy',
        'Future<void> playOutgoingTone',
      );
      expect(body.isNotEmpty, isTrue);
      expect(
        body.contains(
          'setAudioContext(\n'
          '      AudioContext(\n'
          '        iOS: AudioContextIOS(\n'
          '          category: AVAudioSessionCategory.playAndRecord,\n'
          '          options: {},\n'
          '        ),\n'
          '      ),\n'
          '    )',
        ),
        isTrue,
        reason: 'OFF path must keep setAudioContext(playAndRecord,{})',
      );
    });

    test('new ON player has no setAudioContext', () {
      final body = _section(
        ringtoneSrc,
        'Future<void> _startRingbackPlayer()',
        'Future<void> _startRingbackPlayerLegacy',
      );
      expect(body.isNotEmpty, isTrue);
      expect(body.contains('_ringbackPlayer!.setAudioContext'), isFalse);
      // Same asset/volume/loop as before — only the session call is gone
      expect(body.contains('setVolume(0.8)'), isTrue);
      expect(body.contains('ReleaseMode.loop'), isTrue);
      expect(body.contains("AssetSource('audio/ringback.wav')"), isTrue);
    });
  });

  group('Commit C: session activation on the ON path', () {
    test('setActive(true) runs before play() on the ON path', () {
      final body = _section(
        ringtoneSrc,
        'Future<void> _startRingbackPlayer()',
        'Future<void> _startRingbackPlayerLegacy',
      );
      expect(body.contains('AudioSession.instance'), isTrue);
      expect(body.contains('setActive('), isTrue);
      // Activation strictly before the player starts
      final activateAt = body.indexOf('setActive(');
      final playAt = body.indexOf("play(AssetSource('audio/ringback.wav'))");
      expect(activateAt, greaterThanOrEqualTo(0));
      expect(playAt, greaterThan(activateAt));
      // Diagnostics: session dump before and after activation
      expect(body.contains("_logAudioSessionState('pre')"), isTrue);
      expect(body.contains("_logAudioSessionState('post')"), isTrue);
      expect(ringtoneSrc.contains("'describeAudioSession'"), isTrue);
      // The whole activation is inside try/catch — a failure must fall
      // through to play() rather than abort the ringback attempt
      expect(body.contains('} catch (e) {'), isTrue);
    });

    test('never deactivates the session and never calls configure()', () {
      expect(ringtoneSrc.contains('setActive(false'), isFalse);
      expect(ringtoneSrc.contains('.configure('), isFalse);
      // No setAudioContext call anywhere in the new player either
      final body = _section(
        ringtoneSrc,
        'Future<void> _startRingbackPlayer()',
        'Future<void> _startRingbackPlayerLegacy',
      );
      expect(body.contains('_ringbackPlayer!.setAudioContext'), isFalse);
    });

    test('activation failure cannot escape the try/catch or stop the call',
        () {
      final body = _section(
        ringtoneSrc,
        'Future<void> _startRingbackPlayer()',
        'Future<void> _startRingbackPlayerLegacy',
      );
      // catch block exists before setVolume — the player attempt follows it
      final catchAt = body.indexOf('} catch (e) {');
      final volumeAt = body.indexOf('setVolume(0.8)');
      expect(catchAt, greaterThanOrEqualTo(0));
      expect(volumeAt, greaterThan(catchAt));
    });

    test('fallback config mirrors WebRTC session values (no real change)', () {
      final body = _section(
        ringtoneSrc,
        'Future<void> _startRingbackPlayer()',
        'Future<void> _startRingbackPlayerLegacy',
      );
      expect(body.contains('fallbackConfiguration'), isTrue);
      expect(body.contains('playAndRecord'), isTrue);
      expect(body.contains('voiceChat'), isTrue);
      expect(body.contains('_ringbackSessionOptions'), isTrue);
      // The shared options constant mirrors ensureAudioSessionWithRecording
      expect(ringtoneSrc.contains('allowBluetooth'), isTrue);
      expect(ringtoneSrc.contains('allowBluetoothA2dp'), isTrue);
      expect(ringtoneSrc.contains('allowAirPlay'), isTrue);
    });

    test('legacy OFF path has no activation or diagnostics', () {
      final body = _section(
        ringtoneSrc,
        'Future<void> _playOutgoingRingtoneLegacy',
        '/// Release-visible dump',
      );
      expect(body.contains('AudioSession'), isFalse);
      expect(body.contains('setActive'), isFalse);
      expect(body.contains('describeAudioSession'), isFalse);
    });

    test('native describeAudioSession case exists and is read-only', () {
      final appDelegate = _read(
        '$root/ios/Runner/AppDelegate.swift',
      );
      final body = _section(
        appDelegate,
        'case "describeAudioSession"',
        'case "endOrphanedCallKitCall"',
      );
      expect(body.isNotEmpty, isTrue);
      expect(body.contains('session.category.rawValue'), isTrue);
      expect(body.contains('session.mode.rawValue'), isTrue);
      expect(body.contains('currentRoute'), isTrue);
      expect(body.contains('isOtherAudioPlaying'), isTrue);
      expect(body.contains('result('), isTrue);
      // Read-only: no mutating calls inside the case
      expect(body.contains('setActive'), isFalse);
      expect(body.contains('setCategory'), isFalse);
      expect(body.contains('setMode'), isFalse);
      expect(body.contains('overrideOutputAudioPort'), isFalse);
    });
  });

  group('incoming path unchanged', () {
    test('playIncomingRingtone still uses FlutterRingtonePlayer', () {
      final body = _section(
        ringtoneSrc,
        'Future<void> playIncomingRingtone',
        'Future<void> playOutgoingRingtone',
      );
      expect(body.isNotEmpty, isTrue);
      expect(body.contains('_playRingtoneLoop()'), isTrue);
      expect(body.contains('FlutterRingtonePlayer()'), isTrue);
      // No caller-ringback machinery may have leaked into the incoming path
      expect(body.contains('playRingback'), isFalse);
      expect(body.contains("AssetSource('audio/ringback.wav')"), isFalse);
      expect(body.contains('setAudioContext'), isFalse);
      expect(body.contains('_playingOutgoing'), isFalse);
    });

    test('generic stopRingtone still stops the incoming player', () {
      final body = _section(
        ringtoneSrc,
        'Future<void> stopRingtone',
        'Future<void> playConnectedTone',
      );
      expect(body.contains('FlutterRingtonePlayer().stop()'), isTrue);
    });

    test('callkit/incoming wiring references are intact', () {
      // The incoming-screen ownership suppression from 216b must be untouched
      // by this change.
      expect(
        controllerSrc.contains('suppressIncomingUiForPushCall'),
        isTrue,
      );
      expect(controllerSrc.contains('isPushKitCallOwned'), isTrue);
    });
  });
}
