import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:get/get.dart';
import 'api_service.dart';
import '../constants/security_constants.dart';

class StripeService extends GetxService {
  static const String _stripePublishableKey =
      SecurityConstants.stripePublishableKey;

  final RxBool isAvailable = false.obs;
  final RxBool isLoading = false.obs;

  Future<StripeService> init() async {
    try {
      Stripe.publishableKey = _stripePublishableKey;
      isAvailable.value = true;
      debugPrint('✅ Stripe Service initialized');
    } catch (e) {
      debugPrint('❌ Failed to initialize Stripe Service: $e');
      isAvailable.value = false;
    }
    return this;
  }

  /// Create a payment intent on the backend
  Future<Map<String, dynamic>> createPaymentIntent({
    required String deviceId,
    required String planId,
    required int amount,
    required String currency,
  }) async {
    try {
      isLoading.value = true;
      final data = await ApiService.to.createStripeIntent(
          deviceId: deviceId,
          planId: planId,
          amount: amount,
          currency: currency);
      debugPrint('✅ Payment intent created: ${data['paymentIntentId']}');
      return data;
    } catch (e) {
      debugPrint('❌ Error creating payment intent: $e');
      rethrow;
    } finally {
      isLoading.value = false;
    }
  }

  /// Confirm payment using Stripe payment sheet
  Future<bool> confirmPayment({
    required String clientSecret,
    required String paymentIntentId,
  }) async {
    try {
      isLoading.value = true;

      // Present payment sheet
      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: SetupPaymentSheetParameters(
          paymentIntentClientSecret: clientSecret,
          merchantDisplayName: 'Vant Chat',
          allowsDelayedPaymentMethods: true,
          style: ThemeMode.dark,
        ),
      );

      // Confirm payment
      await Stripe.instance.presentPaymentSheet();

      debugPrint('✅ Payment confirmed: $paymentIntentId');
      return true;
    } catch (e) {
      debugPrint('❌ Payment confirmation failed: $e');
      rethrow;
    } finally {
      isLoading.value = false;
    }
  }

  /// Record successful purchase to backend
  Future<bool> recordPurchase({
    required String deviceId,
    required String planId,
    required int amount,
    required String currency,
    required String paymentIntentId,
    required String countryCode,
    String? cardCountry,
  }) async {
    try {
      final data = await ApiService.to.recordStripePurchase(
        deviceId: deviceId,
        planId: planId,
        amount: amount,
        currency: currency,
        paymentIntentId: paymentIntentId,
        countryCode: countryCode,
        cardCountry: cardCountry,
      );
      debugPrint('✅ Purchase recorded: ${data['success']}');
      return data['success'] ?? false;
    } catch (e) {
      debugPrint('❌ Error recording purchase: $e');
      rethrow;
    }
  }

  /// Complete Stripe purchase flow
  Future<bool> purchase({
    required String deviceId,
    required String planId,
    required int amount,
    required String currency,
    required String countryCode,
  }) async {
    try {
      // Step 1: Create payment intent
      final paymentIntent = await createPaymentIntent(
        deviceId: deviceId,
        planId: planId,
        amount: amount,
        currency: currency,
      );

      // Step 2: Confirm payment
      final confirmed = await confirmPayment(
        clientSecret: paymentIntent['clientSecret'],
        paymentIntentId: paymentIntent['paymentIntentId'],
      );

      if (!confirmed) {
        return false;
      }

      // Step 3: Record purchase to backend
      await recordPurchase(
        deviceId: deviceId,
        planId: planId,
        amount: amount,
        currency: currency,
        paymentIntentId: paymentIntent['paymentIntentId'],
        countryCode: countryCode,
      );

      return true;
    } catch (e) {
      debugPrint('❌ Stripe purchase failed: $e');
      rethrow;
    }
  }
}
