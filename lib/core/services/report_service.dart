import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'local_storage_service.dart';

class ReportService extends GetxService {
  static const String _baseUrl = 'https://vant.chat';

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

      final response = await http.post(
        Uri.parse('$_baseUrl/api/reports'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'reporterDeviceId': _deviceId,
          'targetType': targetType,
          'targetId': targetId,
          'reason': reason,
          'description': description,
        }),
      );

      if (response.statusCode == 201) {
        return true;
      } else {
        debugPrint('❌ Report submission failed: ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Report submission error: $e');
      return false;
    } finally {
      isSubmitting.value = false;
    }
  }

  /// Submit a contact us message
  Future<bool> submitContactMessage({
    required String name,
    required String email,
    required String message,
  }) async {
    try {
      isSubmitting.value = true;

      final response = await http.post(
        Uri.parse('$_baseUrl/api/contact'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': name, 'email': email, 'message': message}),
      );

      if (response.statusCode == 201) {
        return true;
      } else {
        debugPrint('❌ Contact submission failed: ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Contact submission error: $e');
      return false;
    } finally {
      isSubmitting.value = false;
    }
  }

  /// Check if current device is muted or banned
  Future<Map<String, dynamic>?> checkModerationStatus() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/moderation/status/$_deviceId'),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (e) {
      debugPrint('❌ Moderation status check error: $e');
      return null;
    }
  }
}
