/// Memoizes the server's STUN/TURN ICE server list.
///
/// TURN credentials are minted server-side and stay valid for their TTL
/// (15 min by default), but the app requests the list once per peer
/// connection plus once per incoming ring. During call bursts that can
/// exceed the server's per-device mint budget, which previously meant a
/// silent STUN-only fallback. This cache serves a memoized list for
/// [memoTtl], shares one in-flight request across callers
/// (single-flight), and — when a fresh fetch fails (rate-limited,
/// timeout, malformed) — falls back to the last still-valid credentials
/// instead of STUN-only.
class IceServersRequestCache {
  IceServersRequestCache({
    this.memoTtl = const Duration(seconds: 60),
    this.staleMargin = const Duration(seconds: 30),
    this.unknownExpiryWindow = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// How long a fresh fetch is reused without a new request.
  final Duration memoTtl;

  /// Credentials are treated as dead this long before their server expiry.
  final Duration staleMargin;

  /// When the server sends no expiresAt (older builds), stale cache is
  /// served only within this window — well under the TURN credential TTL.
  final Duration unknownExpiryWindow;

  final DateTime Function() _now;

  List<Map<String, dynamic>>? _servers;
  DateTime? _fetchedAt;
  int? _expiresAtEpoch;
  Future<List<Map<String, dynamic>>?>? _inFlight;

  bool get _stillValid {
    final exp = _expiresAtEpoch;
    if (exp != null) {
      return exp * 1000 >
          _now().millisecondsSinceEpoch + staleMargin.inMilliseconds;
    }
    final at = _fetchedAt;
    return at != null && _now().difference(at) < unknownExpiryWindow;
  }

  /// Fetch the ICE list through the cache. [fetch] returns the parsed
  /// server list plus the credential expiry (epoch seconds) when present.
  Future<List<Map<String, dynamic>>?> request(
    Future<({List<Map<String, dynamic>>? servers, int? expiresAtEpoch})>
        Function() fetch,
  ) {
    final servers = _servers;
    final at = _fetchedAt;
    if (servers != null &&
        at != null &&
        _now().difference(at) < memoTtl) {
      return Future.value(servers);
    }
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final future = () async {
      final result = await fetch();
      final fresh = result.servers;
      if (fresh != null && fresh.isNotEmpty) {
        _servers = fresh;
        _fetchedAt = _now();
        _expiresAtEpoch = result.expiresAtEpoch;
        return fresh;
      }
      return _stillValid ? _servers : null;
    }();
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
  }

  void clear() {
    _servers = null;
    _fetchedAt = null;
    _expiresAtEpoch = null;
  }
}
