import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/network_constants.dart';
import '../../core/constants/pricing_config.dart';
import '../../core/services/api_service.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/services/membership_service.dart';
import '../../core/services/stripe_subscription_service.dart';

/// New, additive screen offering the app's real 2 plans (6 Months / 1 Year -
/// same [PricingConfig] plans/prices as [MembershipScreen]'s in_app_purchase
/// flow) through:
///  - A single unified Stripe Payment Sheet (Card + Apple Pay + Google Pay)
///    with a 7-day free trial, then auto-renewal at the plan's price.
///  - A separate one-time "Pay with Crypto" option (USDC via Stripe Checkout),
///    since Stripe's crypto payment method cannot be used inside a recurring
///    subscription/trial.
/// This does not replace the existing [MembershipScreen] (in_app_purchase
/// flow) - it is a new entry point.
class StripeSubscriptionScreen extends StatefulWidget {
  const StripeSubscriptionScreen({super.key});

  @override
  State<StripeSubscriptionScreen> createState() =>
      _StripeSubscriptionScreenState();
}

class _StripeSubscriptionScreenState extends State<StripeSubscriptionScreen> {
  String? _processingPlanId;
  bool _termsAccepted = false;

  @override
  Widget build(BuildContext context) {
    final stripeService = Get.find<StripeSubscriptionService>();
    final membershipService = Get.find<MembershipService>();
    final pricing = PricingConfig.globalPricing;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1A1A2E), Color(0xFF0A0A0F)],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Get.back(),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHeroSection(membershipService),
                        const SizedBox(height: 16),
                        _buildTermsCheckbox(),
                        const SizedBox(height: 16),
                        _buildPaymentMethodInfo(),
                        const SizedBox(height: 24),
                        const Text(
                          'Choose your plan',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _buildStripePlanButton(
                          stripeService,
                          planId: '6_months',
                          title: '6 Months',
                          price: pricing.sixMonthDisplay,
                          perMonth: _calculatePerMonth(
                            pricing.sixMonthPrice,
                            6,
                            pricing.currencySymbol,
                          ),
                          isPopular: false,
                        ),
                        const SizedBox(height: 12),
                        _buildStripePlanButton(
                          stripeService,
                          planId: '1_year',
                          title: '1 Year',
                          price: pricing.oneYearDisplay,
                          perMonth: _calculatePerMonth(
                            pricing.oneYearPrice,
                            12,
                            pricing.currencySymbol,
                          ),
                          isPopular: true,
                        ),
                        const SizedBox(height: 16),
                        _buildCryptoButton(),
                        const SizedBox(height: 20),
                        _buildFeaturesSection(),
                        const SizedBox(height: 16),
                        _buildSubscriptionInfo(pricing),
                        const SizedBox(height: 16),
                        _buildLegalLinks(),
                        const SizedBox(height: 20),
                        Text(
                          'Payment processed via Stripe. You will not be charged until your 7-day free trial ends, and you can cancel anytime from your Stripe account.',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.35),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroSection(MembershipService membershipService) {
    return Column(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [AppColors.primary, const Color(0xFFF5C518)],
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.4),
                blurRadius: 24,
                spreadRadius: 4,
              ),
            ],
          ),
          child: const Icon(Icons.auto_awesome, color: Colors.black, size: 40),
        ),
        const SizedBox(height: 20),
        const Text(
          'Unlock Premium',
          style: TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 10),
        Obx(() {
          final text = membershipService.statusDescription;
          final isPremium = membershipService.isPremium;
          return Text(
            text,
            style: TextStyle(
              color: isPremium
                  ? Colors.green.shade300
                  : membershipService.freeMediaDaysRemaining > 0
                      ? Colors.amber.shade300
                      : Colors.redAccent.shade100,
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          );
        }),
      ],
    );
  }

  Widget _buildTermsCheckbox() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withValues(alpha: 0.05),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              setState(() => _termsAccepted = !_termsAccepted);
            },
            child: Container(
              width: 20,
              height: 20,
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: _termsAccepted
                      ? AppColors.primary
                      : Colors.white.withValues(alpha: 0.4),
                  width: 2,
                ),
                color: _termsAccepted ? AppColors.primary : Colors.transparent,
              ),
              child: _termsAccepted
                  ? const Icon(Icons.check, color: Colors.black, size: 14)
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() => _termsAccepted = !_termsAccepted);
              },
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'I accept the ',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 14,
                      ),
                    ),
                    WidgetSpan(
                      child: InkWell(
                        onTap: () => _launchUrl(NetworkConstants.appleTermsUrl),
                        child: Text(
                          'Terms of Use (EULA)',
                          style: TextStyle(
                            color: AppColors.primary,
                            fontSize: 14,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                    TextSpan(
                      text: ' and ',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 14,
                      ),
                    ),
                    WidgetSpan(
                      child: InkWell(
                        onTap: () =>
                            _launchUrl(NetworkConstants.privacyPolicyUrl),
                        child: Text(
                          'Privacy Policy',
                          style: TextStyle(
                            color: AppColors.primary,
                            fontSize: 14,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentMethodInfo() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withValues(alpha: 0.05),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.payment,
            color: AppColors.primary,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Payment Method',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Stripe Checkout (cards, Apple Pay, Google Pay)',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStripePlanButton(
    StripeSubscriptionService stripeService, {
    required String planId,
    required String title,
    required String price,
    required String perMonth,
    required bool isPopular,
  }) {
    final isProcessing = _processingPlanId == planId;
    return GestureDetector(
      onTap: _processingPlanId != null
          ? null
          : () {
              if (!_termsAccepted) {
                _showTermsAlert();
                return;
              }
              _startTrial(stripeService, planId);
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isPopular
                ? AppColors.primary
                : _processingPlanId == planId
                    ? Colors.white38
                    : Colors.white12,
            width: isPopular ? 2 : 1,
          ),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isPopular
                ? [
                    AppColors.primary.withValues(alpha: 0.18),
                    AppColors.primary.withValues(alpha: 0.06),
                  ]
                : [
                    Colors.white.withValues(alpha: 0.07),
                    Colors.white.withValues(alpha: 0.03),
                  ],
          ),
          boxShadow: isPopular
              ? [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.25),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ]
              : [],
        ),
        child: Stack(
          children: [
            if (isPopular)
              Positioned(
                top: 0,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'BEST VALUE',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          perMonth,
                          style: TextStyle(
                            color: isPopular
                                ? AppColors.primary
                                : Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '7-day free trial, then auto-renews',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.35),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        price,
                        style: TextStyle(
                          color: isPopular ? AppColors.primary : Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        planId == '1_year' ? '/ year' : '/ 6 months',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  isProcessing
                      ? const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : Container(
                          width: 35,
                          height: 35,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isPopular
                                ? AppColors.primary
                                : Colors.white.withValues(alpha: 0.1),
                          ),
                          child: Icon(
                            Icons.arrow_forward_rounded,
                            color: isPopular ? Colors.black : Colors.white70,
                            size: 18,
                          ),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCryptoButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () {
          if (!_termsAccepted) {
            _showTermsAlert();
            return;
          }
          Get.to(() => const CryptoPaymentScreen());
        },
        icon: const Icon(Icons.currency_bitcoin, color: Colors.orangeAccent),
        label: const Text('Pay with Crypto (USDC via Stripe)'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Colors.white24),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }

  Widget _buildFeaturesSection() {
    const features = [
      (Icons.phone_in_talk_rounded, 'Voice calls'),
      (Icons.photo_library_rounded, 'Unlimited photo sharing'),
      (Icons.attach_file_rounded, 'Send files without limits'),
      (Icons.bolt_rounded, 'Priority customer support'),
      (Icons.new_releases_rounded, 'Early access to new features'),
      (Icons.lock_rounded, 'Enhanced privacy controls'),
    ];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.white.withValues(alpha: 0.05),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Everything in Premium',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          ...features.map(
            (f) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.primary.withValues(alpha: 0.15),
                    ),
                    child: Icon(f.$1, color: AppColors.primary, size: 18),
                  ),
                  const SizedBox(width: 14),
                  Text(
                    f.$2,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubscriptionInfo(RegionPricing pricing) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Subscription Terms',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          _buildTermsItem(
            'Vant Chat Premium is an auto-renewable subscription.',
          ),
          _buildTermsItem(
            '6-Month Plan: ${pricing.sixMonthDisplay} — billed every 6 months until cancelled.',
          ),
          _buildTermsItem(
            '1-Year Plan: ${pricing.oneYearDisplay} — billed every 12 months until cancelled.',
          ),
          _buildTermsItem(
            'Start with a 7-day free trial. You will not be charged until the trial ends.',
          ),
          _buildTermsItem(
            'Subscription automatically renews unless cancelled at least 24 hours before the end of the current period.',
          ),
          _buildTermsItem(
            'Your account will be charged for renewal within 24 hours prior to the end of the current period.',
          ),
          _buildTermsItem(
            'You can manage or cancel your subscription anytime from your Stripe customer portal.',
          ),
        ],
      ),
    );
  }

  Widget _buildTermsItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegalLinks() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        children: [
          Text(
            'Legal Information',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLegalLink(
                'Terms of Use (EULA)',
                NetworkConstants.appleTermsUrl,
              ),
              const SizedBox(width: 20),
              _buildLegalLink(
                'Privacy Policy',
                NetworkConstants.privacyPolicyUrl,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegalLink(String title, String url) {
    return InkWell(
      onTap: () => _launchUrl(url),
      child: Text(
        title,
        style: TextStyle(
          color: AppColors.primary,
          fontSize: 12,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showTermsAlert() {
    Get.dialog(
      AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text(
          'Accept Terms Required',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: const Text(
          'Please accept the Terms of Use and Privacy Policy to continue with your purchase.',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 14,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              Get.back();
              setState(() => _termsAccepted = true);
            },
            child: Text(
              'Accept & Continue',
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      barrierDismissible: true,
    );
  }

  String _calculatePerMonth(int totalPrice, int months, String currencySymbol) {
    final perMonth = (totalPrice / months / 100).toStringAsFixed(2);
    return '$currencySymbol$perMonth / month';
  }

  Future<void> _startTrial(
      StripeSubscriptionService stripeService, String planId) async {
    if (!stripeService.isAvailable) {
      Get.snackbar(
        'Unavailable',
        'Card/Apple Pay/Google Pay checkout is not configured on this build yet.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.orange.shade100,
        colorText: Colors.orange.shade800,
      );
      return;
    }

    setState(() => _processingPlanId = planId);
    final result = await stripeService.startTrialSubscription(planId);
    if (!mounted) return;
    setState(() => _processingPlanId = null);

    if (result.success) {
      await Get.find<MembershipService>().activateMembership(
        selectedPlan: planId,
        purchaseId: 'stripe_subscription',
      );
      Get.back();
      Get.snackbar(
        'Membership Activated',
        'Your membership has been activated successfully.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.green.shade100,
        colorText: Colors.green.shade800,
      );
    } else if (!result.cancelled) {
      Get.snackbar(
        'Payment Failed',
        result.error ?? 'Something went wrong. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
    }
  }
}

/// One-time crypto payment screen using Stripe's own "Stablecoins and
/// Crypto" payment method: we create a Stripe Checkout Session restricted to
/// `payment_method_types: ['crypto']`, open it in the browser (customer
/// connects a wallet like MetaMask/Phantom at crypto.stripe.com and pays in
/// USDC), then poll our backend - which is updated by the
/// `checkout.session.completed` webhook - until the payment is confirmed.
///
/// Note: this requires "Stablecoins and Crypto" to be approved for your
/// Stripe account under Settings -> Payment methods; until then, creating
/// the checkout session will fail with a Stripe error.
class CryptoPaymentScreen extends StatefulWidget {
  const CryptoPaymentScreen({super.key});

  @override
  State<CryptoPaymentScreen> createState() => _CryptoPaymentScreenState();
}

class _CryptoPaymentScreenState extends State<CryptoPaymentScreen> {
  String _selectedPlan = '6_months';
  bool _isStarting = false;
  bool _checkoutOpened = false;
  bool _termsAccepted = false;
  Timer? _pollTimer;
  String _status = 'idle';

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1A1A2E), Color(0xFF0A0A0F)],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Get.back(),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHero(),
                        const SizedBox(height: 16),
                        if (!_checkoutOpened) ...[
                          _buildTermsCheckbox(),
                          const SizedBox(height: 16),
                        ],
                        _buildPlanPicker(),
                        const SizedBox(height: 16),
                        _buildSubscriptionInfo(),
                        const SizedBox(height: 16),
                        _buildLegalLinks(),
                        const SizedBox(height: 20),
                        Text(
                          'Crypto payments are one-time and processed via Stripe. You will be redirected to a secure Stripe checkout page.',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.35),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHero() {
    return Column(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [AppColors.primary, const Color(0xFFF5C518)],
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.4),
                blurRadius: 24,
                spreadRadius: 4,
              ),
            ],
          ),
          child: const Icon(Icons.currency_bitcoin, color: Colors.black, size: 40),
        ),
        const SizedBox(height: 20),
        const Text(
          'Pay with Crypto',
          style: TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'One-time payment via Stripe. Secure and non-custodial.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 14,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildTermsCheckbox() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withValues(alpha: 0.05),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              setState(() => _termsAccepted = !_termsAccepted);
            },
            child: Container(
              width: 20,
              height: 20,
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: _termsAccepted
                      ? AppColors.primary
                      : Colors.white.withValues(alpha: 0.4),
                  width: 2,
                ),
                color: _termsAccepted ? AppColors.primary : Colors.transparent,
              ),
              child: _termsAccepted
                  ? const Icon(Icons.check, color: Colors.black, size: 14)
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() => _termsAccepted = !_termsAccepted);
              },
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'I accept the ',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 14,
                      ),
                    ),
                    WidgetSpan(
                      child: InkWell(
                        onTap: () => _launchUrl(NetworkConstants.appleTermsUrl),
                        child: Text(
                          'Terms of Use (EULA)',
                          style: TextStyle(
                            color: AppColors.primary,
                            fontSize: 14,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                    TextSpan(
                      text: ' and ',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 14,
                      ),
                    ),
                    WidgetSpan(
                      child: InkWell(
                        onTap: () =>
                            _launchUrl(NetworkConstants.privacyPolicyUrl),
                        child: Text(
                          'Privacy Policy',
                          style: TextStyle(
                            color: AppColors.primary,
                            fontSize: 14,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlanPicker() {
    final pricing = PricingConfig.globalPricing;
    if (_checkoutOpened) {
      return _buildWaitingView();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Choose a plan',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          children: [
            ChoiceChip(
              label: Text('6 Months - ${pricing.sixMonthDisplay}'),
              selected: _selectedPlan == '6_months',
              onSelected: (_) => setState(() => _selectedPlan = '6_months'),
              selectedColor: AppColors.primary,
              labelStyle: TextStyle(
                  color: _selectedPlan == '6_months'
                      ? Colors.black87
                      : Colors.white),
              backgroundColor: Colors.white.withValues(alpha: 0.08),
            ),
            ChoiceChip(
              label: Text('1 Year - ${pricing.oneYearDisplay}'),
              selected: _selectedPlan == '1_year',
              onSelected: (_) => setState(() => _selectedPlan = '1_year'),
              selectedColor: AppColors.primary,
              labelStyle: TextStyle(
                  color: _selectedPlan == '1_year'
                      ? Colors.black87
                      : Colors.white),
              backgroundColor: Colors.white.withValues(alpha: 0.08),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          'You\'ll be taken to a secure Stripe page to connect your crypto wallet (e.g. MetaMask, Phantom) and pay in USDC.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _isStarting ? null : _startCheckout,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.black87,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: _isStarting
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Continue to Pay with Crypto'),
          ),
        ),
      ],
    );
  }

  Widget _buildWaitingView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Waiting for your crypto payment to confirm...',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        const SizedBox(height: 12),
        Text(
          'Status: $_status',
          style: const TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 20),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _startCheckout,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white24),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('Reopen Checkout Page'),
          ),
        ),
      ],
    );
  }

  Widget _buildSubscriptionInfo() {
    final pricing = PricingConfig.globalPricing;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Crypto Payment Terms',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          _buildTermsItem(
            'Crypto payments are one-time purchases that activate Premium immediately.',
          ),
          _buildTermsItem(
            '6-Month Plan: ${pricing.sixMonthDisplay}.',
          ),
          _buildTermsItem(
            '1-Year Plan: ${pricing.oneYearDisplay}.',
          ),
          _buildTermsItem(
            'Stripe converts your crypto payment to fiat. No wallet addresses are handled by this app.',
          ),
          _buildTermsItem(
            'Refunds are handled according to our Terms of Use and Privacy Policy.',
          ),
        ],
      ),
    );
  }

  Widget _buildTermsItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegalLinks() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        children: [
          Text(
            'Legal Information',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLegalLink(
                'Terms of Use (EULA)',
                NetworkConstants.appleTermsUrl,
              ),
              const SizedBox(width: 20),
              _buildLegalLink(
                'Privacy Policy',
                NetworkConstants.privacyPolicyUrl,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegalLink(String title, String url) {
    return InkWell(
      onTap: () => _launchUrl(url),
      child: Text(
        title,
        style: TextStyle(
          color: AppColors.primary,
          fontSize: 12,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _startCheckout() async {
    if (!_termsAccepted) {
      _showTermsAlert();
      return;
    }
    setState(() => _isStarting = true);
    try {
      final deviceId = Get.find<LocalStorageService>().deviceId ?? '';
      final data = await ApiService.to.createCryptoCheckout(
        deviceId: deviceId,
        planId: _selectedPlan,
      );

      final url = data['url'] as String?;
      if (url == null) throw Exception('No checkout URL returned');

      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw Exception('Could not open checkout page');
      }

      if (!mounted) return;
      setState(() {
        _checkoutOpened = true;
        _status = 'pending';
      });
      _startPolling(deviceId);
    } catch (e) {
      Get.snackbar(
        'Error',
        'Failed to start crypto checkout. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
    } finally {
      if (mounted) setState(() => _isStarting = false);
    }
  }

  void _showTermsAlert() {
    Get.dialog(
      AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text(
          'Accept Terms Required',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: const Text(
          'Please accept the Terms of Use and Privacy Policy to continue with your purchase.',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 14,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              Get.back();
              setState(() => _termsAccepted = true);
            },
            child: Text(
              'Accept & Continue',
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      barrierDismissible: true,
    );
  }

  void _startPolling(String deviceId) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        final result = await ApiService.to.getCryptoCheckoutStatus(deviceId);
        final status = result['status'] as String? ?? 'pending';
        if (!mounted) return;
        setState(() => _status = status);
        if (status == 'active') {
          _pollTimer?.cancel();
          await Get.find<MembershipService>().activateMembership(
            selectedPlan: _selectedPlan,
            purchaseId: 'stripe_crypto_checkout',
          );
          Get.back();
          Get.snackbar(
            'Payment Confirmed!',
            'Your Premium membership is now active.',
            snackPosition: SnackPosition.BOTTOM,
            backgroundColor: Colors.green.shade100,
            colorText: Colors.green.shade800,
          );
        }
      } catch (_) {
        // ignore transient polling errors
      }
    });
  }
}
