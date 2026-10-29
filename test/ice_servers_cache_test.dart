import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/ice_servers_cache.dart';

void main() {
  List<Map<String, dynamic>> fakeServers(String tag) => [
        {'urls': 'stun:test:3478'},
        {'urls': 'turn:test:3478', 'username': tag, 'credential': 'x'},
      ];

  test('memoizes the list for the TTL — fetch called once', () async {
    var t = DateTime.fromMillisecondsSinceEpoch(1000000);
    final cache = IceServersRequestCache(now: () => t);
    var calls = 0;

    Future<({List<Map<String, dynamic>>? servers, int? expiresAtEpoch})>
        fetch() async {
      calls++;
      return (servers: fakeServers('u1'), expiresAtEpoch: null);
    }

    expect(await cache.request(fetch), isNotNull);
    expect(await cache.request(fetch), isNotNull);
    expect(calls, 1);

    t = t.add(const Duration(seconds: 61));
    expect(await cache.request(fetch), isNotNull);
    expect(calls, 2);
  });

  test('single-flight — concurrent requests share one fetch', () async {
    final cache = IceServersRequestCache();
    var calls = 0;

    Future<({List<Map<String, dynamic>>? servers, int? expiresAtEpoch})>
        fetch() async {
      calls++;
      await Future.delayed(const Duration(milliseconds: 50));
      return (servers: fakeServers('u1'), expiresAtEpoch: null);
    }

    final results = await Future.wait([
      cache.request(fetch),
      cache.request(fetch),
      cache.request(fetch),
    ]);
    expect(calls, 1);
    for (final r in results) {
      expect(r, isNotNull);
    }
  });

  test('failed fetch serves stale-but-valid cached credentials', () async {
    var t = DateTime.fromMillisecondsSinceEpoch(1000000);
    final cache = IceServersRequestCache(now: () => t);
    var calls = 0;

    Future<({List<Map<String, dynamic>>? servers, int? expiresAtEpoch})>
        fetch() async {
      calls++;
      if (calls == 1) {
        // Valid for ~10 more minutes.
        return (
          servers: fakeServers('u1'),
          expiresAtEpoch:
              (t.millisecondsSinceEpoch + 600 * 1000) ~/ 1000,
        );
      }
      return (servers: null, expiresAtEpoch: null); // rate_limited/timeout
    }

    final first = await cache.request(fetch);
    expect(first, isNotNull);

    t = t.add(const Duration(seconds: 61)); // memo expired
    final second = await cache.request(fetch);
    expect(calls, 2);
    expect(second, isNotNull);
    expect(second![1]['username'], 'u1');
  });

  test('failed fetch returns null once cached creds are near expiry', () async {
    var t = DateTime.fromMillisecondsSinceEpoch(1000000);
    final cache = IceServersRequestCache(now: () => t);
    var calls = 0;

    Future<({List<Map<String, dynamic>>? servers, int? expiresAtEpoch})>
        fetch() async {
      calls++;
      if (calls == 1) {
        // Expires 20s after fetch — inside the 30s stale margin.
        return (
          servers: fakeServers('u1'),
          expiresAtEpoch:
              (t.millisecondsSinceEpoch + 20 * 1000) ~/ 1000,
        );
      }
      return (servers: null, expiresAtEpoch: null);
    }

    await cache.request(fetch);
    t = t.add(const Duration(seconds: 61));
    expect(await cache.request(fetch), isNull);
  });

  test('failed fetch with no cache returns null', () async {
    final cache = IceServersRequestCache();
    final result = await cache.request(
      () async => (
        servers: null as List<Map<String, dynamic>>?,
        expiresAtEpoch: null as int?,
      ),
    );
    expect(result, isNull);
  });
}
