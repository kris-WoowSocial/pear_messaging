import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import '../constants/network_constants.dart';

/// Drains the native PushKit receipt log and uploads it at next foreground.
///
/// Why: production forensics showed incoming-call VoIP pushes accepted by
/// APNs (200) but the callee device never woke during the ring window — while
/// later pushes to the SAME token did. The server cannot distinguish "iOS
/// dropped the push" from "push arrived but the app couldn't report it to
/// CallKit". This log closes that gap: AppDelegate records every VoIP push
/// receipt (timestamp, callId, type, CallKit-report outcome) synchronously
/// into UserDefaults; on the next foreground launch we upload the batch.
///
/// Privacy: entries carry ONLY {ts, callId, type, reported} — no names, no
/// message content, no tokens.
class PushKitReceiptService {
  PushKitReceiptService._();
  static final PushKitReceiptService _instance = PushKitReceiptService._();
  factory PushKitReceiptService() => _instance;

  static const MethodChannel _channel = MethodChannel(
    'com.pear.messaging/call',
  );

  /// Injectable for tests — returns receipts {ts, callId, type, reported}
  /// and clears them natively ONLY after a confirmed upload.
  Future<List<Map<String, dynamic>>> Function()? receiptFetcher;
  Future<void> Function()? receiptClearer;
  Future<int> Function(Uri uri, Map<String, String> headers, String body)?
      poster;

  bool _uploadInFlight = false;

  /// Drain + upload. Safe to call from any lifecycle point — concurrent
  /// calls coalesce, non-iOS is a no-op, every failure leaves receipts
  /// buffered for the next attempt.
  Future<void> drainAndUpload() async {
    // Non-iOS without injected seams is a no-op; tests inject fetch/post.
    if (!Platform.isIOS && receiptFetcher == null) return;
    if (_uploadInFlight) return;
    _uploadInFlight = true;
    try {
      final receipts = await _fetch();
      if (receipts.isEmpty) return;
      for (final r in receipts) {
        debugPrint('📱 PushKit receipt: $r');
      }
      final deviceId =
          (await SharedPreferences.getInstance()).getString('device_id');
      if (deviceId == null || deviceId.isEmpty) return;
      final status = await _post(
        Uri.parse('${NetworkConstants.apiBaseUrl}/api/devices/push-receipts'),
        {'Content-Type': 'application/json', 'x-device-id': deviceId},
        jsonEncode({'receipts': receipts}),
      );
      debugPrint('📱 PushKit receipts upload → $status (${receipts.length})');
      if (status == 200 || status == 204 || status == 404) {
        // 200/204 = stored; 404 = endpoint not deployed yet — receipts were
        // already mirrored to the console log, so dropping them is safe and
        // avoids unbounded buffering on builds ahead of the server route.
        await _clear();
      }
    } catch (e) {
      debugPrint('⚠️ PushKitReceiptService: drain/upload failed: $e');
    } finally {
      _uploadInFlight = false;
    }
  }

  Future<List<Map<String, dynamic>>> _fetch() async {
    if (receiptFetcher != null) return receiptFetcher!();
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'getPushKitReceipts',
    );
    return (raw ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  Future<void> _clear() async {
    if (receiptClearer != null) return receiptClearer!();
    await _channel.invokeMethod<void>('clearPushKitReceipts');
  }

  Future<int> _post(Uri uri, Map<String, String> headers, String body) async {
    if (poster != null) return poster!(uri, headers, body);
    final res = await http
        .post(uri, headers: headers, body: body)
        .timeout(const Duration(seconds: 8));
    return res.statusCode;
  }
}
