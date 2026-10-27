import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/caller_name_resolver.dart';
import 'package:pear_messaging/core/services/qr_service.dart';

String source(String path) => File(path).readAsStringSync();

String section(String src, String start, String end) {
  final s = src.indexOf(start);
  final e = src.indexOf(end, s);
  expect(s, greaterThanOrEqualTo(0), reason: 'missing: $start');
  expect(e, greaterThan(s), reason: 'missing: $end');
  return src.substring(s, e);
}

void main() {
  const deviceId = 'dev_abcdef12345';

  group('CallerNameResolver.isPlaceholder', () {
    test('generated @user_ handles are placeholders', () {
      expect(CallerNameResolver.isPlaceholder('@user_f12345', deviceId), isTrue);
      expect(CallerNameResolver.isPlaceholder('@user_1234', deviceId), isTrue);
    });

    test('empty/null/id-equal/generic fallbacks are placeholders', () {
      expect(CallerNameResolver.isPlaceholder(null, deviceId), isTrue);
      expect(CallerNameResolver.isPlaceholder('', deviceId), isTrue);
      expect(CallerNameResolver.isPlaceholder('   ', deviceId), isTrue);
      expect(CallerNameResolver.isPlaceholder(deviceId, deviceId), isTrue);
      expect(CallerNameResolver.isPlaceholder('Unknown', deviceId), isTrue);
      expect(CallerNameResolver.isPlaceholder('Incoming Call', deviceId), isTrue);
    });

    test('real names are not placeholders', () {
      expect(CallerNameResolver.isPlaceholder('Waqar', deviceId), isFalse);
      expect(CallerNameResolver.isPlaceholder('John Smith', deviceId), isFalse);
    });
  });

  group('CallerNameResolver.resolveSync order', () {
    test('payload name wins when it is a real name', () {
      final name = CallerNameResolver.resolveSync(
        deviceId,
        payloadName: 'Waqar',
        savedNameLookup: (_) => 'Saved Alias',
      );
      expect(name, 'Waqar');
    });

    test('saved contact wins over a placeholder payload name', () {
      final name = CallerNameResolver.resolveSync(
        deviceId,
        payloadName: '@user_f12345',
        savedNameLookup: (_) => 'Waqar',
      );
      expect(name, 'Waqar');
    });

    test('returns null when everything is placeholder', () {
      final name = CallerNameResolver.resolveSync(
        deviceId,
        payloadName: 'Incoming Call',
        savedNameLookup: (_) => null,
      );
      expect(name, isNull);
    });
  });

  group('CallerNameResolver.resolve full order', () {
    test('server profile wins over friendly fallback', () async {
      final name = await CallerNameResolver.resolve(
        deviceId,
        savedNameLookup: (_) => null,
        serverNameLookup: (_) async => 'Real Name',
      );
      expect(name, 'Real Name');
    });

    test('falls back to the friendly name when all else fails', () async {
      final name = await CallerNameResolver.resolve(
        deviceId,
        payloadName: '@user_f12345',
        savedNameLookup: (_) => null,
        serverNameLookup: (_) async => null,
      );
      expect(name, startsWith('@user_'));
    });

    test('survives a throwing server lookup', () async {
      final name = await CallerNameResolver.resolve(
        deviceId,
        savedNameLookup: (_) => null,
        serverNameLookup: (_) async => throw StateError('offline'),
      );
      expect(name, startsWith('@user_'));
    });
  });

  group('incoming-call call sites use the resolver', () {
    final cc = source('lib/features/call/call_controller.dart');

    test('_handleIncomingCall resolves and rewrites callerName', () {
      final body = section(
        cc,
        'Future<void> _handleIncomingCall',
        'isBackgroundedForIncomingCall',
      );
      expect(body, contains('CallerNameResolver.resolveSync'));
      expect(body, contains("data['callerName'] = resolvedName"));
      expect(body, contains('CallerNameResolver.resolve('));
    });

    test('native show/flutter-call and answer paths resolve too', () {
      expect(
        section(cc, 'void _handleNativeShowFlutterCall', '_setNativeInCall'),
        contains('CallerNameResolver.resolveSync'),
      );
      expect(
        section(cc, "if (action == 'show_incoming_call')",
            "if (action == 'open_ongoing_call')"),
        contains('CallerNameResolver.resolveSync'),
      );
      expect(
        section(cc, 'Future<void> _handleNativeAnswer', '_stopNativeIncomingCall'),
        contains('CallerNameResolver.resolveSync'),
      );
    });
  });

  group('Android native resolver mirrors the order', () {
    final kt = source(
      'android/app/src/main/kotlin/com/vant/chat/VantFirebaseMessagingService.kt',
    );

    test('resolveCallerName exists and reads the saved contact cache', () {
      expect(kt, contains('private fun resolveCallerName'));
      expect(kt, contains('flutter.chat_name_'));
      expect(kt, contains('@user_'));
    });

    test('incoming + missed call paths use resolveCallerName', () {
      final incoming = section(kt, 'private fun handleIncomingCall', 'prewarmCallEngine');
      expect(incoming, contains('resolveCallerName'));
      final missed = section(kt, 'private fun handleMissedCall', 'createMissedCallChannel');
      expect(missed, contains('resolveCallerName'));
    });
  });

  group('QR invite carries the inviter name', () {
    test('QR Branch link includes user_name like the share link does', () {
      final profile = source('lib/features/profile/profile_screen.dart');
      final fn = section(profile, '_generateQRData', '_showLinkInfluencerDialog');
      expect(fn, contains('user_name='));
    });

    test('payload QR signs userName and round-trips deviceId + name', () async {
      final data = await QRService.generateQRData(
        deviceId,
        userName: 'Waqar',
      );
      final parsed = await QRService.validateQRDataEx(data);
      expect(parsed, isNotNull);
      expect(parsed!.deviceId, deviceId);
      expect(parsed.userName, 'Waqar');
      // Legacy accessor still works
      expect(await QRService.validateQRData(data), deviceId);
    });

    test('payload QR without a name still validates (back-compat)', () async {
      final data = await QRService.generateQRData(deviceId);
      final parsed = await QRService.validateQRDataEx(data);
      expect(parsed, isNotNull);
      expect(parsed!.deviceId, deviceId);
      expect(parsed.userName, isNull);
    });
  });

  group('iOS decline double-end guard', () {
    final cks = source('lib/core/services/callkit_service.dart');

    test('actionCallDecline removes the uuid from active tracking', () {
      final body = section(cks, 'case Event.actionCallDecline:', 'case Event.actionCallEnded:');
      expect(body, contains('_activeCallKitCalls.remove'));
    });

    test('endCall and declineCall serialize on _endingCallKitUuids', () {
      expect(cks, contains('_endingCallKitUuids'));
      final decline = section(cks, 'Future<void> declineCall', 'Future<void> endCall');
      expect(decline, contains('_endingCallKitUuids.add'));
      final end = section(cks, 'Future<void> endCall', '_handleCallKitEvent');
      expect(end, contains('_endingCallKitUuids.add'));
    });
  });

  group('remote-end delivery + UI dismissal (bug 4)', () {
    final cc = source('lib/features/call/call_controller.dart');

    test('endCall uses HTTP /respond fallback when the socket is down', () {
      final body = section(cc, 'void endCall()', 'minimizeCallScreen');
      expect(body, contains('_socketService.isConnected.value'));
      expect(body, contains('_terminateCallOverHttp'));
    });

    test('rejectCall uses the same HTTP fallback', () {
      final body = section(cc, 'void rejectCall(', 'resetCallStateForRemoteEnd');
      expect(body, contains('_socketService.isConnected.value'));
      expect(body, contains("_terminateCallOverHttp(callId, 'reject')"));
    });

    test('_terminateCallOverHttp posts action to /api/calls/{id}/respond', () {
      final body = section(
        cc,
        'Future<void> _terminateCallOverHttp',
        '/// Handle call rejected',
      );
      expect(body, contains('/api/calls/'));
      expect(body, contains('x-device-id'));
    });

    test('terminated path schedules a guarded call-route dismissal', () {
      final body = section(cc, 'void _handleCallTerminated', 'Future<void> _handleIceCandidate');
      expect(body, contains('_scheduleCallRouteDismissal'));
      final wd = section(cc, 'void _scheduleCallRouteDismissal', 'Future<void> _handleIceCandidate');
      expect(wd, contains("'/chat-list'"));
      expect(wd, contains('canPop'));
      expect(wd, contains("'/call/'"));
    });
  });
}
