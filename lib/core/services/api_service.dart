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

  Future<http.Response> _delete(String path, {Map<String, dynamic>? body}) =>
      http
          .delete(_uri(path),
              headers: _headers, body: body != null ? jsonEncode(body) : null)
          .timeout(_timeout);

  Future<http.Response> _patch(String path, Map<String, dynamic> body) => http
      .patch(_uri(path), headers: _headers, body: jsonEncode(body))
      .timeout(_timeout);

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

  /// Reports a successful in-app purchase (Apple IAP / Google Play Billing)
  /// to the backend so it's recorded and referral commission is credited to
  /// the influencer/inviter chain, if any. Without this call, real purchases
  /// never reach the backend and influencers never get paid.
  Future<Map<String, dynamic>> recordIAPPurchase({
    required String deviceId,
    required String planId,
    required int amountCents,
    required String currency,
    required String purchaseId,
    required String countryCode,
    required String platform, // 'android' or 'ios'
  }) async {
    final res = await _post('/api/membership/record-google-play-purchase', {
      'deviceId': deviceId,
      'planId': planId,
      'amount': amountCents,
      'currency': currency,
      'purchaseId': purchaseId,
      'countryCode': countryCode,
      'platform': platform,
    });
    return _decode(res, 'recordIAPPurchase');
  }

  // ── Stripe subscription (7-day trial + auto-renew on the app's real ────────
  // 6_months / 1_year plans) ──────────────────────────────────────────────────
  // New, additive endpoints - do not affect the existing in_app_purchase flow.

  Future<Map<String, dynamic>> createStripeSubscription(
      String deviceId, String planId,
      {String? email}) async {
    final res = await _post('/api/membership/stripe/create-subscription', {
      'deviceId': deviceId,
      'planId': planId,
      if (email != null) 'email': email,
    });
    return _decode(res, 'createStripeSubscription');
  }

  Future<Map<String, dynamic>> confirmStripeSubscription(
      String deviceId, String subscriptionId) async {
    final res = await _post('/api/membership/stripe/confirm-subscription', {
      'deviceId': deviceId,
      'subscriptionId': subscriptionId,
    });
    return _decode(res, 'confirmStripeSubscription');
  }

  Future<Map<String, dynamic>> cancelStripeSubscription(String deviceId) async {
    final res = await _post(
        '/api/membership/stripe/cancel-subscription', {'deviceId': deviceId});
    return _decode(res, 'cancelStripeSubscription');
  }

  Future<Map<String, dynamic>> getStripeSubscriptionStatus(
      String deviceId) async {
    final res =
        await _get('/api/membership/stripe/subscription-status/$deviceId');
    return _decode(res, 'getStripeSubscriptionStatus');
  }

  // ── Crypto payment (one-time, via Stripe's own "Stablecoins and Crypto" ────
  // payment method - customer connects a wallet at crypto.stripe.com and
  // pays in USDC; Stripe settles USD to your balance) ────────────────────────

  Future<Map<String, dynamic>> createCryptoCheckout({
    required String deviceId,
    required String planId,
  }) async {
    final res = await _post('/api/membership/stripe/create-crypto-checkout', {
      'deviceId': deviceId,
      'planId': planId,
    });
    return _decode(res, 'createCryptoCheckout');
  }

  Future<Map<String, dynamic>> getCryptoCheckoutStatus(String deviceId) async {
    final res =
        await _get('/api/membership/stripe/crypto-checkout-status/$deviceId');
    return _decode(res, 'getCryptoCheckoutStatus');
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
        debugPrint(
            '⚠️ claimAcceptedInvite HTTP ${res.statusCode}: ${res.body}');
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
    final res = await _post('/api/referrals/link-vant-account',
        {'token': token, 'deviceId': deviceId});
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

  // ── Groups ────────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> createGroup({
    required String name,
    required String createdBy,
    List<String> memberDeviceIds = const [],
    String? avatarUrl,
  }) async {
    final res = await _post('/api/groups', {
      'name': name,
      'createdBy': createdBy,
      'memberDeviceIds': memberDeviceIds,
      if (avatarUrl != null) 'avatarUrl': avatarUrl,
    });
    return _decode(res, 'createGroup');
  }

  Future<Map<String, dynamic>> getGroup({
    required String groupId,
    required String deviceId,
  }) async {
    final res = await _get('/api/groups/$groupId?deviceId=$deviceId');
    return _decode(res, 'getGroup');
  }

  Future<List<dynamic>> getGroupsForDevice(String deviceId) async {
    final res = await _get('/api/groups?deviceId=$deviceId');
    final data = _decode(res, 'getGroupsForDevice');
    return data['groups'] as List<dynamic>? ?? [];
  }

  Future<Map<String, dynamic>> addGroupMembers({
    required String groupId,
    required String deviceId,
    required List<String> memberDeviceIds,
  }) async {
    final res = await _post('/api/groups/$groupId/members', {
      'deviceId': deviceId,
      'memberDeviceIds': memberDeviceIds,
    });
    return _decode(res, 'addGroupMembers');
  }

  Future<Map<String, dynamic>> removeGroupMember({
    required String groupId,
    required String targetDeviceId,
    required String deviceId,
  }) async {
    final res = await _delete(
      '/api/groups/$groupId/members/$targetDeviceId',
      body: {'deviceId': deviceId},
    );
    return _decode(res, 'removeGroupMember');
  }

  Future<Map<String, dynamic>> leaveGroup({
    required String groupId,
    required String deviceId,
  }) async {
    return removeGroupMember(
      groupId: groupId,
      targetDeviceId: deviceId,
      deviceId: deviceId,
    );
  }

  Future<Map<String, dynamic>> updateGroupInfo({
    required String groupId,
    required String deviceId,
    String? name,
    String? avatarUrl,
  }) async {
    final body = <String, dynamic>{'deviceId': deviceId};
    if (name != null) body['name'] = name;
    if (avatarUrl != null) body['avatarUrl'] = avatarUrl;
    final res = await _patch('/api/groups/$groupId', body);
    return _decode(res, 'updateGroupInfo');
  }

  Future<Map<String, dynamic>> promoteGroupMember({
    required String groupId,
    required String targetDeviceId,
    required String deviceId,
  }) async {
    final res = await _post(
      '/api/groups/$groupId/admins/$targetDeviceId',
      {'deviceId': deviceId},
    );
    return _decode(res, 'promoteGroupMember');
  }

  Future<Map<String, dynamic>> demoteGroupMember({
    required String groupId,
    required String targetDeviceId,
    required String deviceId,
  }) async {
    final res = await _delete(
      '/api/groups/$groupId/admins/$targetDeviceId',
      body: {'deviceId': deviceId},
    );
    return _decode(res, 'demoteGroupMember');
  }

  Future<Map<String, dynamic>> dissolveGroup({
    required String groupId,
    required String deviceId,
  }) async {
    final res =
        await _delete('/api/groups/$groupId', body: {'deviceId': deviceId});
    return _decode(res, 'dissolveGroup');
  }

  Future<Map<String, dynamic>> joinGroupByInvite({
    required String inviteCode,
    required String deviceId,
  }) async {
    final res = await _post('/api/groups/join/$inviteCode', {
      'deviceId': deviceId,
    });
    return _decode(res, 'joinGroupByInvite');
  }

  Future<Map<String, dynamic>> getGroupByInviteCode(String inviteCode) async {
    final res = await _get('/api/groups/invite/$inviteCode');
    return _decode(res, 'getGroupByInviteCode');
  }
}
