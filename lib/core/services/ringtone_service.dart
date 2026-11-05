import 'dart:async';
import 'dart:io' show Platform;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart' as audio_session;
import 'call_phase_logger.dart';

/// Ringtone Service - Manages call ringtone playback
/// Handles incoming call ringtones and outgoing call tones using system sounds
class RingtoneService {
  static final RingtoneService _instance = RingtoneService._internal();
  factory RingtoneService() => _instance;
  RingtoneService._internal();

  static const MethodChannel _audioChannel = MethodChannel(
    'com.pear.messaging/audio',
  );
  static const MethodChannel _callChannel = MethodChannel(
    'com.pear.messaging/call',
  );

  // Matches the options flutter_webrtc sets in ensureAudioSessionWithRecording
  // so audio_session's implicit fallback configure (which fires if this
  // AudioSession instance was never configured) applies identical values —
  // never a real category/mode/options change.
  static final audio_session.AVAudioSessionCategoryOptions
      _ringbackSessionOptions =
      audio_session.AVAudioSessionCategoryOptions.allowBluetooth |
          audio_session.AVAudioSessionCategoryOptions.allowBluetoothA2dp |
          audio_session.AVAudioSessionCategoryOptions.allowAirPlay;

  bool _isPlaying = false;
  AudioPlayer? _ringbackPlayer;
  // Direction tracking: which tone is playing and for which call, so a stale
  // reset from a previous call can never stop a newer call's outgoing tone or
  // a live incoming ringtone.
  bool _playingOutgoing = false;
  String? _outgoingCallId;

  /// Play incoming call ringtone
  /// Loops the ringtone until call is answered or declined
  /// Uses system default ringtone (like WhatsApp)
  Future<void> playIncomingRingtone() async {
    if (_isPlaying) {
      debugPrint('🔔 RingtoneService: Ringtone already playing');
      return;
    }

    try {
      _isPlaying = true;

      debugPrint(
        '🔔 RingtoneService: Playing incoming ringtone (system default)',
      );

      // Play ringtone in a loop
      _playRingtoneLoop();
    } catch (e) {
      debugPrint('❌ RingtoneService: Error playing ringtone: $e');
      _isPlaying = false;
    }
  }

  /// Play ringtone in a loop
  void _playRingtoneLoop() {
    if (!_isPlaying) return;

    // Play system ringtone
    FlutterRingtonePlayer().play(
      android: AndroidSounds.ringtone,
      ios: IosSounds.glass,
      looping: false, // We handle looping manually
      asAlarm: false,
    );

    // Schedule next ring after ringtone duration (typically 2-3 seconds)
    // _ringTimer = Timer(const Duration(seconds: 3), () {
    //   if (_isPlaying && _ringCount < 30) {
    //     // Ring for up to 30 cycles (90 seconds)
    //     _playRingtoneLoop();
    //   } else {
    //     stopRingtone();
    //   }
    // });
  }

  /// Pure selector for ff_call_ringback: only an explicit cached `false`
  /// chooses the legacy implementation; a missing key means the new path.
  /// [cachedFlagValue] is the raw ff_cache_ value — true means flag ON.
  static bool useLegacyRingbackPath({required bool? cachedFlagValue}) {
    return cachedFlagValue == false;
  }

  /// Play outgoing ringback tone (looping) — heard by caller through earpiece
  Future<void> playOutgoingRingtone({String? callId}) async {
    if (_isPlaying) {
      debugPrint('🔔 RingtoneService: Tone already playing');
      return;
    }

    // ff_call_ringback selects which ringback implementation runs. The disk
    // cache is read directly — FeatureFlagService hydration runs after
    // runApp, too late on cold start.
    bool legacyPath;
    try {
      final prefs = await SharedPreferences.getInstance();
      legacyPath = useLegacyRingbackPath(
        cachedFlagValue: prefs.getBool('ff_cache_ff_call_ringback'),
      );
    } catch (_) {
      legacyPath = false;
    }
    if (legacyPath) {
      await _playOutgoingRingtoneLegacy();
      return;
    }

    try {
      _isPlaying = true;
      _playingOutgoing = true;
      _outgoingCallId = (callId == null || callId.isEmpty) ? null : callId;
      debugPrint(
        '🔔 RingtoneService: Playing outgoing ringback',
      );

      if (Platform.isAndroid) {
        // Use native ToneGenerator — plays TONE_SUP_RINGTONE on STREAM_VOICE_CALL
        // which routes through the current communication audio path (earpiece
        // when speaker off, speaker when on). Same mechanism WhatsApp uses.
        final ok = await _audioChannel.invokeMethod<bool>('playRingback');
        if (ok == false) {
          throw StateError('native playRingback reported failure');
        }
      } else {
        // iOS: use AudioPlayer with ringback.wav through the call audio session
        await _startRingbackPlayer();
      }
      CallPhaseLogger.mark('ringback_start');
    } catch (e) {
      debugPrint('❌ RingtoneService: Error playing outgoing tone: $e');
      // Release-visible: debugPrint is stripped in release builds.
      // ignore: avoid_print
      print('❌ RingtoneService: Error playing outgoing tone: $e');
      CallPhaseLogger.mark('ringback_error');
      _isPlaying = false;
      _playingOutgoing = false;
      _outgoingCallId = null;
      await _ringbackPlayer?.stop();
      await _ringbackPlayer?.dispose();
      _ringbackPlayer = null;
    }
  }

