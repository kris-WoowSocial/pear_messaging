import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import '../../core/services/membership_service.dart';
import '../../core/services/iap_service.dart';
import '../../core/services/stripe_service.dart';
import '../../core/services/region_service.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/constants/pricing_config.dart';

class MembershipController extends GetxController {
  static MembershipController get to => Get.find();

  final RxString selectedPlan = ''.obs;
  final RxBool isProcessing = false.obs;
  final RxBool isRestoring = false.obs;
  final RxBool termsAccepted = false.obs;

  late MembershipService _membershipService;
  late IAPService _iapService;
  late StripeService _stripeService;
  late RegionService _regionService;

  @override
  void onInit() {
    super.onInit();
    _membershipService = Get.find<MembershipService>();
    _iapService = Get.find<IAPService>();
    _stripeService = Get.find<StripeService>();
    _regionService = Get.find<RegionService>();
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
      // Determine payment method based on user's country
      final paymentMethod = _regionService.getPaymentMethod();

      // Get pricing for the region
      final region =
          paymentMethod == 'stripe' ? 'HighPrice' : _regionService.region;
      final pricing = PricingConfig.getPricingForRegion(region);
      final amount = pricing.getPriceForPlan(planId);
      final currency = pricing.currency;

      if (paymentMethod == 'stripe') {
        // Use Stripe for high-price countries
        await _purchaseWithStripe(planId, amount, currency);
      } else {
        // Use Google Play for low-price countries
        await _purchaseWithGooglePlay(planId);
      }
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

  Future<void> _purchaseWithGooglePlay(String planId) async {
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
        '🛒 Initiating Google Play purchase for plan: $planId, productId: $productId');
    await _iapService.purchaseProduct(productId);
  }

  Future<void> _purchaseWithStripe(
      String planId, int amount, String currency) async {
    if (!_stripeService.isAvailable.value) {
      Get.snackbar(
        'Not Available',
        'Stripe payment is not available.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
      return;
    }

    // Get device ID from storage service
    final storageService = Get.find<LocalStorageService>();
    final deviceId = storageService.deviceId;

    if (deviceId == null) {
      throw Exception('Device ID not available');
    }

    debugPrint(
        '🛒 Initiating Stripe purchase for plan: $planId, amount: $amount, currency: $currency');

    final success = await _stripeService.purchase(
      deviceId: deviceId,
      planId: planId,
      amount: amount,
      currency: currency.toLowerCase(),
      countryCode: _regionService.countryCode,
    );

    if (success) {
      await _handleStripePurchaseSuccess(planId);
    }
  }

  Future<void> _handleStripePurchaseSuccess(String planId) async {
    debugPrint('✅ Stripe purchase successful for plan: $planId');

    await _membershipService.activateMembership(
      selectedPlan: planId,
      purchaseId: 'stripe_${DateTime.now().millisecondsSinceEpoch}',
    );

    Get.back();

    final planLabel = planId == '1_year' ? '1-Year Plan' : '6-Month Plan';
    Get.snackbar(
      '🎉 Welcome to Premium!',
      '$planLabel activated successfully. Enjoy unlimited media sharing!',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.green.shade100,
      colorText: Colors.green.shade800,
      duration: const Duration(seconds: 4),
    );
  }

  void _handlePurchaseSuccess(PurchaseDetails purchaseDetails) async {
    debugPrint(
        '✅ Purchase successful in controller: ${purchaseDetails.productID}');

    final planId =
        _iapService.getPlanIdFromProductId(purchaseDetails.productID);
    final planLabel = planId == '1_year' ? '1-Year Plan' : '6-Month Plan';

    // Record Google Play purchase to backend
    try {
      final storageService = Get.find<LocalStorageService>();
      final deviceId = storageService.deviceId;

      if (deviceId != null) {
        final pricing =
            PricingConfig.getPricingForRegion(_regionService.region);
        final amount = pricing.getPriceForPlan(planId);

        // TODO: Call backend to record Google Play purchase
        // This requires extracting Play Store account region from purchase token
        debugPrint(
            '🛒 Recording Google Play purchase to backend: deviceId=$deviceId, planId=$planId, amount=$amount');
      }
    } catch (e) {
      debugPrint('⚠️ Failed to record Google Play purchase to backend: $e');
    }

    await _membershipService.activateMembership(
      selectedPlan: planId,
      purchaseId: purchaseDetails.purchaseID ??
          purchaseDetails.transactionDate ??
          'unknown',
    );

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
    if (errorString.contains('Stripe is not configured')) {
      return 'Payment service is temporarily unavailable. Please try again later.';
    }
    if (errorString.contains('Payment service unavailable')) {
      return 'Payment service is temporarily unavailable. Please try again later.';
    }
    if (errorString.contains('Failed to create payment intent')) {
      return 'Unable to process payment. Please try again.';
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
