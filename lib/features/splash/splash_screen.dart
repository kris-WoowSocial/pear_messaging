import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'splash_controller.dart';

class SplashScreen extends GetView<SplashController> {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.showInitialNameSetup();
    });

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Privacy Icon - Green square with connected devices
              Container(
                width: 150,
                height: 150,
                margin: const EdgeInsets.symmetric(vertical: 60),
                decoration: BoxDecoration(
                  color: const Color(0xFF00FF00),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    "assets/icons/logo.jpeg",
                    fit: BoxFit.cover,
                  ),
                ),
              ),

              // Main Title
              const Text(
                'Ultimate privacy',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF00FF00),
                  height: 1.2,
                ),
              ),

              const SizedBox(height: 60),

              // Privacy Features List
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildPrivacyFeature('1. No Servers.'),
                  const SizedBox(height: 16),
                  _buildPrivacyFeature('2. No tracking.'),
                  const SizedBox(height: 16),
                  _buildPrivacyFeature('3. No Metadata.'),
                  const SizedBox(height: 16),
                  _buildPrivacyFeature('4. No Registration.'),
                  const SizedBox(height: 16),
                  _buildPrivacyFeature('5. No data collected.'),
                ],
              ),
              const SizedBox(height: 30),

              // Terms and Privacy Policy section (only on first launch)
              Obx(() => controller.isFirstLaunch.value
                  ? SizedBox(
                      width: double.infinity,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: ElevatedButton(
                          onPressed: controller.acceptTermsAndContinue,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(25),
                            ),
                            elevation: 0,
                          ),
                          child: const Text(
                            'I agree to the Terms and Privacy Policy',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    )
                  : // Loading indicator for returning users
                  Obx(() => controller.isLoading.value
                      ? const CircularProgressIndicator(
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Color(0xFF00FF00)),
                        )
                      : const SizedBox.shrink())),

              const SizedBox(height: 40),

              // Bottom tagline
              const Text(
                'Your data stays only on your device.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  color: Color(0xFF00FF00),
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 40),

              // Terms and Privacy links
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: controller.openTermsOfService,
                    child: const Text(
                      'Terms of Service',
                      style: TextStyle(
                        color: Color(0xFF00FF00),
                        fontSize: 14,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                  const Text(
                    ' and ',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                    ),
                  ),
                  GestureDetector(
                    onTap: controller.openPrivacyPolicy,
                    child: const Text(
                      'Privacy Policy',
                      style: TextStyle(
                        color: Color(0xFF00FF00),
                        fontSize: 14,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPrivacyFeature(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 20,
        color: Color(0xFF00FF00),
        fontWeight: FontWeight.w500,
        height: 1.4,
      ),
    );
  }
}
