import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// Remote feature flags — every new capability ships OFF by default and is
/// enabled gradually from Firebase Remote Config (no server deploy needed,
/// instant kill switch).
///
/// Current flags:
///  - ff_verification_ui     Phase 1 contact verification screen
///  - ff_encrypted_signaling Phase 2 SDP/ICE encryption
///  - ff_video_calling       video call offers/answers
///
/// A fetch failure NEVER enables anything — defaults stay off.
class FeatureFlagService extends GetxService {
  static const String kVerificationUi = 'ff_verification_ui';
  static const String kEncryptedSignaling = 'ff_encrypted_signaling';
  static const String kVideoCalling = 'ff_video_calling';

  final RxBool verificationUi = false.obs;
  final RxBool encryptedSignaling = false.obs;
  final RxBool videoCalling = false.obs;

  FirebaseRemoteConfig? _rc;
  final Completer<void> _initialFetchCompleter = Completer<void>();
  final List<VoidCallback> _onApplyCallbacks = [];

  /// Completes once the first Remote Config fetch/activate attempt finishes,
  /// whether it succeeded or not. Socket registration can wait on this with
  /// a timeout so it never stalls cold-start if Remote Config is unreachable.
  Future<void> get initialFetchCompleted => _initialFetchCompleter.future;

  /// Register a callback invoked every time flags are applied (initial load,
  /// real-time config updates, and manual refresh). Used by SocketService to
  /// re-announce capabilities whenever a flag changes.
  void onFlagsUpdated(VoidCallback callback) {
    _onApplyCallbacks.add(callback);
  }

  Future<FeatureFlagService> init() async {
    try {
      _rc = FirebaseRemoteConfig.instance;
      await _rc!.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 10),
        // Debug builds must see freshly published values while device testing.
        // Release keeps a one-hour interval to avoid a Remote Config fetch storm.
        minimumFetchInterval:
            kDebugMode ? Duration.zero : const Duration(hours: 1),
      ));
      // Safe defaults baked in — remote values only ever tighten control.
      await _rc!.setDefaults({
        kVerificationUi: false,
        kEncryptedSignaling: false,
        kVideoCalling: false,
      });
      await _rc!.fetchAndActivate();
      _apply();
      _rc!.onConfigUpdated.listen((_) async {
        await _rc!.activate();
        _apply();
      });
    } catch (e) {
      debugPrint('⚠️ Remote Config unavailable — all feature flags OFF: $e');
    } finally {
      if (!_initialFetchCompleter.isCompleted) {
        _initialFetchCompleter.complete();
      }
    }
    return this;
  }

  /// Fetch fresh flags now (called on app resume — faster than the 1h floor).
  Future<void> refresh() async {
    try {
      await _rc?.fetchAndActivate();
      _apply();
    } catch (_) {} // network/config hiccup → keep current flags
  }

  void _apply() {
    verificationUi.value = _rc!.getBool(kVerificationUi);
    encryptedSignaling.value = _rc!.getBool(kEncryptedSignaling);
    videoCalling.value = _rc!.getBool(kVideoCalling);
    debugPrint(
      '🎛️ Feature flags: verification=${verificationUi.value}, '
      'encrypted=${encryptedSignaling.value}, video=${videoCalling.value} '
      '(fetch=${_rc!.lastFetchStatus}, at=${_rc!.lastFetchTime})',
    );
    for (final callback in _onApplyCallbacks) {
      try {
        callback();
      } catch (e) {
        debugPrint('⚠️ Flag update callback failed: $e');
      }
    }
  }
}
