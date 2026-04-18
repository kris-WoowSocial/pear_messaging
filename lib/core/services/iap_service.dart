import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

class IAPService extends GetxService {
  final InAppPurchase _iap = InAppPurchase.instance;

  // Platform-specific Product IDs
  static const String _sixMonthProductIdIOS = 'com.vantchat.premium.6months.v2';
  static const String _oneYearProductIdIOS = 'com.vantchat.premium.1year.v3';
  static const String _sixMonthProductIdAndroid =
      'com.vantchat.premium.6months';
  static const String _oneYearProductIdAndroid = 'com.vantchat.premium.1year';

  // Get platform-specific product IDs
  static String get sixMonthProductId {
    return defaultTargetPlatform == TargetPlatform.iOS
        ? _sixMonthProductIdIOS
        : _sixMonthProductIdAndroid;
  }

  static String get oneYearProductId {
    return defaultTargetPlatform == TargetPlatform.iOS
        ? _oneYearProductIdIOS
        : _oneYearProductIdAndroid;
  }

  static Set<String> get _productIds {
    return {
      sixMonthProductId,
      oneYearProductId,
    };
  }

  // Observables
  final RxBool isAvailable = false.obs;
  final RxList<ProductDetails> products = <ProductDetails>[].obs;
  final RxBool isLoading = false.obs;

  StreamSubscription<List<PurchaseDetails>>? _subscription;

  // Callbacks
  Function(PurchaseDetails)? onPurchaseSuccess;
  Function(String)? onPurchaseError;
  Function()? onPurchaseCanceled;

  Future<IAPService> init() async {
    debugPrint('🛒 Initializing IAP Service...');

    // Check if IAP is available
    isAvailable.value = await _iap.isAvailable();

    if (!isAvailable.value) {
      debugPrint('❌ IAP not available on this device');
      return this;
    }

    debugPrint('✅ IAP is available');

    // Listen to purchase updates
    _subscription = _iap.purchaseStream.listen(
      _handlePurchaseUpdate,
      onDone: () => debugPrint('🛒 Purchase stream closed'),
      onError: (error) => debugPrint('❌ Purchase stream error: $error'),
    );

    // Load products
    await fetchProducts();

    debugPrint('✅ IAP Service initialized');
    return this;
  }

  Future<void> fetchProducts() async {
    if (!isAvailable.value) {
      debugPrint('⚠️ Cannot fetch products - IAP not available');
      return;
    }

    isLoading.value = true;

    try {
      final ProductDetailsResponse response =
          await _iap.queryProductDetails(_productIds);

      if (response.error != null) {
        debugPrint('❌ Error fetching products: ${response.error}');
        isLoading.value = false;
        return;
      }

      if (response.productDetails.isEmpty) {
        debugPrint(
            '⚠️ No products found. Make sure products are created in App Store Connect / Play Console');
      } else {
        products.value = response.productDetails;
        debugPrint('✅ Loaded ${products.length} products:');
        for (var product in products) {
          debugPrint('   - ${product.id}: ${product.title} (${product.price})');
        }
      }

      // Check for invalid product IDs
      if (response.notFoundIDs.isNotEmpty) {
        debugPrint('⚠️ Products not found: ${response.notFoundIDs}');
      }
    } catch (e) {
      debugPrint('❌ Exception fetching products: $e');
    } finally {
      isLoading.value = false;
    }
  }

  ProductDetails? getProduct(String productId) {
    try {
      return products.firstWhere((p) => p.id == productId);
    } catch (e) {
      debugPrint('⚠️ Product not found: $productId');
      return null;
    }
  }

