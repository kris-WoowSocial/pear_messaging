import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Release-visible call timing. Each phase is forwarded to AppDelegate and
/// written with `os_log("%{public}@")` using only the phase name and elapsed
/// milliseconds — never call ids, names, tokens or IP addresses.
///
/// A session starts on the push wake (or the answer tap, whichever is first)
/// and stops when the call state resets, so unrelated traffic never produces
/// phase lines. iOS only; a no-op everywhere else.
class CallPhaseLogger {
  CallPhaseLogger._();

  static const MethodChannel _channel =
      MethodChannel('com.pear.messaging/call');
  static final Stopwatch _watch = Stopwatch();
  static final Set<String> _seen = <String>{};
  static bool _active = false;

  /// Start a fresh phase session (zeroes the elapsed clock).
  static void start() {
    if (!Platform.isIOS) return;
    _active = true;
    _seen.clear();
    _watch
      ..reset()
      ..start();
  }

  /// Start only when no session is running — the answer tap may arrive after
  /// a push-wake session already began and must not reset its clock.
  static void startIfInactive() {
    if (!_active) start();
  }

  /// Stop emitting — called when the call state resets.
  static void stop() => _active = false;

  /// Log [phase] with elapsed ms since [start].
  static void mark(String phase) {
    if (!_active || !Platform.isIOS) return;
    unawaited(
      _channel.invokeMethod('logCallPhase', <String, dynamic>{
        'phase': phase,
        'ms': _watch.elapsedMilliseconds,
      }).catchError((_) {}),
    );
  }

  /// Log [phase] at most once per session (e.g. ICE candidate types).
  static void markOnce(String phase) {
    if (_seen.add(phase)) mark(phase);
  }
}
