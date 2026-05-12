import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class StripeService extends GetxService {
  static const String _stripePublishableKey =
      'pk_live_51TOkyVIC9vv7zpPxQHj0TE6JA9qRW0RlLQBR0gLsLJqxVwWSObl0uwbTIRzwemrTvgNY8y2mMPhdEB93HIERXhzg00lr6lYUqD';

  static const String _baseUrl = 'https://vant.chat/api/membership';

  final RxBool isAvailable = false.obs;
  final RxBool isLoading = false.obs;

  Future<StripeService> init() async {
    try {
      Stripe.publishableKey = _stripePublishableKey;
      isAvailable.value = true;
      print('✅ Stripe Service initialized');
    } catch (e) {
      print('❌ Failed to initialize Stripe Service: $e');
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

      final response = await http.post(
        Uri.parse('$_baseUrl/create-payment-intent'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceId': deviceId,
          'planId': planId,
          'amount': amount,
          'currency': currency,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('✅ Payment intent created: ${data['paymentIntentId']}');
        return data;
      } else {
        throw Exception('Failed to create payment intent: ${response.body}');
      }
    } catch (e) {
      print('❌ Error creating payment intent: $e');
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

      print('✅ Payment confirmed: $paymentIntentId');
      return true;
    } catch (e) {
      print('❌ Payment confirmation failed: $e');
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
      final response = await http.post(
        Uri.parse('$_baseUrl/record-stripe-purchase'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceId': deviceId,
          'planId': planId,
          'amount': amount,
          'currency': currency,
          'paymentIntentId': paymentIntentId,
          'countryCode': countryCode,
          'cardCountry': cardCountry,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('✅ Purchase recorded: ${data['success']}');
        return data['success'] ?? false;
      } else {
        throw Exception('Failed to record purchase: ${response.body}');
      }
    } catch (e) {
      print('❌ Error recording purchase: $e');
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
      print('❌ Stripe purchase failed: $e');
      rethrow;
    }
  }
}
