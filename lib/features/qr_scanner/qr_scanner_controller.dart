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
      final base64Result = await QRService.validateQRDataEx(qrData);
      String? deviceId = base64Result?.deviceId;
      String? userName = base64Result?.userName;

      // 2. Fall back to URL format: https://vant.chat/chat?device_id=XXXX
      //    (and the Branch quick-link QR: ...app.link/?device_id=X&user_name=Y)
      if (deviceId == null) {
        final urlParts = _extractDeviceIdFromUrl(qrData);
        deviceId = urlParts?.$1;
        userName ??= urlParts?.$2;
      }

      if (deviceId != null) {
        // Valid QR code - initialize chat and navigate
        final chatListController = Get.find<ChatListController>();
        await chatListController.initializeChatFromQR(
          deviceId,
          userName: userName,
        );
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

  /// Extract device_id (and user_name when present) from an invitation URL.
  /// Handles https://vant.chat/chat?device_id=XXXX, the Branch quick-link
  /// (vantchatting.app.link/?device_id=X&user_name=Y), and any URL carrying
  /// a device_id query param.
  (String, String?)? _extractDeviceIdFromUrl(String qrData) {
    try {
      final uri = Uri.tryParse(qrData);
      if (uri == null) return null;
      final deviceId = uri.queryParameters['device_id'];
      if (deviceId != null && deviceId.isNotEmpty) {
        return (deviceId, uri.queryParameters['user_name']);
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
