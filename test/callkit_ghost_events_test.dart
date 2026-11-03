import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/callkit_ghost_events.dart';
import 'package:pear_messaging/core/services/callkit_service.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
