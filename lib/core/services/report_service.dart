import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'api_service.dart';
import 'local_storage_service.dart';

class ReportService extends GetxService {
  final RxBool isSubmitting = false.obs;

  String get _deviceId {
    final storage = Get.find<LocalStorageService>();
    return storage.deviceId ?? 'unknown';
  }

  /// Submit a report for a user or message
  Future<bool> submitReport({
    required String targetType,
    required String targetId,
    required String reason,
    String description = '',
  }) async {
    try {
      isSubmitting.value = true;
      return await ApiService.to.submitReport(
        reporterDeviceId: _deviceId,
        targetType: targetType,
        targetId: targetId,
        reason: reason,
        description: description,
      );
    } catch (e) {
      debugPrint('❌ Report submission error: $e');
      return false;
    } finally {
      isSubmitting.value = false;
    }
  }

  Future<bool> submitContactMessage({
    required String name,
    required String email,
    required String message,
  }) async {
    try {
      isSubmitting.value = true;
      return await ApiService.to
          .submitContactMessage(name: name, email: email, message: message);
    } catch (e) {
      debugPrint('❌ Contact submission error: $e');
      return false;
    } finally {
      isSubmitting.value = false;
    }
  }

  Future<Map<String, dynamic>?> checkModerationStatus() async {
    try {
      return await ApiService.to.checkModerationStatus(_deviceId);
    } catch (e) {
      debugPrint('❌ Moderation status check error: $e');
      return null;
    }
  }
}
