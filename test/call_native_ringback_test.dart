/// Structure tests for ff_call_native_ringback — the native iOS diagnostic
/// ringback path (option b): a Runner-owned AVAudioPlayer behind a separate
/// flag, with its own VantRingback os_log lines, bypassing audioplayers.
///
/// Asserts: flag wiring (default OFF everywhere), the Dart gate inside the
/// non-legacy ON path only, stop wiring on both stop methods, and the
/// AppDelegate implementation (channel cases, explicit setActive, looping
/// AVAudioPlayer, os_log lines, no session deactivation, no PushKit/CallKit
/// entanglement).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

String _section(String src, String startMarker, String endMarker) {
  final start = src.indexOf(startMarker);
  if (start < 0) return '';
  final end = src.indexOf(endMarker, start);
  if (end < 0) return src.substring(start);
  return src.substring(start, end);
}

void main() {
  final root = Directory.current.path;
  final flagSrc =
      _read('$root/lib/core/services/feature_flag_service.dart');
  final ringtoneSrc =
      _read('$root/lib/core/services/ringtone_service.dart');
  final appDelegateSrc = _read('$root/ios/Runner/AppDelegate.swift');

  group('ff_call_native_ringback flag wiring', () {
    test('constant exists, default OFF in all three places', () {
      expect(
        flagSrc.contains(
          "kCallNativeRingback = 'ff_call_native_ringback'",
        ),
        isTrue,
      );
      // Default OFF: Rx field, Remote Config defaults map.
      expect(flagSrc.contains('callNativeRingback = false.obs'), isTrue);
      expect(flagSrc.contains('kCallNativeRingback: false'), isTrue);
    });

    test('hydrate, apply and cache write mirror the other flags', () {
      expect(
        flagSrc.contains("_rc!.getBool(kCallNativeRingback)"),
        isTrue,
      );
      expect(
        flagSrc.contains("'ff_cache_\$kCallNativeRingback'"),
        isTrue,
      );
      expect(
        flagSrc.contains(
          "prefs.getBool('ff_cache_\$kCallNativeRingback')",
        ),
        isTrue,
      );
    });
  });

  group('Dart gate inside ringtone service', () {
    test('native path reads the disk cache like ff_call_ringback', () {
      expect(
        ringtoneSrc.contains(
          "prefs.getBool('ff_cache_ff_call_native_ringback') ?? false",
        ),
        isTrue,
      );
    });

    test('native branch lives only inside the non-legacy ON path, iOS only',
        () {
      final body = _section(
        ringtoneSrc,
        'Future<void> playOutgoingRingtone',
        'Future<void> _playOutgoingRingtoneLegacy',
      );
      // Invoked on the call channel, bool-checked like the Android path.
      expect(body.contains("invokeMethod<bool>('playNativeRingback')"), isTrue);
      expect(body.contains('nativeIosPath'), isTrue);
      // It must sit between the Android branch and the audioplayers iOS
      // branch — i.e. inside the ON path, after Platform.isAndroid.
      final androidAt = body.indexOf('Platform.isAndroid');
      final nativeAt = body.indexOf('else if (nativeIosPath)');
      final playerAt = body.indexOf('_startRingbackPlayer()');
      expect(nativeAt, greaterThan(androidAt));
      expect(nativeAt, lessThan(playerAt));
      // Legacy path must not contain it.
      final legacy = _section(
        ringtoneSrc,
        'Future<void> _playOutgoingRingtoneLegacy',
        'Future<void> _logAudioSessionState',
      );
      expect(legacy.contains('playNativeRingback'), isFalse);
    });

    test('stopNativeRingback is wired in BOTH stop methods', () {
      final stopOutgoing = _section(
        ringtoneSrc,
        'Future<void> stopOutgoingRingback',
        'Future<void> stopRingtone',
      );
      expect(stopOutgoing.contains('stopNativeRingback'), isTrue);
      final stopRingtone = _section(
        ringtoneSrc,
        'Future<void> stopRingtone',
        'Future<void> playConnectedTone',
      );
      expect(stopRingtone.contains('stopNativeRingback'), isTrue);
    });
  });

  group('AppDelegate native player', () {
    test('channel cases exist next to describeAudioSession', () {
      final describeAt = appDelegateSrc.indexOf('case "describeAudioSession"');
      final playAt = appDelegateSrc.indexOf('case "playNativeRingback"');
      final stopAt = appDelegateSrc.indexOf('case "stopNativeRingback"');
      expect(describeAt, greaterThan(-1));
      expect(playAt, greaterThan(describeAt));
      expect(stopAt, greaterThan(playAt));
      // Before the CallKit-adjacent cases — away from PushKit/CallKit logic.
      final orphanAt = appDelegateSrc.indexOf('case "endOrphanedCallKitCall"');
      expect(orphanAt, greaterThan(stopAt));
    });

    test('player is owned, looping, activated, and fully os_logged', () {
      expect(
        appDelegateSrc.contains('private var vantRingbackPlayer'),
        isTrue,
      );
      final body = _section(
        appDelegateSrc,
        'MARK: - Native caller ringback',
        'NO_END_MARKER_TO_EOF',
      );
      expect(body.contains('AVAudioPlayer(contentsOf:'), isTrue);
      expect(body.contains('numberOfLoops = -1'), isTrue);
      expect(body.contains('try session.setActive(true)'), isTrue);
      // os_log VantRingback lines: start, setActive error, asset missing,
      // play result, stop.
      expect(body.contains('"VantRingback start'), isTrue);
      expect(body.contains('"VantRingback setActive error'), isTrue);
      expect(body.contains('"VantRingback asset_missing'), isTrue);
      expect(body.contains('"VantRingback play ok='), isTrue);
      expect(body.contains('"VantRingback stop reason='), isTrue);
      // Never deactivates the session — WebRTC owns its lifecycle.
      expect(body.contains('setActive(false)'), isFalse);
      expect(body.contains('deactivateAudioSession'), isFalse);
    });

    test('no PushKit/CallKit interaction', () {
      final body = _section(
        appDelegateSrc,
        'MARK: - Native caller ringback',
        'NO_END_MARKER_TO_EOF',
      );
      expect(body.contains('PushKit'), isFalse);
      expect(body.contains('CXCall'), isFalse);
      expect(body.contains('reportNewIncomingCall'), isFalse);
      expect(body.contains('PKPush'), isFalse);
    });
  });
}
