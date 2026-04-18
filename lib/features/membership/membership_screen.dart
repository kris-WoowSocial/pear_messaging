import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/membership_service.dart';
import '../../core/services/region_service.dart';
import '../../core/constants/pricing_config.dart';
import 'membership_controller.dart';

class MembershipScreen extends GetView<MembershipController> {
  const MembershipScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final membershipService = Get.find<MembershipService>();
    final regionService = Get.find<RegionService>();
    final pricing = PricingConfig.getPricingForRegion(regionService.region);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Stack(
        children: [
          // Background gradient
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
                // Custom AppBar
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
                      children: [
                        const SizedBox(height: 16),
                        // Hero section
                        _buildHeroSection(membershipService),
                        const SizedBox(height: 16),
                        // Terms and Conditions Checkbox
                        Obx(() => _buildTermsCheckbox()),
                        const SizedBox(height: 24),
                        // Plan cards
                        Obx(() => _buildPlanCard(
                              planId: '6_months',
                              title: '6 Months',
                              price: pricing.sixMonthDisplay,
                              period: '/ 6 months',
                              perMonth: _calculatePerMonth(
                                  pricing.sixMonthPrice,
                                  6,
                                  pricing.currencySymbol),
                              isPopular: false,
                              isSelected:
                                  controller.selectedPlan.value == '6_months',
                              onTap: () => controller.purchasePlan('6_months'),
                              isProcessing: controller.isProcessing.value &&
                                  controller.selectedPlan.value == '6_months',
                              termsAccepted: controller.termsAccepted.value,
                            )),
                        const SizedBox(height: 16),
                        Obx(() => _buildPlanCard(
                              planId: '1_year',
                              title: '1 Year',
                              price: pricing.oneYearDisplay,
                              period: '/ year',
                              perMonth: _calculatePerMonth(pricing.oneYearPrice,
                                  12, pricing.currencySymbol),
                              isPopular: true,
                              isSelected:
                                  controller.selectedPlan.value == '1_year',
                              onTap: () => controller.purchasePlan('1_year'),
                              isProcessing: controller.isProcessing.value &&
                                  controller.selectedPlan.value == '1_year',
                              termsAccepted: controller.termsAccepted.value,
                            )),
                        const SizedBox(height: 36),
                        // Features
                        _buildFeaturesSection(),
                        const SizedBox(height: 16),
                        // Required Subscription Information
                        _buildSubscriptionInfo(),
                        const SizedBox(height: 16),
                        // Legal Links
                        _buildLegalLinks(),
                        const SizedBox(height: 20),
                        // Disclaimer
                        Text(
                          'Payment processed via App Store/Google Play. Manage subscription from your profile.',
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withOpacity(0.35)),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        // Restore Purchases Button
                        Obx(() => TextButton(
                              onPressed: controller.isRestoring.value
                                  ? null
                                  : () => controller.restorePurchases(),
                              child: controller.isRestoring.value
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white54,
                                      ),
                                    )
                                  : Text(
                                      'Restore Purchases',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Colors.white.withOpacity(0.6),
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                            )),
                        const SizedBox(height: 16),
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
        // Icon
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
                color: AppColors.primary.withOpacity(0.4),
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
          final membershipService = Get.find<MembershipService>();
          final daysLeft = membershipService.freeMediaDaysRemaining;
          final text = daysLeft > 0
              ? '$daysLeft day${daysLeft == 1 ? '' : 's'} of free media remaining'
              : 'Free media period ended · Upgrade to continue';
          return Text(
            text,
            style: TextStyle(
              color: daysLeft > 0
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

  Widget _buildPlanCard({
    required String planId,
    required String title,
    required String price,
    required String period,
    required String perMonth,
    required bool isPopular,
    required bool isSelected,
    required VoidCallback onTap,
    required bool isProcessing,
    required bool termsAccepted,
  }) {
    return GestureDetector(
      onTap: (isProcessing || !termsAccepted)
          ? () {
              if (!termsAccepted) {
                _showTermsAlert();
              }
            }
          : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isPopular
                ? AppColors.primary
                : isSelected
                    ? Colors.white38
                    : Colors.white12,
            width: isPopular ? 2 : 1,
          ),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isPopular
                ? [
                    AppColors.primary.withOpacity(0.18),
                    AppColors.primary.withOpacity(0.06),
                  ]
                : [
                    Colors.white.withOpacity(0.07),
                    Colors.white.withOpacity(0.03),
                  ],
          ),
          boxShadow: isPopular
              ? [
                  BoxShadow(
                    color: AppColors.primary.withOpacity(0.25),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  )
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
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
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          perMonth,
                          style: TextStyle(
                            color:
                                isPopular ? AppColors.primary : Colors.white54,
                            fontSize: 13,
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
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        period,
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
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isPopular
                                ? AppColors.primary
                                : Colors.white.withOpacity(0.1),
                          ),
                          child: Icon(
                            Icons.arrow_forward_rounded,
                            color: isPopular ? Colors.black : Colors.white,
                            size: 20,
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

  Widget _buildFeaturesSection() {
    const features = [
      (Icons.photo_library_rounded, 'Unlimited photo & video sharing'),
      (Icons.attach_file_rounded, 'Send files without limits'),
      (Icons.bolt_rounded, 'Priority customer support'),
      (Icons.new_releases_rounded, 'Early access to new features'),
      (Icons.lock_rounded, 'Enhanced privacy controls'),
    ];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.white.withOpacity(0.05),
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
                      color: AppColors.primary.withOpacity(0.15),
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

  String _calculatePerMonth(int totalPrice, int months, String currencySymbol) {
    // Calculate per-month price from total price in smallest currency unit
    final perMonth = (totalPrice / months / 100).toStringAsFixed(2);
    return '$currencySymbol$perMonth / month';
  }

  Widget _buildSubscriptionInfo() {
    final regionService = Get.find<RegionService>();
    final pricing = PricingConfig.getPricingForRegion(regionService.region);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Subscription Details',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          _buildSubscriptionDetail(
            title: 'Vant Chat Premium - 6 Months',
            duration: '6 months',
            price: pricing.sixMonthDisplay,
            features:
                'Unlimited media sharing, priority support, enhanced privacy',
          ),
          const SizedBox(height: 12),
          _buildSubscriptionDetail(
            title: 'Vant Chat Premium - 1 Year',
            duration: '1 year',
            price: pricing.oneYearDisplay,
            features:
                'Unlimited media sharing, priority support, enhanced privacy, best value',
          ),
        ],
      ),
    );
  }

  Widget _buildSubscriptionDetail({
    required String title,
    required String duration,
    required String price,
    required String features,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Duration: $duration',
          style: TextStyle(
            color: Colors.white.withOpacity(0.7),
            fontSize: 12,
          ),
        ),
        Text(
          'Price: $price',
          style: TextStyle(
            color: Colors.white.withOpacity(0.7),
            fontSize: 12,
          ),
        ),
        Text(
          'Includes: $features',
          style: TextStyle(
            color: Colors.white.withOpacity(0.7),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildLegalLink(String title, String url) {
    return InkWell(
      onTap: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
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

  Widget _buildLegalLinks() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withOpacity(0.03),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        children: [
          Text(
            'Legal Information',
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLegalLink('Terms of Use', 'https://vant.chat/api/terms'),
              const SizedBox(width: 20),
              _buildLegalLink(
                  'Privacy Policy', 'https://vant.chat/privacy-policy.html'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTermsCheckbox() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              controller.termsAccepted.value = !controller.termsAccepted.value;
            },
            child: Container(
              width: 20,
              height: 20,
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: controller.termsAccepted.value
                      ? AppColors.primary
                      : Colors.white.withOpacity(0.4),
                  width: 2,
                ),
                color: controller.termsAccepted.value
                    ? AppColors.primary
                    : Colors.transparent,
              ),
              child: controller.termsAccepted.value
                  ? const Icon(
                      Icons.check,
                      color: Colors.black,
                      size: 14,
                    )
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: () {
                controller.termsAccepted.value =
                    !controller.termsAccepted.value;
              },
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'I accept the ',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.8),
                        fontSize: 14,
                      ),
                    ),
                    WidgetSpan(
                      child: InkWell(
                        onTap: () async {
                          final uri = Uri.parse('https://vant.chat/api/terms');
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri,
                                mode: LaunchMode.externalApplication);
                          }
                        },
                        child: Text(
                          'Terms of Use',
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
                        color: Colors.white.withOpacity(0.8),
                        fontSize: 14,
                      ),
                    ),
                    WidgetSpan(
                      child: InkWell(
                        onTap: () async {
                          final uri = Uri.parse(
                              'https://vant.chat/privacy-policy.html');
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri,
                                mode: LaunchMode.externalApplication);
                          }
                        },
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
          style: TextStyle(
            color: Colors.white70,
            fontSize: 14,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 14,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              Get.back();
              // Scroll to the terms checkbox
              controller.termsAccepted.value = true;
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
}
