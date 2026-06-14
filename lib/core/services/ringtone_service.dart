import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

/// Ringtone Service - Manages call ringtone playback
/// Handles incoming call ringtones and outgoing call tones using system sounds
class RingtoneService {
  static final RingtoneService _instance = RingtoneService._internal();
  factory RingtoneService() => _instance;
  RingtoneService._internal();

  bool _isPlaying = false;
  Timer? _ringTimer;
  int _ringCount = 0;

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
      _ringCount = 0;

      debugPrint(
          '🔔 RingtoneService: Playing incoming ringtone (system default)');

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

    _ringCount++;

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
    _ringTimer?.cancel();
    _ringTimer = null;
    _ringCount = 0;

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