  /// Legacy caller ringback — the pre-flag implementation, byte-for-byte.
  /// Runs only when ff_call_ringback is explicitly cached OFF. No direction
  /// tracking, no phase marks, Android result ignored, iOS keeps the
  /// setAudioContext player.
  Future<void> _playOutgoingRingtoneLegacy() async {
    try {
      _isPlaying = true;
      debugPrint(
        '🔔 RingtoneService: Playing outgoing ringback',
      );

      if (Platform.isAndroid) {
        // Use native ToneGenerator — plays TONE_SUP_RINGTONE on STREAM_VOICE_CALL
        // which routes through the current communication audio path (earpiece
        // when speaker off, speaker when on). Same mechanism WhatsApp uses.
        await _audioChannel.invokeMethod('playRingback');
      } else {
        // iOS: use AudioPlayer with ringback.wav through the call audio session
        await _startRingbackPlayerLegacy();
      }
    } catch (e) {
      debugPrint('❌ RingtoneService: Error playing outgoing tone: $e');
      _isPlaying = false;
    }
  }

  /// Release-visible dump of the shared iOS audio session via the read-only
  /// describeAudioSession channel case. Never mutates anything.
  Future<void> _logAudioSessionState(String phase) async {
    try {
      final desc = await _callChannel.invokeMethod<Map>(
        'describeAudioSession',
      );
      // ignore: avoid_print
      print('🔔 RingtoneService: session[$phase]=$desc');
    } catch (e) {
      // ignore: avoid_print
      print('⚠️ RingtoneService: describeAudioSession($phase) failed: $e');
    }
  }

  /// Start ringback via AudioPlayer routed through earpiece (iOS fallback).
  Future<void> _startRingbackPlayer() async {
    await _ringbackPlayer?.dispose();
    _ringbackPlayer = AudioPlayer();

    // ff_call_ringback ON path: no setAudioContext — the call's
    // RTCAudioSession already owns the shared AVAudioSession, and the
    // empty-options setCategory(.playAndRecord) strips its Bluetooth/speaker
    // options mid-capture (suspected cause of silent caller ringback). The
    // player plays on the session WebRTC configured.
    //
    // audioplayers never calls setActive — an inactive session means the
    // player "plays" silently. Activate it before play(); never deactivate:
    // the WebRTC ADM owns the session lifecycle and deactivates on teardown.
    // Failure is logged and the player still attempts to start.
    try {
      await _logAudioSessionState('pre');
      final session = await audio_session.AudioSession.instance;
      final activated = await session.setActive(
        true,
        fallbackConfiguration: audio_session.AudioSessionConfiguration(
          avAudioSessionCategory:
              audio_session.AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions: _ringbackSessionOptions,
          avAudioSessionMode: audio_session.AVAudioSessionMode.voiceChat,
        ),
      );
      // ignore: avoid_print
      print('🔔 RingtoneService: setActive(true) -> $activated');
      CallPhaseLogger.mark(
        activated ? 'ringback_activated' : 'ringback_activate_false',
      );
      await _logAudioSessionState('post');
    } catch (e) {
      // ignore: avoid_print
      print('⚠️ RingtoneService: setActive error: $e');
      CallPhaseLogger.mark('ringback_activate_error');
    }

    await _ringbackPlayer!.setVolume(0.8);
    await _ringbackPlayer!.setReleaseMode(ReleaseMode.loop);
    await _ringbackPlayer!.play(AssetSource('audio/ringback.wav'));
    debugPrint('🔔 RingtoneService: Ringback player started (iOS)');
  }

