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

  // ── Referrals ────────────────────────────────────────────────────────────────

  /// Claim referral attribution when a referred user accepts the invite that
  /// brought them into the app. Provide either [influencerCode] (influencer
  /// referral link) or [inviterDeviceId] (chat invite from a referred user).
  /// Returns true if a new attribution was created, false otherwise.
  Future<bool> claimAcceptedInvite({
    required String referredDeviceId,
    String? influencerCode,
    String? inviterDeviceId,
  }) async {
    if ((influencerCode == null || influencerCode.isEmpty) &&
        (inviterDeviceId == null || inviterDeviceId.isEmpty)) {
      return false;
    }
    try {
      final body = <String, dynamic>{'referredDeviceId': referredDeviceId};
      if (influencerCode != null && influencerCode.isNotEmpty) {
        body['influencerCode'] = influencerCode;
      }
      if (inviterDeviceId != null && inviterDeviceId.isNotEmpty) {
        body['inviterDeviceId'] = inviterDeviceId;
      }
      final res = await _post('/api/referrals/claim-accepted-invite', body);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        debugPrint('⚠️ claimAcceptedInvite HTTP ${res.statusCode}: ${res.body}');
        return false;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return data['created'] == true;
    } catch (e) {
      debugPrint('⚠️ claimAcceptedInvite failed: $e');
      return false;
    }
  }

  /// Look up the influencer linked to this device, if any.
  Future<Map<String, dynamic>?> getInfluencerByDeviceId(String deviceId) async {
    try {
      final res = await _get('/api/referrals/influencer-by-device/$deviceId');
      if (res.statusCode == 404) return null;
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('⚠️ getInfluencerByDeviceId failed: $e');
      return null;
    }
  }

  /// Link a Vant account (device) to an influencer using a one-time token.
  Future<Map<String, dynamic>> linkVantAccount({
    required String token,
    required String deviceId,
  }) async {
    final res = await _post(
        '/api/referrals/link-vant-account', {'token': token, 'deviceId': deviceId});
    return _decode(res, 'linkVantAccount');
  }

  /// Report an unverified in-app purchase for referral event logging.
  /// Commission is never credited for these events (verification required).
  Future<bool> reportUnverifiedIap({
    required String deviceId,
    required String purchaseId,
    required String paymentMethod,
  }) async {
    try {
      final res = await _post('/api/referrals/iap-unverified', {
        'deviceId': deviceId,
        'purchaseId': purchaseId,
        'paymentMethod': paymentMethod,
      });
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint('⚠️ reportUnverifiedIap failed: $e');
      return false;
    }
  }
}
