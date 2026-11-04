import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

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
    expect(handler, contains('iosPushWakeReconnect.value'));
    expect(handler, contains('_ringingCallId = pushCallId'));
    expect(handler, contains("prefs.setString('ringing_call_id', pushCallId)"));
    expect(handler, contains('_socketService.forceReconnect()'));
    expect(handler.indexOf('iosPushWakeReconnect.value'),
        lessThan(handler.indexOf('_socketService.forceReconnect()')));
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
    expect(reset,
        contains('if (Platform.isIOS && _ringingCallId == callId)'));
    expect(reset, contains("prefs.remove('ringing_call_id')"));
    expect(reset, contains('CallPhaseLogger.stop()'));
  });

  test('terminate also clears a stale ringing marker for its callId', () {
    final src = controller();
    final terminated = src.substring(
      src.indexOf('  void _handleCallTerminated('),
    );
    expect(terminated,
        contains('Platform.isIOS && callId != null && callId == _ringingCallId'));
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
}
