import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_strings.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/widgets/primary_button.dart';
import 'onboarding_controller.dart';

class OnboardingScreen extends GetView<OnboardingController> {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Skip button
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: controller.skip,
                child: const Text(
                  'Skip',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppSizes.fontL,
                  ),
                ),
              ),
            ),
            
            // Page View
            Expanded(
              child: PageView.builder(
                controller: controller.pageController,
                onPageChanged: controller.onPageChanged,
                itemCount: controller.pages.length,
                itemBuilder: (context, index) {
                  final page = controller.pages[index];
                  return Padding(
                    padding: const EdgeInsets.all(AppSizes.paddingXL),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Illustration placeholder
                        Container(
                          width: 200,
                          height: 200,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            index == 0
                                ? Icons.lock_outline
                                : index == 1
                                    ? Icons.bolt
                                    : Icons.privacy_tip_outlined,
                            size: 80,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(height: AppSizes.paddingXL),
                        
                        // Title
                        Text(
                          page.title,
                          style: const TextStyle(
                            fontSize: AppSizes.fontXXL,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppSizes.paddingM),
                        
                        // Description
                        Text(
                          page.description,
                          style: const TextStyle(
                            fontSize: AppSizes.fontL,
                            color: AppColors.textSecondary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            
            // Bottom section
            Padding(
              padding: const EdgeInsets.all(AppSizes.paddingXL),
              child: Column(
                children: [
                  // Page indicator
                  SmoothPageIndicator(
                    controller: controller.pageController,
                    count: controller.pages.length,
                    effect: const WormEffect(
                      dotWidth: 10,
                      dotHeight: 10,
                      spacing: 16,
                      activeDotColor: AppColors.primary,
                      dotColor: AppColors.divider,
                    ),
                  ),
                  const SizedBox(height: AppSizes.paddingXL),
                  
                  // Get Started button
                  Obx(() => controller.currentPage.value ==
                          controller.pages.length - 1
                      ? PrimaryButton(
                          text: AppStrings.getStarted,
                          onPressed: controller.completeOnboarding,
                        )
                      : PrimaryButton(
                          text: 'Next',
                          onPressed: controller.nextPage,
                        )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
