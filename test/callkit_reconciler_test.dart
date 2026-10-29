import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/callkit_reconciler.dart';

void main() {
  test(
      'socket termination records completion before requiring a controller listener',
      () {
    final source =
        File('lib/core/services/socket_service.dart').readAsStringSync();
    final start = source.indexOf("_socket?.on('call_terminated'");
    final end = source.indexOf('\n    });', start);
    final handler = source.substring(start, end);
    expect(handler.indexOf('reconcileNativeCalls'), greaterThanOrEqualTo(0));
    expect(handler.indexOf('completedCallId: data[\'callId\'] as String'),
        greaterThanOrEqualTo(0));
    expect(handler.indexOf('reconcileNativeCalls'),
        lessThan(handler.indexOf('if (onCallTerminated != null')));
  });

  Map<String, dynamic> record(String uuid, String callId) => {
        'id': uuid,
        'extra': {'callId': callId}
      };

  test('ends a completed native orphan by its real UUID', () async {
    final ended = <String>[];
    final reconciler = CallKitReconciler(
      activeCalls: () async => [record('native-uuid', 'ended')],
      endUuid: (uuid) async => ended.add(uuid),
    );
    await reconciler
        .reconcile(completedCallIds: {'ended'}, liveCallId: () => '');
    expect(ended, ['native-uuid']);
  });

  test('untracked remote termination is persisted before native cleanup',
      () async {
    final completed = <String>{};
    final ended = <String>[];
    final persisted = <Set<String>>[];
    final reconciler = CallKitReconciler(
      activeCalls: () async => [record('native-cold-uuid', 'remote-only')],
      endUuid: (uuid) async {
        expect(persisted.single, contains('remote-only'));
        ended.add(uuid);
      },
    );
    await reconciler.reconcile(
      completedCallIds: completed,
      liveCallId: () => '',
      completedCallId: 'remote-only',
      saveCompleted: (ids) async => persisted.add(Set.of(ids)),
    );
    expect(completed, {'remote-only'});
    expect(ended, ['native-cold-uuid']);
  });

  test('live call wins over stale completed-call state', () async {
    final ended = <String>[];
    final reconciler = CallKitReconciler(
      activeCalls: () async => [record('u', 'live')],
      endUuid: (uuid) async => ended.add(uuid),
    );
    await reconciler
        .reconcile(completedCallIds: {'live'}, liveCallId: () => 'live');
    expect(ended, isEmpty);
  });

  test('different call and pending cold-start call are untouched', () async {
    final ended = <String>[];
    final reconciler = CallKitReconciler(
      activeCalls: () async => [
        record('a', 'ended'),
        record('b', 'incoming'),
        {'id': 'unknown'}
      ],
      endUuid: (uuid) async => ended.add(uuid),
    );
    await reconciler
        .reconcile(completedCallIds: {'ended'}, liveCallId: () => 'incoming');
    expect(ended, ['a']);
  });

  test('overlapping reconciliation does not issue duplicate native ends',
      () async {
    final completion = Completer<void>();
    var ends = 0;
    final reconciler = CallKitReconciler(
      activeCalls: () async => [record('u', 'ended')],
      endUuid: (_) {
        ends++;
        return completion.future;
      },
    );
    final first =
        reconciler.reconcile(completedCallIds: {'ended'}, liveCallId: () => '');
    await Future<void>.delayed(Duration.zero);
    await reconciler
        .reconcile(completedCallIds: {'ended'}, liveCallId: () => '');
    expect(ends, 1);
    completion.complete();
    await first;
  });

  test('native end failure remains retryable', () async {
    var attempts = 0;
    final reconciler = CallKitReconciler(
      activeCalls: () async => [record('u', 'ended')],
      endUuid: (_) async {
        if (++attempts == 1) throw StateError('retry');
      },
    );
    await expectLater(
        reconciler.reconcile(completedCallIds: {'ended'}, liveCallId: () => ''),
        throwsStateError);
    await reconciler
        .reconcile(completedCallIds: {'ended'}, liveCallId: () => '');
    expect(attempts, 2);
  });
}
