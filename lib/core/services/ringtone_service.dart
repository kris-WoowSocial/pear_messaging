import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Service for playing ringtones during incoming calls
/// Uses native platform channels for system ringtones
class RingtoneService {
  static final RingtoneService _instance = RingtoneService._internal();
  factory RingtoneService() => _instance;
  RingtoneService._internal();

  bool _isPlaying = false;

  // Platform channel for native ringtone playback
  static const MethodChannel _platformChannel = MethodChannel('com.vant.chat/ringtone');

  /// Initialize the ringtone service
  Future<void> init() async {
    debugPrint('📞 RingtoneService initialized (using native platform)');
  }

  /// Play incoming call ringtone using system default
  Future<void> playIncomingCallRingtone() async {
    if (_isPlaying) {
      debugPrint('📞 Ringtone already playing');
      return;
    }

    try {
      _isPlaying = true;
      
      // Try to play system default ringtone via platform channel
      if (Platform.isAndroid) {
        await _platformChannel.invokeMethod('playRingtone');
      }
      
      debugPrint('📞 Playing system ringtone');
    } catch (e) {
      debugPrint('⚠️ Native ringtone failed: $e');
      // Ringtone is not critical - call will still work
      _isPlaying = false;
    }
  }

  /// Play outgoing call dial tone
  Future<void> playDialTone() async {
    debugPrint('📞 Dial tone (native platform)');
  }

  /// Stop playing ringtone
  Future<void> stopRingtone() async {
    try {
      if (_isPlaying) {
        if (Platform.isAndroid) {
          await _platformChannel.invokeMethod('stopRingtone');
        }
        _isPlaying = false;
        debugPrint('📞 Ringtone stopped');
      }
    } catch (e) {
      debugPrint('⚠️ Failed to stop ringtone: $e');
    }
  }

  /// Dispose the service
  Future<void> dispose() async {
    await stopRingtone();
    _isPlaying = false;
    debugPrint('📞 RingtoneService disposed');
  }

  /// Check if ringtone is currently playing
  bool get isPlaying => _isPlaying;
}
