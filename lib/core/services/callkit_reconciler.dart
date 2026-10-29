class CallKitReconciler {
  CallKitReconciler({required this.activeCalls, required this.endUuid});

  final Future<List<Map<dynamic, dynamic>>> Function() activeCalls;
  final Future<void> Function(String uuid) endUuid;
  final Set<String> _ending = {};

  Future<void> reconcile({
    required Set<String> completedCallIds,
    required String Function() liveCallId,
    String? completedCallId,
    Future<void> Function(Set<String>)? saveCompleted,
  }) async {
    if (completedCallId != null && completedCallId.isNotEmpty) {
      completedCallIds.add(completedCallId);
      await saveCompleted?.call(completedCallIds);
    }
    for (final record in await activeCalls()) {
      final extra = record['extra'];
      final callId = extra is Map ? extra['callId'] : null;
      final uuid = record['id'];
      if (callId is! String ||
          uuid is! String ||
          uuid.isEmpty ||
          !completedCallIds.contains(callId) ||
          callId == liveCallId() ||
          !_ending.add(uuid.toLowerCase())) {
        continue;
      }
      try {
        await endUuid(uuid);
      } finally {
        _ending.remove(uuid.toLowerCase());
      }
    }
  }
}
