import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// Android Picture-in-Picture bridge for video calls.
///
/// Wraps the `com.pear.messaging/call` method channel and the
/// `com.vant.chat/call_events` event channel (PiP changes arrive as
/// `{type: 'pip_changed', is_pip: 'true'|'false'}` broadcasts from
/// MainActivity). All methods no-op off Android and when the
/// `ff_pip_android` flag is off — the flag-off path must behave exactly like
/// the pre-PiP build.
///
/// Logcat tag used natively and mirrored in debugPrint: `VantPip` / `📺`.
class PipService {
  PipService._();
  static final PipService _instance = PipService._();
  factory PipService() => _instance;

  static const MethodChannel _callChannel = MethodChannel(
    'com.pear.messaging/call',
  );

  /// Reactive PiP state driven by `onPictureInPictureModeChanged` events.
  /// VideoCallScreen switches to the bare remote-video layout while true.
  final RxBool isInPip = false.obs;

  /// Set natively BEFORE `enterPictureInPictureMode()` so the camera-pause
  /// path can tell "going into PiP" from a real background transition.
  /// Mirrored here from the `pip_changed` event + explicit queries.
  bool _pipEntering = false;
  bool get pipEntering => _pipEntering;

  /// Enabled while a connected video call is up (drives API31+ auto-enter and
  /// the API26-30 onUserLeaveHint path natively).
  bool _pipEligible = false;
  bool get pipEligible => _pipEligible;

  /// Called by CallController from the call_events stream.
  void onPipChanged(bool inPip) {
    if (_pipEntering && !inPip) _pipEntering = false;
    if (isInPip.value == inPip) return;
    isInPip.value = inPip;
    debugPrint('📺 VantPip: pip_changed -> isInPip=$inPip');
  }

  /// Synchronous query — always asks native (source of truth for the
  /// activity-level PiP flag). Used by the camera-pause debounce.
  Future<bool> isInPipMode() async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _callChannel.invokeMethod<bool>('isInPipMode');
      return result ?? false;
    } catch (e) {
      debugPrint('⚠️ VantPip: isInPipMode query failed: $e');
      return isInPip.value;
    }
  }

  /// Also ask native for the pipEntering flag (set before
  /// enterPictureInPictureMode, cleared in onPictureInPictureModeChanged).
  Future<bool> isPipEntering() async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _callChannel.invokeMethod<bool>('isPipEntering');
      _pipEntering = result ?? _pipEntering;
      return result ?? false;
    } catch (e) {
      debugPrint('⚠️ VantPip: isPipEntering query failed: $e');
      return _pipEntering;
    }
  }

  /// Tell native whether the current state allows PiP entry, plus the aspect
  /// ratio for the PiP window (remote video dims, 9:16 fallback).
  Future<void> setPipEligible(bool enabled, {int width = 9, int height = 16}) async {
    if (!Platform.isAndroid) return;
    if (_pipEligible == enabled && !enabled) return;
    _pipEligible = enabled;
    try {
      await _callChannel.invokeMethod('setPipParams', {
        'enabled': enabled,
        'width': width,
        'height': height,
      });
      debugPrint(
        '📺 VantPip: setPipEligible=$enabled ratio=$width:$height',
      );
    } catch (e) {
      debugPrint('⚠️ VantPip: setPipParams failed: $e');
    }
  }

  /// Called when the call ends. NEVER finishes the activity — finishing would
  /// destroy the Flutter engine, the Dart isolate, and the signaling socket.
  /// Instead native runs moveTaskToBack(true): the PiP window closes and the
  /// app process/socket stay alive exactly like pressing Home.
  Future<void> onCallEnded() async {
    if (!Platform.isAndroid) return;
    _pipEligible = false;
    try {
      await _callChannel.invokeMethod('pipCallEnded');
      debugPrint('📺 VantPip: call ended (wasInPip=${isInPip.value})');
    } catch (e) {
      debugPrint('⚠️ VantPip: pipCallEnded failed: $e');
    }
    isInPip.value = false;
    _pipEntering = false;
  }

  /// User dismissed the PiP window with the system close (X) control — the
  /// call continues on audio. Native just leaves PiP if somehow still active.
  Future<void> onPipDismissed() async {
    if (!Platform.isAndroid) return;
    try {
      await _callChannel.invokeMethod('exitPipIfActive');
    } catch (e) {
      debugPrint('⚠️ VantPip: exitPipIfActive failed: $e');
    }
    isInPip.value = false;
  }

  void reset() {
    _pipEligible = false;
    _pipEntering = false;
    isInPip.value = false;
  }
}
