import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../constants/network_constants.dart';

/// Centralised HTTP client for all backend API calls.
/// All services must use this instead of constructing raw http.* calls.
class ApiService extends GetxService {
  static const Duration _timeout = Duration(seconds: 10);
  static String get _base => NetworkConstants.apiBaseUrl;

  // ── Singleton accessor ──────────────────────────────────────────────────────
  static ApiService get to => Get.find<ApiService>();

  Future<ApiService> init() async {
    debugPrint('✅ ApiService initialized (base: $_base)');
    return this;
  }

  // ── Low-level helpers ───────────────────────────────────────────────────────

  Map<String, String> get _headers => {'Content-Type': 'application/json'};

  Uri _uri(String path) => Uri.parse('$_base$path');

  Future<http.Response> _get(String path) =>
      http.get(_uri(path), headers: _headers).timeout(_timeout);

  Future<http.Response> _post(String path, Map<String, dynamic> body) => http
      .post(_uri(path), headers: _headers, body: jsonEncode(body))
      .timeout(_timeout);

  Future<http.Response> _delete(String path) =>
      http.delete(_uri(path), headers: _headers).timeout(_timeout);

  /// Decode and return body map, throws on non-2xx.
  Map<String, dynamic> _decode(http.Response res, String label) {
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('[$label] HTTP ${res.statusCode}: ${res.body}');
    }
    return data;
  }

  // ── Region ──────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> detectRegion() async {
    final res = await _get('/api/membership/detect-region');
    return _decode(res, 'detectRegion');
  }

  // ── Membership ──────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> syncMembershipStatus(String deviceId) async {
    final res = await _get('/api/membership/sync-status/$deviceId');
    return _decode(res, 'syncMembershipStatus');
  }

  Future<void> unregisterDevice(String deviceId) async {
    final res = await _delete('/api/membership/unregister-device/$deviceId');
    if (res.statusCode >= 300) {
      throw Exception('[unregisterDevice] HTTP ${res.statusCode}');
    }
  }

  // ── Username ─────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> setUsername(
      String deviceId, String username) async {
    final res = await _post(
        '/api/username', {'deviceId': deviceId, 'username': username});
    return _decode(res, 'setUsername');
  }

  Future<Map<String, dynamic>?> getUsername(String deviceId) async {
    final res = await _get('/api/username/$deviceId');
    if (res.statusCode == 404) return null;
    return _decode(res, 'getUsername');
  }

  Future<Map<String, dynamic>> getBatchUsernames(List<String> deviceIds) async {
    final res = await _post('/api/username/batch', {'deviceIds': deviceIds});
    return _decode(res, 'getBatchUsernames');
  }

  Future<void> deleteUsername(String deviceId) async {
    final res = await _delete('/api/username/$deviceId');
    if (res.statusCode >= 300) {
      throw Exception('[deleteUsername] HTTP ${res.statusCode}');
    }
  }

  Future<Map<String, dynamic>> syncContactName({
    required String ownerDeviceId,
    required String contactDeviceId,
    required String displayName,
  }) async {
    final res = await _post('/api/username/contact', {
      'ownerDeviceId': ownerDeviceId,
      'contactDeviceId': contactDeviceId,
      'displayName': displayName,
    });
    return _decode(res, 'syncContactName');
  }

  // ── Reports / Moderation ────────────────────────────────────────────────────

  Future<bool> submitReport({
    required String reporterDeviceId,
    required String targetType,
    required String targetId,
    required String reason,
    String description = '',
  }) async {
    final res = await _post('/api/reports', {
      'reporterDeviceId': reporterDeviceId,
      'targetType': targetType,
      'targetId': targetId,
      'reason': reason,
      'description': description,
    });
    return res.statusCode == 201;
  }

  Future<bool> submitContactMessage({
    required String name,
    required String email,
    required String message,
  }) async {
    final res = await _post(
        '/api/contact', {'name': name, 'email': email, 'message': message});
    return res.statusCode == 201;
  }

  Future<Map<String, dynamic>?> checkModerationStatus(String deviceId) async {
    final res = await _get('/api/moderation/status/$deviceId');
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}
