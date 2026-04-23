import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'dart:io' show Platform;

class IAPService extends GetxService {
  final InAppPurchase _iap = InAppPurchase.instance;

  // Platform-specific Product IDs
  static const String _sixMonthProductIdIOS = 'com.vantchat.premium.6months.v2';
  static const String _oneYearProductIdIOS = 'com.vantchat.premium.1year.v3';
  static const String _sixMonthProductIdAndroid =
      'com.vantchat.premium.6months';
  static const String _oneYearProductIdAndroid = 'com.vantchat.premium.1year';

  // Using standard products with regional pricing templates (much simpler!)
  // No separate premium products needed - Google Play handles regional pricing

  // EU countries that use premium pricing on Android only
  static const Set<String> _premiumPricingCountries = {
    'AL', // Albania (covers Kosovo users too)
    'IT', // Italy
    'GR', // Greece
    'RS', // Serbia (covers Montenegro users)
  };

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

  // Get regional product IDs - now just returns standard products
  // Google Play pricing templates will handle regional pricing automatically
  static String getRegionalSixMonthProductId(String countryCode,
      {String? languageCode}) {
    return defaultTargetPlatform == TargetPlatform.iOS
        ? _sixMonthProductIdIOS
        : _sixMonthProductIdAndroid;
  }

  static String getRegionalOneYearProductId(String countryCode,
      {String? languageCode}) {
    return defaultTargetPlatform == TargetPlatform.iOS
        ? _oneYearProductIdIOS
        : _oneYearProductIdAndroid;
  }

  // Check if country uses premium pricing
  static bool isPremiumPricingCountry(String countryCode) {
    return _premiumPricingCountries.contains(countryCode.toUpperCase());
  }

