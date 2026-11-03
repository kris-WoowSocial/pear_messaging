/// Emits `peer_ringing` to the caller exactly once per call, at the moment
/// the callee's call UI is actually presented (Flutter incoming screen,
/// CallKit report on a VoIP wake, or the native incoming activity — i.e.
/// every path that stores `_latestIncomingCallData`).
///
/// Deduped per callId so resync re-emissions and duplicate `incoming_call`
/// deliveries can't spam the caller — the server forwards every emit to the
/// caller's socket.
class PeerRingingNotifier {
  PeerRingingNotifier(this._emit);

  final void Function({required String callId, required String callerId}) _emit;

  String? _sentForCallId;
  String? get sentForCallId => _sentForCallId;

  /// Emits once for [callId]; subsequent calls with the same id return false.
  bool notify({required String callId, required String callerId}) {
    if (callId.isEmpty || callerId.isEmpty) return false;
    if (_sentForCallId == callId) return false;
    _sentForCallId = callId;
    _emit(callId: callId, callerId: callerId);
    return true;
  }

  /// Called when the call resets so the next call can emit again.
  void reset() => _sentForCallId = null;
}
