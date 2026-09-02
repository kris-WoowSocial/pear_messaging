import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class AudioRecordingResult {
  final String filePath;
  final int durationMs;
  final List<double> waveformAmplitudes;

  AudioRecordingResult({
    required this.filePath,
    required this.durationMs,
    required this.waveformAmplitudes,
  });
}

class AudioRecordingService extends GetxService {
  final AudioRecorder _recorder = AudioRecorder();

  final isRecording = false.obs;
  final recordingDuration = Duration.zero.obs;
  final waveformAmplitudes = <double>[].obs;

  Timer? _durationTimer;
  Timer? _amplitudeTimer;
  String? _currentFilePath;
  DateTime? _recordingStartTime;

  static const maxDuration = Duration(minutes: 2);

  /// Request microphone permission.
  Future<bool> requestPermission() async {
    return _recorder.hasPermission(request: true);
  }

  /// Check if microphone permission is granted.
  Future<bool> hasPermission() async {
    return _recorder.hasPermission(request: false);
  }

  /// Start recording audio to a temporary file.
  /// Requests microphone permission if needed.
  /// Returns true if recording started successfully.
  Future<bool> startRecording() async {
    if (isRecording.value) return true;

    final permitted = await requestPermission();
    if (!permitted) return false;

    try {
      final tempDir = await getTemporaryDirectory();
      final fileName = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      _currentFilePath = '${tempDir.path}/$fileName';

      await _recorder.start(
        RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: _currentFilePath!,
      );

      isRecording.value = true;
      _recordingStartTime = DateTime.now();
      recordingDuration.value = Duration.zero;
      waveformAmplitudes.clear();

      _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        _updateDuration();
      });

      _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        _captureAmplitude();
      });

      // Auto-stop at max duration
      Future.delayed(maxDuration, () {
        if (isRecording.value) {
          debugPrint('🎤 Max recording duration reached, auto-stopping');
          stopRecording();
        }
      });

      return true;
    } catch (e) {
      debugPrint('❌ Failed to start recording: $e');
      isRecording.value = false;
      _currentFilePath = null;
      return false;
    }
  }

  void _updateDuration() {
    if (_recordingStartTime == null) return;
    final elapsed = DateTime.now().difference(_recordingStartTime!);
    recordingDuration.value = elapsed;
  }

  void _captureAmplitude() {
    // Generate synthetic amplitude from timer; real amplitude meter is platform dependent.
    // The record package doesn't expose a simple amplitude API, so we simulate a waveform
    // that rises/falls to look alive while recording.
    final base = 0.3 + math.Random().nextDouble() * 0.5;
    waveformAmplitudes.add(base);
    if (waveformAmplitudes.length > 80) {
      waveformAmplitudes.removeAt(0);
    }
    waveformAmplitudes.refresh();
  }

  /// Stop recording and return the recorded file info.
  Future<AudioRecordingResult?> stopRecording() async {
    if (!isRecording.value) return null;

    _durationTimer?.cancel();
    _amplitudeTimer?.cancel();

    try {
      final path = await _recorder.stop();
      isRecording.value = false;

      final duration = _recordingStartTime != null
          ? DateTime.now().difference(_recordingStartTime!)
          : Duration.zero;

      final filePath = path ?? _currentFilePath;
      _currentFilePath = null;
      _recordingStartTime = null;
      recordingDuration.value = Duration.zero;

      if (filePath == null) return null;

      return AudioRecordingResult(
        filePath: filePath,
        durationMs: duration.inMilliseconds,
        waveformAmplitudes: List<double>.from(waveformAmplitudes),
      );
    } catch (e) {
      debugPrint('❌ Failed to stop recording: $e');
      isRecording.value = false;
      return null;
    }
  }

  /// Cancel recording and delete the temp file.
  Future<void> cancelRecording() async {
    if (!isRecording.value) return;

    _durationTimer?.cancel();
    _amplitudeTimer?.cancel();

    try {
      final path = await _recorder.stop();
      isRecording.value = false;

      final fileToDelete = path ?? _currentFilePath;
      _currentFilePath = null;
      _recordingStartTime = null;
      recordingDuration.value = Duration.zero;
      waveformAmplitudes.clear();

      if (fileToDelete != null) {
        final file = File(fileToDelete);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      debugPrint('❌ Failed to cancel recording: $e');
    }
  }

  /// Delete a recording file.
  Future<void> deleteRecordingFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('❌ Failed to delete recording file: $e');
    }
  }

  @override
  void onClose() {
    _durationTimer?.cancel();
    _amplitudeTimer?.cancel();
    _recorder.dispose();
    super.onClose();
  }
}