  // Check if language indicates premium pricing (for users in unsupported countries)
  static bool isPremiumPricingLanguage(String languageCode) {
    final premiumLanguages = {
      'sq', // Albanian (Albania & Kosovo)
      'it', // Italian (Italy)
      'el', // Greek (Greece)
      'sr', // Serbian (Serbia & Montenegro)
    };
    return premiumLanguages.contains(languageCode.toLowerCase());
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
  final RxString userCountryCode = ''.obs; // Store user's country code

  StreamSubscription<List<PurchaseDetails>>? _subscription;

  // Get user's country code (only needed for Android premium pricing)
  Future<String> getUserCountryCode() async {
    if (userCountryCode.value.isNotEmpty) {
      return userCountryCode.value;
    }

    // For iOS, we don't need country detection since no premium pricing
    if (Platform.isIOS) {
      userCountryCode.value = 'US';
      debugPrint(
          '🌍 iOS detected - using default country (no premium pricing needed)');
      return userCountryCode.value;
    }

    try {
      // For Android, try to get country for premium pricing
      if (Platform.isAndroid) {
        // Method 1: Try to get from Play Store account locale
        final storeCountry = await _getPlayStoreCountry();
        if (storeCountry.isNotEmpty) {
          userCountryCode.value = storeCountry;
          debugPrint('🌍 Country from Play Store: $storeCountry');
          return storeCountry;
        }

        // Method 2: Fallback to device locale
        final localeCountry = await _getDeviceLocaleCountry();
        if (localeCountry.isNotEmpty) {
          userCountryCode.value = localeCountry;
          debugPrint('🌍 Country from device locale: $localeCountry');
          return localeCountry;
        }
      }

      // Method 3: Final fallback
      userCountryCode.value = 'US';
      debugPrint('🌍 Using default country: US');
    } catch (e) {
      debugPrint('⚠️ Error detecting country: $e');
      userCountryCode.value = 'US'; // Default fallback
    }

    return userCountryCode.value;
  }

  // Get country from Play Store (Android)
  Future<String> _getPlayStoreCountry() async {
    try {
      // Try to get from Google Play billing API
      // This will return the country code of the user's Play Store account
      final response = await _iap.queryProductDetails({'test'});
      if (response.notFoundIDs.isNotEmpty) {
        // If we can reach Play Store, assume user is in a supported region
        // This is a basic check - you might need to implement more sophisticated detection
        return 'US'; // Default to US for now
      }
    } catch (e) {
      debugPrint('⚠️ Could not get Play Store country: $e');
    }
    return '';
  }

  // Get country from device locale (fallback method)
  Future<String> _getDeviceLocaleCountry() async {
    try {
      String locale = '';
      String languageCode = '';

      if (Platform.isAndroid) {
        // Use system locale for Android since AndroidDeviceInfo doesn't have locale property
        try {
          final systemLocale =
              WidgetsBinding.instance.platformDispatcher.locale;
          locale = systemLocale.toString();
          languageCode = systemLocale.languageCode;
        } catch (e) {
          debugPrint('⚠️ Could not get Android system locale: $e');
          // Fallback to a default Android locale
          locale = 'en_US';
          languageCode = 'en';
        }
      } else if (Platform.isIOS) {
        // Use system locale for iOS since IosDeviceInfo doesn't have locale
        try {
          final systemLocale =
              WidgetsBinding.instance.platformDispatcher.locale;
          locale = systemLocale.toString();
          languageCode = systemLocale.languageCode;
        } catch (e) {
          debugPrint('⚠️ Could not get iOS system locale: $e');
          // Fallback to a default iOS locale
          locale = 'en_US';
          languageCode = 'en';
        }
      }

      debugPrint('🌍 Device locale: $locale, language: $languageCode');

      // Try to extract country code from locale
      if (locale.contains('_')) {
        final parts = locale.split('_');
        if (parts.length >= 2) {
          final countryCode = parts[1];
          // Validate it's a proper country code
          if (countryCode.length == 2 &&
              _premiumPricingCountries.contains(countryCode)) {
            return countryCode;
          }
        }
      }

      // Fallback to language code mapping
      if (languageCode.isNotEmpty) {
        // Map some language codes to our premium countries
        switch (languageCode.toLowerCase()) {
          case 'it':
            return 'IT'; // Italian -> Italy
          case 'el':
            return 'GR'; // Greek -> Greece
          case 'sq':
            return 'AL'; // Albanian -> Albania
          case 'sr':
            return 'ME'; // Serbian -> Montenegro (approximation)
          default:
            break;
        }
      }
    } catch (e) {
      debugPrint('⚠️ Error getting device locale country: $e');
    }
    return '';
  }

  // Get product IDs based on user's region
  Future<String> getSixMonthProductIdForUser() async {
    final countryCode = await getUserCountryCode();
    final languageCode = await _getUserLanguageCode();
    return getRegionalSixMonthProductId(countryCode,
        languageCode: languageCode);
  }

  Future<String> getOneYearProductIdForUser() async {
    final countryCode = await getUserCountryCode();
    final languageCode = await _getUserLanguageCode();
    return getRegionalOneYearProductId(countryCode, languageCode: languageCode);
  }

  // Get user's language code for fallback detection
  Future<String> _getUserLanguageCode() async {
    try {
      final systemLocale = WidgetsBinding.instance.platformDispatcher.locale;
      return systemLocale.languageCode;
    } catch (e) {
      debugPrint('⚠️ Error getting language code: $e');
      return 'en';
    }
  }

  // Check if user is in premium pricing country
  Future<bool> isUserInPremiumCountry() async {
    final countryCode = await getUserCountryCode();
    return isPremiumPricingCountry(countryCode);
  }

  // Get pricing info for display
  Future<Map<String, dynamic>> getPricingInfo() async {
    final countryCode = await getUserCountryCode();
    final languageCode = await _getUserLanguageCode();
    final isPremiumCountry = isPremiumPricingCountry(countryCode);
    final isPremiumLanguage = isPremiumPricingLanguage(languageCode);
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final hasPremiumPricing =
        isAndroid && (isPremiumCountry || isPremiumLanguage);

    return {
      'countryCode': countryCode,
      'languageCode': languageCode,
      'isPremiumCountry': isPremiumCountry,
      'isPremiumLanguage': isPremiumLanguage,
      'isAndroid': isAndroid,
      'hasPremiumPricing': hasPremiumPricing,
      'sixMonthPrice': hasPremiumPricing ? '€600' : 'Standard Price',
      'oneYearPrice': hasPremiumPricing ? '€800' : 'Standard Price',
      'currency': hasPremiumPricing ? 'EUR' : 'Local',
      'platform': isAndroid ? 'Android' : 'iOS',
      'coverage': 'AL, IT, GR, RS + language detection for ME, XK',
    };
  }

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
