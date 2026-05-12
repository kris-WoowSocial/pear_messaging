import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class MembershipService extends GetxService {
  static const String _installDateKey = 'app_install_date';
  static const String _membershipStatusKey = 'membership_status';
  static const String _membershipPlanKey = 'membership_plan';
  static const String _membershipExpiryKey = 'membership_expiry_date';
  static const String _membershipPurchaseDateKey = 'membership_purchase_date';

  static const int _freeMediaDays = 7;

  late SharedPreferences _prefs;

  final RxString status = 'free'.obs;
  final RxString plan = ''.obs;
  final Rx<DateTime?> expiryDate = Rx<DateTime?>(null);
  final RxInt daysInstalled = 0.obs;

  Future<MembershipService> init() async {
    _prefs = await SharedPreferences.getInstance();

    if (!_prefs.containsKey(_installDateKey)) {
      await _prefs.setInt(
          _installDateKey, DateTime.now().millisecondsSinceEpoch);
    }

    final installMs = _prefs.getInt(_installDateKey)!;
    daysInstalled.value = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(installMs))
        .inDays;

    status.value = _prefs.getString(_membershipStatusKey) ?? 'free';
    plan.value = _prefs.getString(_membershipPlanKey) ?? '';

    final expiryMs = _prefs.getInt(_membershipExpiryKey);
    if (expiryMs != null) {
      final expiry = DateTime.fromMillisecondsSinceEpoch(expiryMs);
      expiryDate.value = expiry;
      if (DateTime.now().isAfter(expiry)) {
        await _expireMembership();
      }
    }

    print(
        '✅ MembershipService initialized - status: ${status.value}, daysInstalled: ${daysInstalled.value}');
    return this;
  }

  bool get isPremium =>
      status.value == 'premium' &&
      (expiryDate.value == null || DateTime.now().isBefore(expiryDate.value!));

  bool get canShareMedia {
    if (isPremium) return true;
    return daysInstalled.value < _freeMediaDays;
  }

  int get freeMediaDaysRemaining {
    if (isPremium) return -1;
    final remaining = _freeMediaDays - daysInstalled.value;
    return remaining > 0 ? remaining : 0;
  }

  int get membershipDaysRemaining {
    if (!isPremium || expiryDate.value == null) return 0;
    return expiryDate.value!.difference(DateTime.now()).inDays;
  }

  String get statusLabel {
    if (isPremium) {
      return plan.value == '1_year' ? '1-Year Premium' : '6-Month Premium';
    }
    return 'Free Plan';
  }

  String get statusDescription {
    if (isPremium) {
      if (expiryDate.value != null) {
        final d = expiryDate.value!;
        return 'Expires ${d.day}/${d.month}/${d.year} · $membershipDaysRemaining days left';
      }
      return 'Active';
    }
    if (freeMediaDaysRemaining > 0) {
      return '$freeMediaDaysRemaining day${freeMediaDaysRemaining == 1 ? '' : 's'} of free media remaining';
    }
    return 'Upgrade to share photos & videos';
  }

  Future<void> activateMembership({
    required String selectedPlan,
    required String purchaseId,
  }) async {
    final now = DateTime.now();
    final expiry = selectedPlan == '1_year'
        ? now.add(const Duration(days: 365))
        : now.add(const Duration(days: 183));

    await _prefs.setString(_membershipStatusKey, 'premium');
    await _prefs.setString(_membershipPlanKey, selectedPlan);
    await _prefs.setInt(_membershipExpiryKey, expiry.millisecondsSinceEpoch);
    await _prefs.setInt(_membershipPurchaseDateKey, now.millisecondsSinceEpoch);
    await _prefs.setString('purchase_id', purchaseId);

    status.value = 'premium';
    plan.value = selectedPlan;
    expiryDate.value = expiry;

    print(
        '✅ Membership activated: $selectedPlan, expires: $expiry, purchaseId: $purchaseId');
  }

  Future<void> restoreMembership({
    required String purchaseId,
    required String selectedPlan,
    required DateTime purchaseDate,
  }) async {
    final expiry = selectedPlan == '1_year'
        ? purchaseDate.add(const Duration(days: 365))
        : purchaseDate.add(const Duration(days: 183));

    // Only restore if not expired
    if (DateTime.now().isBefore(expiry)) {
      await _prefs.setString(_membershipStatusKey, 'premium');
      await _prefs.setString(_membershipPlanKey, selectedPlan);
      await _prefs.setInt(_membershipExpiryKey, expiry.millisecondsSinceEpoch);
      await _prefs.setInt(
          _membershipPurchaseDateKey, purchaseDate.millisecondsSinceEpoch);
      await _prefs.setString('purchase_id', purchaseId);

      status.value = 'premium';
      plan.value = selectedPlan;
      expiryDate.value = expiry;

      print('✅ Membership restored: $selectedPlan, expires: $expiry');
    } else {
      print('⚠️ Cannot restore - membership expired on $expiry');
    }
  }

  Future<void> _expireMembership() async {
    await _prefs.setString(_membershipStatusKey, 'free');
    await _prefs.remove(_membershipPlanKey);
    await _prefs.remove(_membershipExpiryKey);
    status.value = 'free';
    plan.value = '';
    expiryDate.value = null;
    print('⚠️ Membership expired');
  }

  String? get purchaseDateFormatted {
    final ms = _prefs.getInt(_membershipPurchaseDateKey);
    if (ms == null) return null;
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day}/${d.month}/${d.year}';
  }

  /// Syncs membership from server on app open.
  /// Only hits the API if no active plan is stored locally.
  /// Call this from the main listing screen (ChatListController) in the background.
  Future<void> syncMembershipFromServer(String deviceId) async {
    // Skip if already active locally
    if (isPremium) {
      debugPrint(
          '📋 Membership sync skipped - active plan already in local storage');
      return;
    }

    try {
      debugPrint('🔄 Syncing membership from server for device: $deviceId');

      final uri =
          Uri.parse('https://vant.chat/api/membership/sync-status/$deviceId');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('⚠️ Membership sync failed: HTTP ${response.statusCode}');
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['hasActivePlan'] != true) {
        debugPrint('📋 No active plan found on server');
        return;
      }

      final planId = data['planId'] as String? ?? '6_months';
      final purchaseId = data['purchaseId'] as String? ?? 'server_sync';
      final purchaseDateStr = data['purchaseDate'] as String?;
      final expiryDateStr = data['expiryDate'] as String?;

      // Use server expiry date if available, otherwise calculate from purchase date
      if (expiryDateStr != null) {
        final expiry = DateTime.parse(expiryDateStr);
        if (DateTime.now().isBefore(expiry)) {
          await _prefs.setString(_membershipStatusKey, 'premium');
          await _prefs.setString(_membershipPlanKey, planId);
          await _prefs.setInt(
              _membershipExpiryKey, expiry.millisecondsSinceEpoch);
          await _prefs.setString('purchase_id', purchaseId);

          if (purchaseDateStr != null) {
            final purchaseDate = DateTime.parse(purchaseDateStr);
            await _prefs.setInt(_membershipPurchaseDateKey,
                purchaseDate.millisecondsSinceEpoch);
          }

          status.value = 'premium';
          plan.value = planId;
          expiryDate.value = expiry;

          debugPrint(
              '✅ Membership restored from server: $planId, expires: $expiry');
        } else {
          debugPrint('⚠️ Server plan is expired, not restoring');
        }
      } else if (purchaseDateStr != null) {
        final purchaseDate = DateTime.parse(purchaseDateStr);
        await restoreMembership(
          purchaseId: purchaseId,
          selectedPlan: planId,
          purchaseDate: purchaseDate,
        );
      }
    } catch (e) {
      debugPrint('⚠️ Membership sync error: $e');
    }
  }
}
