import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/constants/app_strings.dart';
import '../../core/services/local_storage_service.dart';
import '../../routes/app_routes.dart';
import 'onboarding_model.dart';

class OnboardingController extends GetxController {
  final LocalStorageService _storageService = Get.find();
  
  final PageController pageController = PageController();
  final RxInt currentPage = 0.obs;
  
  final List<OnboardingModel> pages = [
    OnboardingModel(
      title: AppStrings.onboardingTitle1,
      description: AppStrings.onboardingDesc1,
      image: 'assets/images/onboarding1.png',
    ),
    OnboardingModel(
      title: AppStrings.onboardingTitle2,
      description: AppStrings.onboardingDesc2,
      image: 'assets/images/onboarding2.png',
    ),
    OnboardingModel(
      title: AppStrings.onboardingTitle3,
      description: AppStrings.onboardingDesc3,
      image: 'assets/images/onboarding3.png',
    ),
  ];

  void onPageChanged(int index) {
    currentPage.value = index;
  }

  void nextPage() {
    if (currentPage.value < pages.length - 1) {
      pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void skip() {
    pageController.jumpToPage(pages.length - 1);
  }

  Future<void> completeOnboarding() async {
    await _storageService.setOnboardingCompleted(true);
    Get.offAllNamed(AppRoutes.chatList);
  }

  @override
  void onClose() {
    pageController.dispose();
    super.onClose();
  }
}
