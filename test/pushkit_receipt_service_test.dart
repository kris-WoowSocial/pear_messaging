import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pear_messaging/core/services/pushkit_receipt_service.dart';

/// Behavioral tests for the PushKit receipt drain: native receipts are only
/// cleared after a confirmed upload (or a known-endpoint answer), never on
/// fetch alone — a failed upload must keep them buffered for next launch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({
        'device_id': 'dev-1',
      }));

  test('uploads receipts then clears the native buffer', () async {
    var cleared = false;
    final posted = <String>[];
    final svc = PushKitReceiptService()
      ..receiptFetcher = (() async => [
            {
              'ts': 1,
              'callId': 'cs_1',
              'type': 'incoming_call',
              'event': 'received'
            },
            {
              'ts': 2,
              'callId': 'cs_1',
              'type': 'incoming_call',
              'event': 'callkit_reported'
            },
          ])
      ..poster = ((uri, headers, body) async {
        posted.add(body);
        return 200;
      })
      ..receiptClearer = (() async => cleared = true);

    await svc.drainAndUpload();
    expect(posted.length, 1);
    expect(posted.first, contains('cs_1'));
    expect(cleared, isTrue);
  });

  test('failed upload leaves receipts buffered (no clear)', () async {
    var cleared = false;
    final svc = PushKitReceiptService()
      ..receiptFetcher = (() async => [
            {
              'ts': 1,
              'callId': 'cs_1',
              'type': 'incoming_call',
              'event': 'received'
            },
          ])
      ..poster = ((uri, headers, body) async => throw Exception('offline'))
      ..receiptClearer = (() async => cleared = true);

    await svc.drainAndUpload();
    expect(cleared, isFalse);
  });

  test('404 (endpoint not yet deployed) clears after logging', () async {
    var cleared = false;
    final svc = PushKitReceiptService()
      ..receiptFetcher = (() async => [
            {
              'ts': 1,
              'callId': 'cs_1',
              'type': 'incoming_call',
              'event': 'received'
            },
          ])
      ..poster = ((uri, headers, body) async => 404)
      ..receiptClearer = (() async => cleared = true);

    await svc.drainAndUpload();
    expect(cleared, isTrue);
  });

  test('empty buffer is a no-op — no post, no clear', () async {
    var cleared = false, posted = 0;
    final svc = PushKitReceiptService()
      ..receiptFetcher = (() async => <Map<String, dynamic>>[])
      ..poster = ((uri, headers, body) async {
        posted++;
        return 200;
      })
      ..receiptClearer = (() async => cleared = true);

    await svc.drainAndUpload();
    expect(posted, 0);
    expect(cleared, isFalse);
  });
}
