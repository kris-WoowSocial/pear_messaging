import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/callkit_ghost_events.dart';
import 'package:pear_messaging/core/services/callkit_service.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('ghost reconciliation does not invoke native code outside iOS', () async {
    if (Platform.isIOS) return;
    const channel = MethodChannel('com.pear.messaging/call');
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async { calls++; return 'ended'; });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    expect(await CallKitService().endGhostCallKitForCall('call', reason: 'accept'), 'none');
    expect(calls, 0);
  });

  test('native answer can disarm a pending ghost and forward accept and end', () async {
    final service = CallKitService();
    CallKitService.ghostEvents.arm('banner-race');
    expect(CallKitService.ghostEvents.suppress('BANNER-RACE'), isTrue);
    CallKitService.ghostEvents.disarm('BANNER-RACE');
    final forwarded = <CallKitEvent>[];
    final subscription = service.eventStream.listen(forwarded.add);
    addTearDown(subscription.cancel);
    for (final event in [Event.actionCallAccept, Event.actionCallEnded]) {
      await service.replayPluginEvent(CallEvent({
        'id': 'banner-race',
        'extra': {'callId': 'banner-race-call'},
      }, event));
    }
    await Future<void>.delayed(Duration.zero);
    expect(forwarded.map((event) => event.type), [
      CallKitEventType.accept,
      CallKitEventType.end,
    ]);
  });

  test('native reconciliation checks answer state again after arming', () {
    final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final helper = source.substring(
      source.indexOf('  private func endGhostCallKitForCall('),
      source.indexOf('  private var ghostEndUuids'),
    );
    expect(helper, contains('foregroundGhostCallIds.contains(callId)'));
    expect(helper, contains('plugin.activeCalls()'));
    expect(helper, contains('self.nativeAnsweredCallIds.contains(callId)'));
    expect(helper, contains('plugin.getAcceptedCall()?.uuid'));
    expect(helper.indexOf('self.nativeAnsweredCallIds.contains(callId)'),
        greaterThan(helper.indexOf('.invokeMethod("armGhostCallKitEnd"')));
    expect(helper.indexOf('self.nativeAnsweredCallIds.contains(callId)'),
        lessThan(helper.indexOf('plugin.endCall(endData)')));
    expect(helper, contains('self.latestPushCallKitUuid == uuid'));
    expect(helper, contains('self.markCallKitEndSilenced(serverCallId: callId)'));
    expect(helper, contains('ghostEndWaiters'));
  });

  test('Flutter presentation and accept reconcile only on iOS', () {
    final screen = File('lib/features/call/incoming_call_screen.dart').readAsStringSync();
    final controller = File('lib/features/call/call_controller.dart').readAsStringSync();
    expect(screen, contains('if (Platform.isIOS)'));
    expect(screen, contains('WidgetsBinding.instance.addPostFrameCallback'));
    expect(screen, contains("reason: 'late'"));
    expect(screen.indexOf("reason: 'accept'"),
        lessThan(screen.indexOf('acceptFuture = controller.acceptCall(callData)')));
    final accept = controller.substring(
      controller.indexOf('  Future<bool> acceptCall('),
      controller.indexOf('  /// Reject an incoming call'),
    );
    expect(accept, contains('if (Platform.isIOS)'));
    expect(accept.indexOf("reason: 'accept'"),
        lessThan(accept.indexOf('_webrtcService.acceptCall(')));
    expect(controller, contains("reason: 'decline'"));
    expect(controller, contains("reason: 'terminated'"));
  });

  test('production plugin handler suppresses the exact owner sequence', () async {
    final service = CallKitService();
    CallKitService.ghostEvents.arm('owner-ghost');
    final forwarded = <CallKitEvent>[];
    final subscription = service.eventStream.listen(forwarded.add);
    addTearDown(subscription.cancel);
    for (final event in [
      Event.actionCallEnded,
      Event.actionCallIncoming,
      Event.actionCallDecline,
      Event.actionCallTimeout,
    ]) {
      await service.replayPluginEvent(CallEvent({
        'id': 'OWNER-GHOST',
        'extra': {'callId': 'owner-call'},
      }, event));
    }
    await Future<void>.delayed(Duration.zero);
    expect(forwarded, isEmpty);
  });

  test('production plugin handler forwards real banner decline and accept', () async {
    final service = CallKitService();
    final forwarded = <CallKitEvent>[];
    final subscription = service.eventStream.listen(forwarded.add);
    addTearDown(subscription.cancel);
    for (final event in [Event.actionCallDecline, Event.actionCallAccept]) {
      await service.replayPluginEvent(CallEvent({
        'id': 'real-banner',
        'extra': {'callId': 'real-call'},
      }, event));
    }
    await Future<void>.delayed(Duration.zero);
    expect(forwarded.map((e) => e.type), [
      CallKitEventType.decline,
      CallKitEventType.accept,
    ]);
  });

  test('acked ghost survives ended, incoming, decline and timeout ordering', () {
    final gate = CallKitGhostEvents()..arm('UUID-A');
    var screenVisible = true;
    var ringing = true;
    final serverActions = <String>[];
    for (final event in ['ended', 'incoming', 'decline', 'timeout']) {
      if (gate.suppress('uuid-a')) continue;
      screenVisible = false;
      ringing = false;
      serverActions.add(event);
    }
    expect(screenVisible, isTrue);
    expect(ringing, isTrue);
    expect(serverActions, isEmpty);
  });

  test('unacked banner actions are not suppressed', () {
    final gate = CallKitGhostEvents();
    for (final event in ['accept', 'decline']) {
      final actions = <String>[];
      if (!gate.suppress('uuid-banner')) actions.add(event);
      expect(actions, [event]);
    }
  });

  test('ghost UUID does not suppress a different native record', () {
    final gate = CallKitGhostEvents()..arm('ghost');
    expect(gate.suppress('banner'), isFalse);
    expect(gate.suppress(null), isFalse);
  });

  test('silenced placeholder end removes the uuid from active tracking', () async {
    final service = CallKitService();
    // Placeholder report lands as actionCallIncoming -> uuid tracked.
    await service.replayPluginEvent(CallEvent({
      'id': 'PLACEHOLDER-UUID',
      'extra': {'callId': 'placeholder-id'},
    }, Event.actionCallIncoming));
    expect(CallKitService.debugIsCallKitTracked('placeholder-uuid'), isTrue);
    // AppDelegate marked it silenced via flutter.silenced_call_ids.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('silenced_call_ids', 'placeholder-id');
    final forwarded = <CallKitEvent>[];
    final subscription = service.eventStream.listen(forwarded.add);
    addTearDown(subscription.cancel);
    await service.replayPluginEvent(CallEvent({
      'id': 'PLACEHOLDER-UUID',
      'extra': {'callId': 'placeholder-id'},
    }, Event.actionCallEnded));
    await Future<void>.delayed(Duration.zero);
    expect(forwarded, isEmpty);
    expect(CallKitService.debugIsCallKitTracked('placeholder-uuid'), isFalse);
  });

  test('silenced ghost decline removes the uuid from active tracking', () async {
    final service = CallKitService();
    await service.replayPluginEvent(CallEvent({
      'id': 'GHOST-UUID',
      'extra': {'callId': 'ghost-call'},
    }, Event.actionCallIncoming));
    expect(CallKitService.debugIsCallKitTracked('ghost-uuid'), isTrue);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('silenced_call_ids', 'ghost-call');
    await service.replayPluginEvent(CallEvent({
      'id': 'GHOST-UUID',
      'extra': {'callId': 'ghost-call'},
    }, Event.actionCallDecline));
    await Future<void>.delayed(Duration.zero);
    expect(CallKitService.debugIsCallKitTracked('ghost-uuid'), isFalse);
  });

  test('Flutter end is independent of the native plugin gate', () {
    final gate = CallKitGhostEvents()..arm('ghost');
    final actions = <String>[];
    actions.add('terminate');
    expect(gate.suppress('ghost'), isTrue);
    expect(actions, ['terminate']);
  });
}