  /// Legacy iOS ringback player — the verbatim pre-flag implementation,
  /// retained for the ff_call_ringback OFF path so a rollback is
  /// byte-for-byte today's behaviour.
  Future<void> _startRingbackPlayerLegacy() async {
    await _ringbackPlayer?.dispose();
    _ringbackPlayer = AudioPlayer();

    await _ringbackPlayer!.setAudioContext(
      AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playAndRecord,
          options: {},
        ),
      ),
    );

    await _ringbackPlayer!.setVolume(0.8);
    await _ringbackPlayer!.setReleaseMode(ReleaseMode.loop);
    await _ringbackPlayer!.play(AssetSource('audio/ringback.wav'));
    debugPrint('🔔 RingtoneService: Ringback player started (iOS)');
  }

  /// Play outgoing call tone (single beep)
  Future<void> playOutgoingTone() async {
    try {
      debugPrint('🔔 RingtoneService: Playing outgoing tone');
      await FlutterRingtonePlayer().play(
        android: AndroidSounds.notification,
        ios: IosSounds.glass,
        asAlarm: false,
      );
    } catch (e) {
      debugPrint('❌ RingtoneService: Error playing outgoing tone: $e');
    }
  }

  /// Pure decision for [stopOutgoingRingback]: stop only when an OUTGOING
  /// ringback is actually playing, and when both call ids are known they must
  /// match — a stale reset for an old call can then never silence a newer
  /// call's tone. Null/empty ids degrade to "unknown" and allow the stop.
  static bool shouldStopOutgoingRingback({
    required bool playingOutgoing,
    String? outgoingCallId,
    String? requestedCallId,
  }) {
    if (!playingOutgoing) return false;
    return outgoingCallId == null ||
        requestedCallId == null ||
        outgoingCallId == requestedCallId;
  }

  /// Stop only the outgoing ringback — NEVER the incoming ringtone. Used by
  /// reset/error paths where a stale reset for an old call could otherwise
  /// kill a newer call's tone.
  Future<void> stopOutgoingRingback({
    String? callId,
    String reason = 'unknown',
  }) async {
    final wantedId = (callId == null || callId.isEmpty) ? null : callId;
    if (!shouldStopOutgoingRingback(
      playingOutgoing: _playingOutgoing,
      outgoingCallId: _outgoingCallId,
      requestedCallId: wantedId,
    )) {
      return;
    }
    debugPrint(
      '🔔 RingtoneService: Stopping outgoing ringback (reason=$reason)',
    );
    CallPhaseLogger.mark('ringback_stop_$reason');
    _isPlaying = false;
    _playingOutgoing = false;
    _outgoingCallId = null;

    if (Platform.isAndroid) {
      try {
        await _audioChannel
            .invokeMethod('stopRingback', {'reason': reason});
      } catch (e) {
        debugPrint('⚠️ RingtoneService: Could not stop native ringback: $e');
      }
    }

    await _ringbackPlayer?.stop();
    await _ringbackPlayer?.dispose();
    _ringbackPlayer = null;
    // FlutterRingtonePlayer is deliberately untouched here — it may be
    // playing a live incoming ringtone for a different call.
  }

  /// Stop ringtone playback
  Future<void> stopRingtone({String reason = 'end'}) async {
    if (!_isPlaying) return;

    debugPrint('🔔 RingtoneService: Stopping ringtone (reason=$reason)');
    if (_playingOutgoing) {
      CallPhaseLogger.mark('ringback_stop_$reason');
    }

    _isPlaying = false;
    _playingOutgoing = false;
    _outgoingCallId = null;

    // Stop native ringback on Android
    if (Platform.isAndroid) {
      try {
        await _audioChannel
            .invokeMethod('stopRingback', {'reason': reason});
      } catch (e) {
        debugPrint('⚠️ RingtoneService: Could not stop native ringback: $e');
      }
    }

    // Stop audioplayers ringback (iOS fallback)
    await _ringbackPlayer?.stop();
    await _ringbackPlayer?.dispose();
    _ringbackPlayer = null;

    await FlutterRingtonePlayer().stop();
  }

  /// Play call connected tone
  Future<void> playConnectedTone() async {
    try {
      debugPrint('🔔 RingtoneService: Playing connected tone');
      await FlutterRingtonePlayer().play(
        android: AndroidSounds.notification,
        ios: IosSounds.glass,
        asAlarm: false,
      );
    } catch (e) {
      debugPrint('❌ RingtoneService: Error playing connected tone: $e');
    }
  }

  /// Play call ended tone
  Future<void> playEndedTone() async {
    try {
      debugPrint('🔔 RingtoneService: Playing ended tone');
      await FlutterRingtonePlayer().play(
        android: AndroidSounds.notification,
        ios: IosSounds.glass,
        asAlarm: false,
      );
    } catch (e) {
      debugPrint('❌ RingtoneService: Error playing ended tone: $e');
    }
  }

  /// Dispose
  void dispose() {
    stopRingtone();
  }

  /// Getters
  bool get isPlaying => _isPlaying;
}
