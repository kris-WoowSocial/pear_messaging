import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/features/call/call_controller.dart';

/// Source-structure checks for the iOS locked-wake socket reconnect
/// (ff_ios_push_wake_reconnect) and the release-visible phase logging.
void main() {
  String appDelegate() =>
      File('ios/Runner/AppDelegate.swift').readAsStringSync();
  String controller() =>
      File('lib/features/call/call_controller.dart').readAsStringSync();
  String logger() =>
      File('lib/core/services/call_phase_logger.dart').readAsStringSync();
  String flags() =>
      File('lib/core/services/feature_flag_service.dart').readAsStringSync();
  String socket() =>
      File('lib/core/services/socket_service.dart').readAsStringSync();
  String webrtc() =>
      File('lib/core/services/webrtc_call_service.dart').readAsStringSync();

  test('push wake invoke runs only on the locked path, fire-and-forget', () {
    final src = appDelegate();
    final fgBlockStart = src.indexOf('if isAppForeground {');
    final lockedPath = src.indexOf(
        'os_log("%{public}@", log: .default, type: .info, "VantPush wake")');
    final report = src.indexOf(
        'showCallkitIncoming(callData, fromPushKit: true) {\n      completion()',
        lockedPath);
    // The invoke must sit between the end of the foreground block and the
    // locked CallKit report.
    expect(lockedPath, greaterThan(fgBlockStart));
    expect(report, greaterThan(lockedPath));
    // No completion-block argument on the invoke — it can never delay the
    // report or completion().
    expect(
        src,
        contains('.invokeMethod("callPushWake", '
            'arguments: ["callId": serverCallId])'));
    expect(src.substring(lockedPath, report), isNot(contains('completion()')));
  });

  test('logCallPhase only emits phase name and elapsed ms', () {
    final src = appDelegate();
    final handler = src.substring(
      src.indexOf('case "logCallPhase"'),
      src.indexOf('case "setInCall"'),
    );
    expect(handler, contains('args["phase"] as? String'));
    expect(handler, contains('args["ms"] as? Int'));
    expect(handler, isNot(contains('callId')));
    expect(handler, contains('%{public}@'));
  });

  test('controller arms ringing marker and reconnects behind the flag', () {
    final src = controller();
    final handler = src.substring(
      src.indexOf("call.method == 'callPushWake'"),
    );
    expect(handler, contains('!Platform.isIOS'));
    // The flag is read from the SharedPreferences cache, not the service:
    // FeatureFlagService hydration runs after runApp, so on a PushKit
    // cold-start wake the service can still hold the default ON. Only an
    // explicit cached false blocks; missing means ON.
    expect(
        handler,
        contains("prefs.getBool('ff_cache_ff_ios_push_wake_reconnect') "
            '== false'));
    expect(handler, contains('_ringingCallId = pushCallId'));
    expect(handler, contains("prefs.setString('ringing_call_id', pushCallId)"));
    expect(handler, contains('_socketService.forceReconnect()'));
    expect(
        handler.indexOf('ff_cache_ff_ios_push_wake_reconnect'),
        lessThan(handler.indexOf('_socketService.forceReconnect()')));
    expect(
        handler.indexOf('ff_cache_ff_ios_push_wake_reconnect'),
        lessThan(handler.indexOf('_ringingCallId = pushCallId')));
    // Never tear down a live or connecting socket.
    expect(handler, contains('!_socketService.isConnected.value'));
    expect(handler, contains('!_socketService.isConnecting'));
    expect(
        handler.indexOf('!_socketService.isConnected.value'),
        lessThan(handler.indexOf('_socketService.forceReconnect()')));
    // Marker is armed only while registration is still pending.
    expect(
        handler.indexOf('!_socketService.isRegistered.value'),
        lessThan(handler.indexOf('_ringingCallId = pushCallId')));
  });

  test('ringing marker is cleared on call-state reset, iOS only', () {
    final src = controller();
    final reset = src.substring(src.indexOf('  void _resetCallState() {'));
    // iOS-gated and keyed on the ended call's id — Android's Kotlin service
    // owns ringing_call_id and a stale reset must not clear a newer marker.
    expect(reset, contains('if (Platform.isIOS) {'));
    expect(reset, contains('_nativePushCallIds.remove(callId)'));
    expect(reset, contains('if (_ringingCallId == callId)'));
    expect(reset, contains("prefs.remove('ringing_call_id')"));
    expect(reset, contains('CallPhaseLogger.stop()'));
  });

  test('terminate also clears a stale ringing marker for its callId', () {
    final src = controller();
    final terminated = src.substring(
      src.indexOf('  void _handleCallTerminated('),
    );
    expect(terminated, contains('Platform.isIOS && callId != null'));
    expect(terminated, contains('_nativePushCallIds.remove(callId)'));
    expect(terminated, contains('callId == _ringingCallId'));
    expect(terminated, contains('_socketService.callUrgency = false'));
  });

  test('flag ships ON so the build under test exercises it', () {
    final src = flags();
    expect(
        src, contains("kIosPushWakeReconnect = 'ff_ios_push_wake_reconnect'"));
    expect(src, contains('kIosPushWakeReconnect: true,'));
    expect(src, contains('ff_cache_\$kIosPushWakeReconnect'));
  });

  test('phase logger is iOS-only and sends only phase + ms', () {
    final src = logger();
    expect(src, contains('Platform.isIOS'));
    expect(src, contains("'logCallPhase'"));
    expect(src, contains("'ms': _watch.elapsedMilliseconds"));
    expect(src, isNot(contains('callId')));
  });

  test('all required phases are emitted', () {
    final ctrl = controller();
    final sock = socket();
    final rtc = webrtc();
    for (final phase in [
      'push_wake',
      'answer_tap',
      'resync_received',
      'incoming_call',
      'answer_sent',
    ]) {
      expect(ctrl, contains("'$phase'"), reason: 'missing $phase');
    }
    for (final phase in [
      'sock_connect_start',
      'sock_up',
      'registered',
      'resync_request',
    ]) {
      expect(sock, contains("'$phase'"), reason: 'missing $phase');
    }
    for (final phase in [
      'ice_gather_start',
      'ice_gather_complete',
      'ice_connecting',
      'ice_connected',
      'connected',
    ]) {
      expect(rtc, contains("'$phase'"), reason: 'missing $phase');
    }
    expect(rtc, contains('r\'\\btyp\\s+(\\w+)\''));
    expect(rtc, contains("'pair_\${local}_\$remote'"));
  });

  test('suppressIncomingUiForPushCall: push-owned suppresses at ANY lifecycle', () {
    const owned = {'call-1'};
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
      null,
    ]) {
      expect(
        CallController.suppressIncomingUiForPushCall(
          callId: 'call-1',
          isIos: true,
          pushOwnedCallIds: owned,
          lifecycleState: state,
        ),
        isTrue,
        reason: 'push-owned call must suppress at lifecycle $state',
      );
    }
  });

  test('suppressIncomingUiForPushCall: false for non-owned/non-iOS/null', () {
    const owned = {'call-1'};
    for (final state in [
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      null,
    ]) {
      expect(
        CallController.suppressIncomingUiForPushCall(
          callId: 'call-2',
          isIos: true,
          pushOwnedCallIds: owned,
          lifecycleState: state,
        ),
        isFalse,
        reason: 'non-push-owned call must not suppress at lifecycle $state',
      );
      expect(
        CallController.suppressIncomingUiForPushCall(
          callId: 'call-1',
          isIos: false,
          pushOwnedCallIds: owned,
          lifecycleState: state,
        ),
        isFalse,
        reason: 'Android must never suppress at lifecycle $state',
      );
      expect(
        CallController.suppressIncomingUiForPushCall(
          callId: null,
          isIos: true,
          pushOwnedCallIds: owned,
          lifecycleState: state,
        ),
        isFalse,
        reason: 'null callId must never suppress at lifecycle $state',
      );
    }
  });

  test('callPushWake arms the push-owned set unconditionally', () {
    final handler = controller().substring(
      controller().indexOf("call.method == 'callPushWake'"),
    );
    // Armed for every push that passes the iOS/!isInCall checks — BEFORE the
    // flag read, so suppression stays unconditional even when the flag keeps
    // the reconnect/resync path off.
    expect(handler, contains('_nativePushCallIds.add(pushCallId)'));
    expect(
      handler.indexOf('_nativePushCallIds.add(pushCallId)'),
      lessThan(handler.indexOf('ff_cache_ff_ios_push_wake_reconnect')),
    );
    expect(
      handler.indexOf('_nativePushCallIds.add(pushCallId)'),
      lessThan(handler.indexOf('!_socketService.isRegistered.value')),
    );
    expect(
      handler.indexOf('_nativePushCallIds.add(pushCallId)'),
      greaterThan(handler.indexOf('pushCallId.isEmpty || isInCall')),
    );
  });

  test('incoming_call gate consults the push-owned set before showing UI', () {
    final src = controller();
    final fn = src.substring(src.indexOf('_handleIncomingCall(Map'));
    expect(fn, contains('suppressIncomingUiForPushCall('));
    // The native pull is the second line of defence for cold starts where
    // callPushWake raced past handler registration.
    expect(fn, contains('CallKitService().isPushKitCallOwned(incomingCallId)'));
    expect(
      fn.indexOf('suppressIncomingUiForPushCall('),
      lessThan(fn.indexOf("Get.toNamed('/call/incoming'")),
    );
    expect(
      fn.indexOf('suppressIncomingUiForPushCall('),
      lessThan(fn.indexOf('_ringtoneService.playIncomingRingtone()')),
    );
  });

  test('incoming screen never late-ends a push-owned call', () {
    final screen = File('lib/features/call/incoming_call_screen.dart')
        .readAsStringSync();
    final init = screen.substring(
      screen.indexOf('void initState()'),
      screen.indexOf('void _onCallStateChanged'),
    );
    expect(init, contains('isPushOwnedCallId(callId)'));
    // Native pull too — covers callPushWake-dropped cold starts.
    expect(init, contains('CallKitService().isPushKitCallOwned(callId)'));
    expect(
      init.indexOf('isPushOwnedCallId(callId)'),
      lessThan(init.indexOf("endGhostCallKitForCall(callId, reason: 'late')")),
    );
  });

  test('native ownership: locked branch inserts before the CallKit report', () {
    final src = appDelegate();
    // The foreground ghost branch must NEVER insert — ghost records stay
    // ghost-owned so 'late'/'handshake' ends keep working.
    final fgStart = src.indexOf('if isAppForeground {');
    final lockedPath = src.indexOf('"VantPush wake")');
    expect(lockedPath, greaterThan(fgStart));
    expect(src.substring(fgStart, lockedPath),
        isNot(contains('pushKitOwnedCallIds')));
    // Insert lands on the locked branch, before showCallkitIncoming.
    final insert = src.indexOf('pushKitOwnedCallIds.insert(serverCallId)');
    expect(insert, greaterThan(lockedPath));
    expect(
      insert,
      lessThan(src.indexOf(
          'showCallkitIncoming(callData, fromPushKit: true) {\n      completion()',
          lockedPath)),
    );
    // Never armed for an empty callId.
    expect(src, contains('if !serverCallId.isEmpty'));
  });

  test('native ownership: every terminal path clears, onAccept keeps it', () {
    final src = appDelegate();
    String slice(String start, String end) =>
        src.substring(src.indexOf(start), src.indexOf(end));
    for (final (start, end) in [
      ('func onDecline(_ call: Call', 'func onEnd(_ call: Call'),
      ('func onEnd(_ call: Call', 'func onTimeOut(_ call: Call'),
      ('func onTimeOut(_ call: Call', 'private func notifyFlutterOfCallAccept'),
    ]) {
      expect(slice(start, end), contains('pushKitOwnedCallIds.remove(callId)'),
          reason: 'missing pushKitOwnedCallIds clear in $start');
    }
    final cancel =
        slice('if pushType == "call_cancelled"', '// Extract call data');
    expect(cancel, contains('pushKitOwnedCallIds.remove(callId)'));
    // onAccept must NOT clear: a duplicate incoming_call right after the
    // answer must stay suppressed until the call ends.
    final accept =
        slice('func onAccept(_ call: Call', 'func onDecline(_ call: Call');
    expect(accept, isNot(contains('pushKitOwnedCallIds.remove')));
    expect(accept, isNot(contains('pushKitOwnedCallIds.insert')));
  });

  test('isPushKitCallOwned channel method returns native set membership', () {
    final src = appDelegate();
    final handler = src.substring(
      src.indexOf('case "isPushKitCallOwned"'),
      src.indexOf('case "endOrphanedCallKitCall"'),
    );
    expect(handler, contains('pushKitOwnedCallIds.contains(callId)'));
    // Fails open: missing args or dead self return false, never an error.
    expect(handler, contains('result(false)'));
    expect(handler, contains('result(owner.pushKitOwnedCallIds.contains(callId))'));
  });

  test('CallKitService.isPushKitCallOwned is iOS-only, bounded, fail-open', () {
    final svc = File('lib/core/services/callkit_service.dart')
        .readAsStringSync();
    final fn = svc.substring(svc.indexOf('Future<bool> isPushKitCallOwned'));
    expect(fn, contains('Platform.isIOS'));
    expect(fn, contains("'isPushKitCallOwned'"));
    expect(fn, contains('milliseconds: 300'));
    expect(fn, contains('return false'));
  });

  test('every terminal and accept path clears the push-owned entry', () {
    String body(String marker, [String? end]) {
      final src = controller();
      final start = src.indexOf(marker);
      return end == null ? src.substring(start) : src.substring(
        start,
        src.indexOf(end, start + marker.length),
      );
    }

    for (final marker in [
      '  void _resetCallState() {',
      '  void _handleCallTerminated(',
      '  void _handleCallKitDecline(',
      '  void _handleCallKitEnd(',
      '  void _handleCallKitTimeout(',
      '  Future<void> _handleNativeDecline(',
      '  Future<bool> acceptCall(',
      '  Future<void> _acceptIncomingCallResync(',
    ]) {
      expect(
        body(marker, '\n  }'),
        contains('_nativePushCallIds.remove(callId)'),
        reason: 'missing push-owned cleanup in $marker',
      );
    }
    // All cleanup is iOS-gated — Android behaviour is byte-for-byte unchanged.
    expect(body('  void _handleCallKitDecline(', '\n  }'),
        contains('if (Platform.isIOS) _nativePushCallIds.remove(callId)'));
    expect(body('  void _handleCallKitEnd(', '\n  }'),
        contains('if (Platform.isIOS) _nativePushCallIds.remove(callId)'));
    expect(body('  void _handleCallKitTimeout(', '\n  }'),
        contains('if (Platform.isIOS) _nativePushCallIds.remove(callId)'));
    expect(body('  Future<void> _handleNativeDecline(', '\n  }'),
        contains('if (Platform.isIOS) _nativePushCallIds.remove(callId)'));
  });

  test('resume-time staleness never expires a push-owned call', () {
    final src = controller();
    final fn = src.substring(
      src.indexOf('  void _expireStaleIncomingCall()'),
      src.indexOf('  void _handleCallEnded('),
    );
    // iOS gating lives inside isPushOwnedCallId — the shared expiry body
    // stays platform-free so Android behaves identically.
    expect(fn, contains('isPushOwnedCallId(callId)'));
    expect(
      fn.indexOf('isPushOwnedCallId(callId)'),
      lessThan(fn.indexOf('isIncomingRingExpired(')),
    );
  });
}
