import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/qr_service.dart';
import '../chat_list/chat_list_controller.dart';

class QRScannerController extends GetxController {
  late MobileScannerController scannerController;
  final RxBool isScanning = true.obs;

  @override
  void onInit() {
    super.onInit();
    scannerController = MobileScannerController();
  }

  @override
  void onReady() {
    super.onReady();
    scannerController.start();
  }

  @override
  void onClose() {
    scannerController.dispose();
    super.onClose();
  }

  /// Handle QR code detection
  void onDetect(BarcodeCapture capture) {
    final List<Barcode> barcodes = capture.barcodes;
    if (isScanning.value && barcodes.isNotEmpty) {
      final barcode = barcodes.first;
      if (barcode.rawValue != null) {
        handleScannedData(barcode.rawValue!);
      }
    }
  }

  /// Handle scanned QR data
  Future<void> handleScannedData(String qrData) async {
    // Stop scanning
    isScanning.value = false;
    await scannerController.stop();

    try {
      // 1. Try legacy base64 format first (backwards compatibility)
      String? deviceId = await QRService.validateQRData(qrData);

      // 2. Fall back to URL format: https://vant.chat/chat?device_id=XXXX
      deviceId ??= _extractDeviceIdFromUrl(qrData);

      if (deviceId != null) {
        // Valid QR code - initialize chat and navigate
        final chatListController = Get.find<ChatListController>();
        await chatListController.initializeChatFromQR(deviceId);
        // Navigation is handled in initializeChatFromQR
      } else {
        // Invalid QR code
        showInvalidQRDialog();
      }
    } catch (e) {
      // Error processing QR code
      showErrorDialog(e.toString());
    }
  }

  /// Extract device_id from a vant.chat invitation URL.
  /// Handles https://vant.chat/chat?device_id=XXXX and any URL containing device_id.
  String? _extractDeviceIdFromUrl(String qrData) {
    try {
      final uri = Uri.tryParse(qrData);
      if (uri == null) return null;
      final deviceId = uri.queryParameters['device_id'];
      if (deviceId != null && deviceId.isNotEmpty) {
        return deviceId;
      }
    } catch (_) {}
    return null;
  }

  /// Show invalid QR code dialog
  void showInvalidQRDialog() {
    Get.defaultDialog(
      title: 'Invalid QR Code',
      middleText: 'This QR code is not from Pear Messaging app or has expired.',
      textConfirm: 'Try Again',
      textCancel: 'Cancel',
      confirmTextColor: Colors.white,
      buttonColor: AppColors.primary,
      onConfirm: () {
        Get.back();
        resumeScanning();
      },
      onCancel: () {
        Get.back();
        Get.back(); // Go back to chat list
      },
    );
  }

  /// Show error dialog
  void showErrorDialog(String error) {
    Get.defaultDialog(
      title: 'Scan Error',
      middleText: 'Failed to process QR code: $error',
      textConfirm: 'Try Again',
      textCancel: 'Cancel',
      confirmTextColor: Colors.white,
      buttonColor: AppColors.primary,
      onConfirm: () {
        Get.back();
        resumeScanning();
      },
      onCancel: () {
        Get.back();
        Get.back(); // Go back to chat list
      },
    );
  }

  /// Resume scanning
  void resumeScanning() {
    isScanning.value = true;
    scannerController.start();
  }

  /// Toggle torch/flash
  Future<void> toggleTorch() async {
    await scannerController.toggleTorch();
  }
}
