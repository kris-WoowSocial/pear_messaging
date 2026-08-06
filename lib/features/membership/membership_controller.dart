import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import '../../core/constants/pricing_config.dart';
import '../../core/services/api_service.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/services/membership_service.dart';
import '../../core/services/iap_service.dart';

class MembershipController extends GetxController {
  static MembershipController get to => Get.find();

  final RxString selectedPlan = ''.obs;
  final RxBool isProcessing = false.obs;
  final RxBool isRestoring = false.obs;
  final RxBool termsAccepted = false.obs;
  late MembershipService _membershipService;
  late IAPService _iapService;

  @override
  void onInit() {
    super.onInit();
    _membershipService = Get.find<MembershipService>();
    _iapService = Get.find<IAPService>();
    _setupIAPCallbacks();
  }

  void _setupIAPCallbacks() {
    _iapService.onPurchaseSuccess = _handlePurchaseSuccess;
    _iapService.onPurchaseError = _handlePurchaseError;
    _iapService.onPurchaseCanceled = _handlePurchaseCanceled;
  }

  bool get isPremium => _membershipService.isPremium;
  String get statusLabel => _membershipService.statusLabel;
  String get statusDescription => _membershipService.statusDescription;
  bool get isIAPAvailable => _iapService.isAvailable.value;
  List<ProductDetails> get products => _iapService.products;

  Future<void> purchasePlan(String planId) async {
    if (isProcessing.value) return;

    if (!termsAccepted.value) {
      Get.snackbar(
        'Terms Required',
        'Please accept the terms and conditions to continue.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.orange.shade100,
        colorText: Colors.orange.shade800,
      );
      return;
    }

    selectedPlan.value = planId;
    isProcessing.value = true;

    try {
      // All digital purchases must go through the platform's in-app purchase system.
      // Google Play and the App Store both handle card payments via their billing systems.
      await _purchaseWithIAP(planId);
    } catch (e) {
      print('❌ Purchase failed: $e');
      Get.snackbar(
        'Purchase Failed',
        _getUserFriendlyErrorMessage(e),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
    } finally {
      isProcessing.value = false;
      selectedPlan.value = '';
    }
  }

  Future<void> _purchaseWithIAP(String planId) async {
    if (!_iapService.isAvailable.value) {
      Get.snackbar(
        'Not Available',
        'In-app purchases are not available on this device.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
      return;
    }

    final productId = _iapService.getProductIdFromPlanId(planId);
    debugPrint(
      '🛒 Initiating IAP purchase for plan: $planId, productId: $productId',
    );
    await _iapService.purchaseProduct(productId);
  }

  void _handlePurchaseSuccess(PurchaseDetails purchaseDetails) async {
    debugPrint(
      '✅ Purchase successful in controller: ${purchaseDetails.productID}',
    );

    final planId = _iapService.getPlanIdFromProductId(
      purchaseDetails.productID,
    );
    final planLabel = planId == '1_year' ? '1-Year Plan' : '6-Month Plan';
    final purchaseId = purchaseDetails.purchaseID ??
        purchaseDetails.transactionDate ??
        'unknown';

    await _membershipService.activateMembership(
      selectedPlan: planId,
      purchaseId: purchaseId,
    );

    // Report the verified purchase to the backend so referral commission is
    // credited to the influencer/inviter chain, if any. This must happen for
    // every real purchase - do it in the background so a network hiccup
    // doesn't block the premium unlock the user already got locally.
    _reportPurchaseForCommission(planId: planId, purchaseId: purchaseId);

    isProcessing.value = false;
    selectedPlan.value = '';

    Get.back();

    Get.snackbar(
      '🎉 Welcome to Premium!',
      '$planLabel activated successfully. Enjoy unlimited media sharing!',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.green.shade100,
      colorText: Colors.green.shade800,
      duration: const Duration(seconds: 4),
    );
  }

  Future<void> _reportPurchaseForCommission({
    required String planId,
    required String purchaseId,
  }) async {
    try {
      final deviceId = Get.find<LocalStorageService>().deviceId;
      if (deviceId == null || deviceId.isEmpty) return;

      final pricing = PricingConfig.globalPricing;
      final countryCode = await _iapService.getUserCountryCode();

      await ApiService.to.recordIAPPurchase(
        deviceId: deviceId,
        planId: planId,
        amountCents: pricing.getPriceForPlan(planId),
        currency: pricing.currency,
        purchaseId: purchaseId,
        countryCode: countryCode,
        platform: Platform.isIOS ? 'ios' : 'android',
      );
      debugPrint('✅ Purchase reported to backend for referral commission');
    } catch (e) {
      // Non-fatal: the user already has premium locally. Log for follow-up.
      debugPrint('⚠️ Failed to report purchase to backend: $e');
    }
  }

  void _handlePurchaseError(String error) {
    debugPrint('❌ Purchase error in controller: $error');
    isProcessing.value = false;
    selectedPlan.value = '';

    Get.snackbar(
      'Purchase Failed',
      _getUserFriendlyErrorMessage(error),
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.red.shade100,
      colorText: Colors.red.shade800,
    );
  }

  String _getUserFriendlyErrorMessage(dynamic error) {
    final errorString = error.toString();

    if (errorString.contains('canceled') || errorString.contains('Canceled')) {
      return 'Payment was canceled. Please try again.';
    }
    if (errorString.contains('network') || errorString.contains('Network')) {
      return 'Network error. Please check your connection and try again.';
    }
    // Default generic message
    return 'An error occurred during purchase. Please try again.';
  }

  void _handlePurchaseCanceled() {
    debugPrint('🚫 Purchase canceled in controller');
    isProcessing.value = false;
    selectedPlan.value = '';
  }

  Future<void> restorePurchases() async {
    if (isRestoring.value) return;

    if (!_iapService.isAvailable.value) {
      Get.snackbar(
        'Not Available',
        'In-app purchases are not available on this device.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
      return;
    }

    isRestoring.value = true;

    try {
      await _iapService.restorePurchases();

      // Wait a bit for the purchase stream to process
      await Future.delayed(const Duration(seconds: 2));

      isRestoring.value = false;

      if (_membershipService.isPremium) {
        Get.snackbar(
          '✅ Restored',
          'Your premium membership has been restored!',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.green.shade100,
          colorText: Colors.green.shade800,
        );
      } else {
        Get.snackbar(
          'No Purchases Found',
          'No active premium membership found to restore.',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.orange.shade100,
          colorText: Colors.orange.shade800,
        );
      }
    } catch (e) {
      isRestoring.value = false;
      debugPrint('❌ Restore error: $e');
      Get.snackbar(
        'Restore Failed',
        'Unable to restore purchases. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
    }
  }

  @override
  void onClose() {
    _iapService.onPurchaseSuccess = null;
    _iapService.onPurchaseError = null;
    _iapService.onPurchaseCanceled = null;
    super.onClose();
  }
}
