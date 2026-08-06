import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:get/get.dart';

import 'api_service.dart';
import '../services/local_storage_service.dart';

/// New, additive Stripe subscription flow: a single Payment Sheet that
/// collects Card, Apple Pay, and Google Pay for the app's real 6-month or
/// 1-year plan (same plans/prices as PricingConfig), with a 7-day free trial
/// before the first charge. Does not touch/replace the existing IAPService
/// flow.
class StripeSubscriptionService extends GetxService {
  static StripeSubscriptionService get to => Get.find();

  bool _initialized = false;

  Future<StripeSubscriptionService> init() async {
    if (!_initialized) {
      // The publishable key can be overridden at build time with
      // --dart-define=STRIPE_PUBLISHABLE_KEY=pk_..., but defaults to the
      // real key below so it works out of the box (publishable keys are
      // safe to ship in client apps - unlike the secret key).
      final publishableKey = const String.fromEnvironment(
        'STRIPE_PUBLISHABLE_KEY',
        defaultValue:
            'pk_live_51TOkyVIC9vv7zpPxQHj0TE6JA9qRW0RlLQBR0gLsLJqxVwWSObl0uwbTIRzwemrTvgNY8y2mMPhdEB93HIERXhzg00lr6lYUqD',
      );

      if (publishableKey.isNotEmpty) {
        Stripe.publishableKey = publishableKey;
        if (Platform.isIOS) {
          // Set to your real Apple Pay merchant identifier before enabling
          // Apple Pay in the Payment Sheet below.
          Stripe.merchantIdentifier = 'merchant.com.vantchat.pear';
        }
        try {
          await Stripe.instance.applySettings();
          _initialized = true;
        } catch (e) {
          debugPrint('⚠️ Stripe.applySettings failed: $e');
        }
      } else {
        debugPrint(
            'ℹ️ STRIPE_PUBLISHABLE_KEY not set - Stripe subscription flow disabled');
      }
    }
    return this;
  }

  bool get isAvailable => _initialized;

  String get _deviceId =>
      Get.find<LocalStorageService>().deviceId ?? '';

  /// Creates the subscription on the backend for [planId] ('6_months' or
  /// '1_year' - matching the app's real plans/prices), presents the unified
  /// Payment Sheet (Card + Apple Pay + Google Pay), and confirms it once the
  /// user completes the sheet. Returns a [StripeSubscriptionResult].
  Future<StripeSubscriptionResult> startTrialSubscription(
      String planId) async {
    if (!isAvailable) {
      return StripeSubscriptionResult.error(
          'Stripe payments are not configured on this build.');
    }

    final deviceId = _deviceId;
    if (deviceId.isEmpty) {
      return StripeSubscriptionResult.error('Missing device id.');
    }

    try {
      final setup =
          await ApiService.to.createStripeSubscription(deviceId, planId);

      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: SetupPaymentSheetParameters(
          merchantDisplayName: 'Vant Chat',
          customerId: setup['customerId'] as String?,
          customerEphemeralKeySecret: setup['ephemeralKey'] as String?,
          setupIntentClientSecret: setup['clientSecret'] as String?,
          allowsDelayedPaymentMethods: true,
          applePay: Platform.isIOS
              ? const PaymentSheetApplePay(merchantCountryCode: 'US')
              : null,
          googlePay: Platform.isAndroid
              ? const PaymentSheetGooglePay(
                  merchantCountryCode: 'US',
                  currencyCode: 'USD',
                  testEnv: false,
                )
              : null,
          style: ThemeMode.dark,
        ),
      );

      await Stripe.instance.presentPaymentSheet();

      final confirm = await ApiService.to
          .confirmStripeSubscription(deviceId, setup['subscriptionId'] as String);

      final status = confirm['status'] as String? ?? 'trialing';
      return StripeSubscriptionResult.success(
        status: status,
        isTrial: status == 'trialing',
        currentPeriodEnd: confirm['currentPeriodEnd'],
      );
    } on StripeException catch (e) {
      if (e.error.code == FailureCode.Canceled) {
        return StripeSubscriptionResult.cancelled();
      }
      return StripeSubscriptionResult.error(
          e.error.localizedMessage ?? e.error.message ?? 'Payment failed');
    } catch (e) {
      debugPrint('❌ Stripe subscription error: $e');
      return StripeSubscriptionResult.error(e.toString());
    }
  }

  Future<Map<String, dynamic>> getStatus() async {
    return ApiService.to.getStripeSubscriptionStatus(_deviceId);
  }

  Future<Map<String, dynamic>> cancel() async {
    return ApiService.to.cancelStripeSubscription(_deviceId);
  }
}

class StripeSubscriptionResult {
  final bool success;
  final bool cancelled;
  final bool isTrial;
  final String? status;
  final int? currentPeriodEnd;
  final String? error;

  StripeSubscriptionResult._({
    required this.success,
    this.cancelled = false,
    this.isTrial = false,
    this.status,
    this.currentPeriodEnd,
    this.error,
  });

  factory StripeSubscriptionResult.success({
    required String status,
    bool isTrial = false,
    dynamic currentPeriodEnd,
  }) =>
      StripeSubscriptionResult._(
        success: true,
        status: status,
        isTrial: isTrial,
        currentPeriodEnd: currentPeriodEnd is int ? currentPeriodEnd : null,
      );

  factory StripeSubscriptionResult.cancelled() =>
      StripeSubscriptionResult._(success: false, cancelled: true);

  factory StripeSubscriptionResult.error(String message) =>
      StripeSubscriptionResult._(success: false, error: message);
}
