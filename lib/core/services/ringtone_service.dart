import 'dart:async';
import 'dart:io' show Platform;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

/// Ringtone Service - Manages call ringtone playback
/// Handles incoming call ringtones and outgoing call tones using system sounds
class RingtoneService {
  static final RingtoneService _instance = RingtoneService._internal();
  factory RingtoneService() => _instance;
  RingtoneService._internal();

  static const MethodChannel _audioChannel = MethodChannel(
    'com.pear.messaging/audio',
  );

  bool _isPlaying = false;
  AudioPlayer? _ringbackPlayer;

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

  /// Play outgoing ringback tone (looping) — heard by caller through earpiece
  Future<void> playOutgoingRingtone() async {
    if (_isPlaying) {
      debugPrint('🔔 RingtoneService: Tone already playing');
      return;
    }
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
        await _startRingbackPlayer();
      }
    } catch (e) {
      debugPrint('❌ RingtoneService: Error playing outgoing tone: $e');
      _isPlaying = false;
    }
  }

  /// Start ringback via AudioPlayer routed through earpiece (iOS fallback).
  Future<void> _startRingbackPlayer() async {
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

  /// Stop ringtone playback
  Future<void> stopRingtone() async {
    if (!_isPlaying) return;

    debugPrint('🔔 RingtoneService: Stopping ringtone');

    _isPlaying = false;

    // Stop native ringback on Android
    if (Platform.isAndroid) {
      try {
        await _audioChannel.invokeMethod('stopRingback');
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
