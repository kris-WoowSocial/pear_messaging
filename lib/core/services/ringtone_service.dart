import 'dart:async';
import 'dart:io' show Platform;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Ringtone Service - Manages call ringtone playback
/// Handles incoming call ringtones and outgoing call tones using system sounds
class RingtoneService {
  static final RingtoneService _instance = RingtoneService._internal();
  factory RingtoneService() => _instance;
  RingtoneService._internal();

  bool _isPlaying = false;
  bool _isOutgoing = false;
  Timer? _ringTimer;
  int _ringCount = 0;
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
      _ringCount = 0;

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

  /// Play outgoing ringback tone (looping) — heard by caller through earpiece
  Future<void> playOutgoingRingtone() async {
    if (_isPlaying) {
      debugPrint('🔔 RingtoneService: Tone already playing');
      return;
    }
    try {
      _isPlaying = true;
      _isOutgoing = true;
      _ringCount = 0;
      // Ensure earpiece routing before playing
      Helper.setSpeakerphoneOn(false);
      debugPrint(
        '🔔 RingtoneService: Playing outgoing ringback through earpiece',
      );
      await _startRingbackPlayer();
    } catch (e) {
      debugPrint('❌ RingtoneService: Error playing outgoing tone: $e');
      _isPlaying = false;
      _isOutgoing = false;
    }
  }

  /// Use AudioPlayer with voice-call audio context to route through earpiece
  Future<void> _startRingbackPlayer() async {
    await _ringbackPlayer?.dispose();
    _ringbackPlayer = AudioPlayer();

    // On Android: use AudioContextAndroid with USAGE_VOICE_COMMUNICATION so
    // Use MEDIA content type for ringback so it doesn't interfere with call audio routing
    if (Platform.isAndroid) {
      await _ringbackPlayer!.setAudioContext(
        AudioContext(
          android: AudioContextAndroid(
            isSpeakerphoneOn: true, // Allow speaker routing
            stayAwake: false,
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.media,
            audioFocus:
                AndroidAudioFocus.none, // Don't take exclusive audio focus
          ),
        ),
      );
    } else if (Platform.isIOS) {
      await _ringbackPlayer!.setAudioContext(
        AudioContext(
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.ambient, // Mix with other audio
            options: {AVAudioSessionOptions.mixWithOthers},
          ),
        ),
      );
    }

    await _ringbackPlayer!.setVolume(0.6);
    await _ringbackPlayer!.setReleaseMode(ReleaseMode.loop); // Loop continuously

    // Play ringback beep continuously
    _ringbackPlayer?.play(AssetSource('audio/ringback.wav'));

    // Auto-stop after 2 minutes (120 seconds) max if not stopped
    _ringTimer = Timer(const Duration(seconds: 120), () {
      if (_isPlaying && _isOutgoing) {
        debugPrint(
          '🔔 RingtoneService: Max ringback duration reached, stopping',
        );
        stopRingtone();
      }
    });
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
    _isOutgoing = false;
    _ringTimer?.cancel();
    _ringTimer = null;
    _ringCount = 0;

    // Stop audioplayers ringback
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
