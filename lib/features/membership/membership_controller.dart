import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import '../../core/services/membership_service.dart';
import '../../core/services/iap_service.dart';
import '../../core/services/stripe_service.dart';
import '../../core/services/crypto_service.dart';
import '../../core/services/region_service.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/constants/pricing_config.dart';
import 'screens/crypto_payment_screen.dart';

class MembershipController extends GetxController {
  static MembershipController get to => Get.find();

  final RxString selectedPlan = ''.obs;
  final RxBool isProcessing = false.obs;
  final RxBool isRestoring = false.obs;
  final RxBool termsAccepted = false.obs;
  final RxString selectedPaymentMethod =
      ''.obs; // 'stripe', 'google_play', 'crypto'

  late MembershipService _membershipService;
  late IAPService _iapService;
  late StripeService _stripeService;
  late CryptoService _cryptoService;
  late RegionService _regionService;

  @override
  void onInit() {
    super.onInit();
    _membershipService = Get.find<MembershipService>();
    _iapService = Get.find<IAPService>();
    _stripeService = Get.find<StripeService>();
    _cryptoService = Get.find<CryptoService>();
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
      // Use the selected payment method
      if (selectedPaymentMethod.value == 'crypto') {
        await _purchaseWithCrypto(planId);
      } else {
        // Always use Stripe with global pricing
        final pricing = PricingConfig.globalPricing;
        final amount = pricing.getPriceForPlan(planId);
        final currency = pricing.currency;
        await _purchaseWithStripe(planId, amount, currency);
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

  Future<void> _purchaseWithCrypto(String planId) async {
    if (!_cryptoService.isAvailable.value) {
      Get.snackbar(
        'Not Available',
        'Crypto payment is not available.',
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

    debugPrint('🛒 Initiating crypto purchase for plan: $planId');

    try {
      final addressInfo = await _cryptoService.generateAddress(
        deviceId: deviceId,
        planId: planId,
        countryCode: _regionService.countryCode,
        coin: _cryptoService.selectedCoin.value,
      );

      // Start polling for payment confirmation
      _cryptoService.startPolling(
        deviceId,
        coin: _cryptoService.selectedCoin.value,
      );

      // Navigate to crypto payment screen
      _showCryptoPaymentScreen(addressInfo, deviceId, planId);
    } catch (e) {
      debugPrint('❌ Crypto purchase failed: $e');
      rethrow;
    }
  }

  void _showCryptoPaymentScreen(
    Map<String, dynamic> addressInfo,
    String deviceId,
    String planId,
  ) {
    Get.to(
      () => CryptoPaymentScreen(
        address: addressInfo['address'],
        amount:
            ((addressInfo['amount'] ??
                        addressInfo['amountUSDT'] ??
                        addressInfo['amountBTC'] ??
                        addressInfo['amountETH'] ??
                        0)
                    as num)
                .toDouble(),
        currency:
            addressInfo['currency'] ?? _cryptoService.selectedCoin.value.symbol,
        coin: _cryptoService.selectedCoin.value,
        expiry: addressInfo['expiry'],
        onPaymentConfirmed: () async {
          _cryptoService.stopPolling();
          await _handleCryptoPurchaseSuccess(planId);
        },
        onCancelled: () {
          _cryptoService.stopPolling();
        },
      ),
    );
  }

  Future<void> _handleCryptoPurchaseSuccess(String planId) async {
    debugPrint('✅ Crypto purchase successful');

    final purchaseId = _cryptoService.txHash.value.isNotEmpty
        ? _cryptoService.txHash.value
        : 'crypto_${DateTime.now().millisecondsSinceEpoch}';
    await _membershipService.activateMembership(
      selectedPlan: planId,
      purchaseId: purchaseId,
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
      '🛒 Initiating Google Play purchase for plan: $planId, productId: $productId',
    );
    await _iapService.purchaseProduct(productId);
  }

  Future<void> _purchaseWithStripe(
    String planId,
    int amount,
    String currency,
  ) async {
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
      '🛒 Initiating Stripe purchase for plan: $planId, amount: $amount, currency: $currency',
    );

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
      '✅ Purchase successful in controller: ${purchaseDetails.productID}',
    );

    final planId = _iapService.getPlanIdFromProductId(
      purchaseDetails.productID,
    );
    final planLabel = planId == '1_year' ? '1-Year Plan' : '6-Month Plan';

    // Record Google Play purchase to backend
    try {
      final storageService = Get.find<LocalStorageService>();
      final deviceId = storageService.deviceId;

      if (deviceId != null) {
        final pricing = PricingConfig.getPricingForRegion(
          _regionService.region,
        );
        final amount = pricing.getPriceForPlan(planId);

        // TODO: Call backend to record Google Play purchase
        // This requires extracting Play Store account region from purchase token
        debugPrint(
          '🛒 Recording Google Play purchase to backend: deviceId=$deviceId, planId=$planId, amount=$amount',
        );
      }
    } catch (e) {
      debugPrint('⚠️ Failed to record Google Play purchase to backend: $e');
    }

    await _membershipService.activateMembership(
      selectedPlan: planId,
      purchaseId:
          purchaseDetails.purchaseID ??
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
    if (errorString.contains('Crypto payment service unavailable')) {
      return 'Crypto payment is not available. Please try Stripe instead.';
    }
    if (errorString.contains('wallet not configured')) {
      return 'Crypto wallet not configured. Please try Stripe instead.';
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
    _cryptoService.stopPolling();
    super.onClose();
  }
}

// Crypto Payment Dialog Widget
class CryptoPaymentDialog extends StatefulWidget {
  final String address;
  final double amount;
  final String currency;
  final CryptoCoin coin;
  final String expiry;
  final VoidCallback onPaymentConfirmed;
  final VoidCallback onCancelled;

  const CryptoPaymentDialog({
    super.key,
    required this.address,
    required this.amount,
    required this.currency,
    required this.coin,
    required this.expiry,
    required this.onPaymentConfirmed,
    required this.onCancelled,
  });

  @override
  State<CryptoPaymentDialog> createState() => _CryptoPaymentDialogState();
}

class _CryptoPaymentDialogState extends State<CryptoPaymentDialog> {
  final CryptoService _cryptoService = Get.find<CryptoService>();
  Timer? _expiryTimer;
  String _timeRemaining = '';

  @override
  void initState() {
    super.initState();
    _updateTimeRemaining();
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _updateTimeRemaining();
    });

    // Listen to payment status
    ever(_cryptoService.paymentStatus, (status) {
      if ((status == 'confirmed' || status == 'active') && mounted) {
        widget.onPaymentConfirmed();
      }
    });
  }

  void _updateTimeRemaining() {
    final expiryTime = DateTime.parse(widget.expiry);
    final remaining = expiryTime.difference(DateTime.now());

    if (remaining.isNegative) {
      setState(() {
        _timeRemaining = 'Expired';
      });
      widget.onCancelled();
      return;
    }

    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;

    setState(() {
      _timeRemaining = '${minutes}m ${seconds}s';
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1A1A2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        padding: const EdgeInsets.all(24),
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Pay with ${widget.coin.label}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: widget.onCancelled,
                ),
              ],
            ),
            const SizedBox(height: 20),

            // QR Code
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Text(
                  'QR CODE\n(To be implemented)',
                  style: TextStyle(color: Colors.black54, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Amount
            Text(
              '${widget.amount.toStringAsFixed(widget.coin == CryptoCoin.btc ? 8 : 6)} ${widget.currency}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),

            // Address
            SelectableText(
              widget.address,
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),

            // Copy Address Button
            TextButton.icon(
              onPressed: () {
                // Copy address to clipboard
              },
              icon: const Icon(Icons.copy, color: Colors.white54, size: 16),
              label: Text(
                'Copy Address',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Status
            Obx(
              () => Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: _cryptoService.paymentStatus.value == 'pending'
                      ? Colors.orange.withOpacity(0.2)
                      : Colors.green.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _cryptoService.paymentStatus.value == 'pending'
                        ? Colors.orange
                        : Colors.green,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_cryptoService.paymentStatus.value == 'pending')
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.orange,
                        ),
                      )
                    else
                      const Icon(
                        Icons.check_circle,
                        color: Colors.green,
                        size: 20,
                      ),
                    const SizedBox(width: 12),
                    Text(
                      _cryptoService.paymentStatus.value == 'pending'
                          ? 'Waiting for payment...'
                          : 'Payment confirmed!',
                      style: TextStyle(
                        color: _cryptoService.paymentStatus.value == 'pending'
                            ? Colors.orange
                            : Colors.green,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Time Remaining
            Text(
              'Expires in $_timeRemaining',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),

            // Info
            Text(
              _cryptoService.getCoinInfo(widget.coin),
              style: TextStyle(
                color: Colors.white.withOpacity(0.4),
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