  Future<void> purchaseProduct(String productId) async {
    if (!isAvailable.value) {
      onPurchaseError
          ?.call('In-app purchases are not available on this device');
      return;
    }

    final product = getProduct(productId);
    if (product == null) {
      onPurchaseError?.call('Product not found. Please try again later.');
      return;
    }

    debugPrint('🛒 Initiating purchase for: ${product.id}');

    final PurchaseParam purchaseParam = PurchaseParam(
      productDetails: product,
    );

    try {
      final bool success =
          await _iap.buyNonConsumable(purchaseParam: purchaseParam);

      if (!success) {
        debugPrint('❌ Purchase initiation failed');
        onPurchaseError?.call('Failed to initiate purchase');
      }
    } catch (e) {
      debugPrint('❌ Purchase error: $e');
      onPurchaseError?.call('Purchase failed: $e');
    }
  }

  Future<void> restorePurchases() async {
    if (!isAvailable.value) {
      onPurchaseError
          ?.call('In-app purchases are not available on this device');
      return;
    }

    debugPrint('🔄 Restoring purchases...');

    try {
      await _iap.restorePurchases();
      debugPrint('✅ Restore purchases initiated');
    } catch (e) {
      debugPrint('❌ Restore purchases error: $e');
      onPurchaseError?.call('Failed to restore purchases: $e');
    }
  }

  void _handlePurchaseUpdate(List<PurchaseDetails> purchaseDetailsList) {
    for (final PurchaseDetails purchaseDetails in purchaseDetailsList) {
      debugPrint(
          '🛒 Purchase update: ${purchaseDetails.productID} - ${purchaseDetails.status}');

      if (purchaseDetails.status == PurchaseStatus.pending) {
        debugPrint('⏳ Purchase pending...');
      } else if (purchaseDetails.status == PurchaseStatus.error) {
        debugPrint('❌ Purchase error: ${purchaseDetails.error}');
        onPurchaseError
            ?.call(purchaseDetails.error?.message ?? 'Purchase failed');
        _completePurchase(purchaseDetails);
      } else if (purchaseDetails.status == PurchaseStatus.canceled) {
        debugPrint('🚫 Purchase canceled by user');
        onPurchaseCanceled?.call();
        _completePurchase(purchaseDetails);
      } else if (purchaseDetails.status == PurchaseStatus.purchased ||
          purchaseDetails.status == PurchaseStatus.restored) {
        debugPrint('✅ Purchase successful: ${purchaseDetails.productID}');

        // Verify purchase (local verification - just check it exists)
        final bool valid = _verifyPurchase(purchaseDetails);

        if (valid) {
          onPurchaseSuccess?.call(purchaseDetails);
        } else {
          debugPrint('❌ Purchase verification failed');
          onPurchaseError?.call('Purchase verification failed');
        }

        _completePurchase(purchaseDetails);
      }
    }
  }

  bool _verifyPurchase(PurchaseDetails purchaseDetails) {
    // Local verification - just check that we have a transaction ID
    // For production, you might want to verify with your backend
    if (purchaseDetails.verificationData.localVerificationData.isEmpty) {
      return false;
    }

    if (purchaseDetails.verificationData.serverVerificationData.isEmpty) {
      return false;
    }

    return true;
  }

  Future<void> _completePurchase(PurchaseDetails purchaseDetails) async {
    if (purchaseDetails.pendingCompletePurchase) {
      await _iap.completePurchase(purchaseDetails);
      debugPrint('✅ Purchase completed: ${purchaseDetails.productID}');
    }
  }

  String getPlanIdFromProductId(String productId) {
    if (productId == _sixMonthProductIdIOS ||
        productId == _sixMonthProductIdAndroid) {
      return '6_months';
    } else if (productId == _oneYearProductIdIOS ||
        productId == _oneYearProductIdAndroid) {
      return '1_year';
    }
    return '';
  }

  String getProductIdFromPlanId(String planId) {
    if (planId == '6_months') {
      return sixMonthProductId;
    } else if (planId == '1_year') {
      return oneYearProductId;
    }
    return '';
  }

  @override
  void onClose() {
    _subscription?.cancel();
    super.onClose();
  }
}
