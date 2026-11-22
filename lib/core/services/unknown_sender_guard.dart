import 'local_storage_service.dart';

/// Client-side complement to the server's "Block unknown account messages"
/// throttle (Settings → Advanced). When enabled, senders with no local chat
/// are capped at a short burst of incoming messages; excess is dropped
/// silently — no save, no ack, no notification.
class UnknownSenderGuard {
  UnknownSenderGuard._();

  static const int _limit = 5;
  static const int _windowMs = 60 * 1000;

  /// senderId -> timestamps of messages seen in the current window.
  static final Map<String, List<int>> _windows = {};

  /// Returns true when the incoming message from [senderId] should be
  /// dropped. Always returns false when the setting is off or the sender is
  /// a known contact (has a local chat entity).
  static bool shouldDrop(String senderId, LocalStorageService storage) {
    if (senderId.isEmpty) return false;
    if (!storage.blockUnknownMessages) return false;
    // Known contact — any existing chat entity exempts the sender.
    if (storage.getChat(senderId) != null) return false;

    final now = DateTime.now().millisecondsSinceEpoch;
    final hits = _windows.putIfAbsent(senderId, () => <int>[])
      ..removeWhere((t) => now - t > _windowMs);
    if (hits.length >= _limit) return true;
    hits.add(now);
    return false;
  }
}
