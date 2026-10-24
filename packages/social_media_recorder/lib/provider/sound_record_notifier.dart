import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:social_media_recorder/audio_encoder_type.dart';

/// Holds the recording state used by [SocialMediaRecorder].
class SoundRecordNotifier extends ChangeNotifier {
  SoundRecordNotifier({
    required this.stopRecording,
    required this.sendRequestFunction,
    required this.startRecording,
    this.onPermissionDenied,
    this.encode = AudioEncoderType.AAC,
    this.maxRecordTime,
    this.edge = 0.0,
    this.minute = 0,
    this.second = 0,
    this.buttonPressed = false,
    this.loopActive = false,
    this.mPath = '',
    this.startRecord = false,
    this.heightPosition = 0,
    this.lockScreenRecord = false,
  });

  int _counter = 0;
  int _localCounterForMaxRecordTime = 0;
  bool _isFinishing = false;

  Timer? _timer;
  Timer? _timerCounter;

  final AudioRecorder recordMp3 = AudioRecorder();

  int? maxRecordTime;

  /// Called when recording starts.
  Function()? startRecording;

  /// Called when recording stops; receives the recorded duration.
  Function(String time)? stopRecording;

  /// Called when a recording is finished and ready to be sent.
  Function(File soundFile, String time) sendRequestFunction;

  /// Called when microphone permission is denied while trying to record.
  Function()? onPermissionDenied;

  /// Recording encoder type.
  late AudioEncoderType encode;

  /// Path prefix to store the recording. If empty a temp directory is used.
  String initialStorePathRecord = '';

  /// Global key used to locate the mic button while dragging.
  GlobalKey key = GlobalKey();

  /// Last horizontal position of the mic button.
  double last = 0;

  /// Current drag offset from the mic button origin.
  double currentButtonHeihtPlace = 0;

  /// Whether the mic is currently held down.
  late bool buttonPressed;

  /// Whether the recording has been locked (drag up).
  late bool isLocked;

  /// Whether the locked-recording UI is visible.
  late bool lockScreenRecord;

  /// Whether the recording bar is expanded.
  late bool isShow;

  /// Horizontal edge offset while sliding to cancel.
  late double edge;

  /// Guards the counter update loop.
  late bool loopActive;

  /// Whether the native recorder has started.
  late bool startRecord;

  /// Vertical drag offset for the lock gesture.
  late double heightPosition;

  /// Recording seconds/minutes.
  late int second;
  late int minute;

  /// Final recorded file path.
  late String mPath;

  double _initWidth = -33;

  /// Initialise any pre-checks (kept for compatibility).
  void voidInitialSound() {
    startRecord = false;
  }

  /// To increase counter every second while the button is held.
  void _mapCounterGenerator() {
    _timerCounter = Timer(const Duration(seconds: 1), () {
      _increaseCounterWhilePressed();
      if (buttonPressed) _mapCounterGenerator();
    });
  }

  /// Stops the recording and sends the file if it is long enough.
  Future<void> finishRecording() async {
    if (!buttonPressed || _isFinishing) return;
    _isFinishing = true;
    final shouldSend = second > 1 || minute > 0;
    final time = '${minute.toString()}:${second.toString()}';
    _timer?.cancel();
    _timerCounter?.cancel();
    try {
      final path = await recordMp3.stop();
      if (shouldSend && path != null && path.isNotEmpty) {
        mPath = path;
        sendRequestFunction(File(path), time);
      }
    } catch (e) {
      debugPrint('Failed to finish recording: $e');
    } finally {
      stopRecording?.call(time);
      await resetEdgePadding();
      _isFinishing = false;
    }
  }

  /// Resets all recording state and stops the native recorder.
  Future<void> resetEdgePadding() async {
    if (_initWidth == -33) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        final position = box.localToGlobal(Offset.zero);
        _initWidth = position.dx;
      }
    }
    _localCounterForMaxRecordTime = 0;
    isLocked = false;
    edge = 0;
    buttonPressed = false;
    second = 0;
    minute = 0;
    isShow = false;
    key = GlobalKey();
    heightPosition = 0;
    lockScreenRecord = false;
    _timer?.cancel();
    _timerCounter?.cancel();

    if (await recordMp3.isRecording()) {
      await recordMp3.stop();
    }
    notifyListeners();
  }

  String _getSoundExtension() {
    if (encode == AudioEncoderType.AAC ||
        encode == AudioEncoderType.AAC_LD ||
        encode == AudioEncoderType.AAC_HE ||
        encode == AudioEncoderType.OPUS) {
      return '.m4a';
    }
    return '.3gp';
  }

  /// Returns a unique file path for the recording.
  Future<String> getFilePath() async {
    final tempDir = await getTemporaryDirectory();
    final basePath = initialStorePathRecord.isEmpty
        ? tempDir.path
        : initialStorePathRecord;
    final dir = Directory(basePath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final now = DateTime.now();
    final convertedDateTime =
        '${_counter.toString()}${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}-${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    _counter++;
    final storagePath = '$basePath/$convertedDateTime${_getSoundExtension()}';
    mPath = storagePath;
    return storagePath;
  }

  /// Stores the initial vertical position of the pointer.
  void setNewInitialDraggableHeight(double newValue) {
    currentButtonHeihtPlace = newValue;
  }

  /// Handles horizontal/vertical drag updates for slide-to-cancel and lock.
  void updateScrollValue(Offset currentValue, BuildContext context) async {
    if (!buttonPressed) return;

    final heightValue = currentButtonHeihtPlace - currentValue.dy;
    if (heightValue >= 50) {
      isLocked = true;
      lockScreenRecord = true;
      heightPosition = 50;
    } else if (heightValue < 0) {
      heightPosition = 0;
    } else {
      heightPosition = heightValue;
    }
    lockScreenRecord = isLocked;
    notifyListeners();

    try {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        final position = box.localToGlobal(Offset.zero);
        if (position.dx <= MediaQuery.of(context).size.width * 0.6) {
          final time = '${minute.toString()}:${second.toString()}';
          stopRecording?.call(time);
          resetEdgePadding();
          return;
        } else if (currentValue.dx >= MediaQuery.of(context).size.width) {
          edge = 0;
        } else {
          edge = (_initWidth - currentValue.dx) > 0
              ? (_initWidth - currentValue.dx)
              : 0;
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  void _increaseCounterWhilePressed() async {
    if (loopActive) return;
    loopActive = true;

    if (maxRecordTime != null) {
      if (_localCounterForMaxRecordTime >= maxRecordTime!) {
        loopActive = false;
        finishRecording();
        return;
      }
      _localCounterForMaxRecordTime++;
    }

    second += 1;
    if (second == 60) {
      second = 0;
      minute += 1;
    }

    loopActive = false;
    notifyListeners();
  }

  /// Starts a recording after requesting microphone permission.
  void record(Function()? startRecord) async {
    final granted = await recordMp3.hasPermission(request: true);
    if (!granted) {
      onPermissionDenied?.call();
      notifyListeners();
      return;
    }

    buttonPressed = true;
    isShow = true;
    final recordFilePath = await getFilePath();

    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), () async {
      try {
        await recordMp3.start(const RecordConfig(), path: recordFilePath);
        startRecord?.call();
      } catch (e) {
        debugPrint('Failed to start recording: $e');
      }
    });

    _mapCounterGenerator();
    notifyListeners();
  }
}
