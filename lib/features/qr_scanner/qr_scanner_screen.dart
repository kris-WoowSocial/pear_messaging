import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import 'qr_scanner_controller.dart';

class QRScannerScreen extends GetView<QRScannerController> {
  const QRScannerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Scan QR Code',
          style: TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () async {
              await controller.toggleTorch();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3, // Reduced flex to give more space to bottom section
            child: Stack(
              children: [
                MobileScanner(
                  controller: controller.scannerController,
                  onDetect: controller.onDetect,
                ),
                // Scanning indicator
                Obx(() => controller.isScanning.value
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(height: 200), // Reduced spacing
                            CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  AppColors.primary),
                            ),
                            SizedBox(height: 16),
                            Text(
                              'Scanning...',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink()),
              ],
            ),
          ),
          Expanded(
            flex: 1, // Increased flex for bottom section
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSizes.paddingL,
                vertical: AppSizes.paddingM, // Reduced vertical padding
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min, // Use minimum space needed
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Position QR code',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: AppSizes.fontM,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSizes.paddingS), // Smaller spacing
                  const Text(
                    'Instant content, any device. Just scan the QR code to start chatting with Vant.',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: AppSizes.fontS,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
