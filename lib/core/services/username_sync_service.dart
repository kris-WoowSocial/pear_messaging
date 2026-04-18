import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'local_storage_service.dart';

/// Service to sync usernames with backend for notification titles
class UsernameSyncService extends GetxService {
  static const String _baseUrl =
      'https://vant.chat'; // Use HTTPS instead of HTTP

  /// Initialize the service
  Future<UsernameSyncService> init() async {
    debugPrint('🔄 UsernameSyncService initialized');
    return this;
  }

  /// Sync username to backend
  Future<bool> syncUsername(String deviceId, String username) async {
    try {
      debugPrint('🔄 Syncing username to backend: $deviceId -> $username');

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/username'),
            headers: {
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'deviceId': deviceId,
              'username': username,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        debugPrint('✅ Username synced successfully: $username');
        return true;
      } else {
        debugPrint(
            '❌ Failed to sync username: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Error syncing username: $e');
      return false;
    }
  }

  /// Sync contact name to backend (what user calls someone else)
  Future<bool> syncContactName(
      String ownerDeviceId, String contactDeviceId, String displayName) async {
    try {
      debugPrint(
          '🔄 Syncing contact name to backend: $ownerDeviceId calls $contactDeviceId as "$displayName"');

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/username/contact'),
            headers: {
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'ownerDeviceId': ownerDeviceId,
              'contactDeviceId': contactDeviceId,
              'displayName': displayName,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        debugPrint('✅ Contact name synced successfully: "$displayName"');
        return true;
      } else {
        debugPrint(
            '❌ Failed to sync contact name: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Error syncing contact name: $e');
      return false;
    }
  }

  /// Get username from backend
  Future<String?> getUsername(String deviceId) async {
    try {
      debugPrint('🔄 Fetching username from backend: $deviceId');

      final response = await http
          .get(
            Uri.parse('$_baseUrl/api/username/$deviceId'),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final username = data['username'] as String?;
        debugPrint('✅ Username fetched from backend: $username');
        return username;
      } else {
        debugPrint(
            '❌ Failed to fetch username: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Error fetching username: $e');
      return null;
    }
  }

  /// Sync all saved chat names to backend
  Future<void> syncAllChatNames() async {
    try {
      debugPrint('🔄 Syncing all chat names to backend...');

      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();

      int syncedCount = 0;
      int errorCount = 0;

      for (final key in keys) {
        if (key.startsWith('chat_name_')) {
          final deviceId = key.substring(10); // Remove 'chat_name_' prefix
          final username = prefs.getString(key);

          if (username != null && username.isNotEmpty) {
            final success = await syncUsername(deviceId, username);
            if (success) {
              syncedCount++;
            } else {
              errorCount++;
            }
          }
        }
      }

      debugPrint(
          '🔄 Chat names sync completed: $syncedCount synced, $errorCount errors');
    } catch (e) {
      debugPrint('❌ Error syncing chat names: $e');
    }
  }

  /// Update username in both local storage and backend
  Future<bool> updateUsername(String deviceId, String username) async {
    try {
      // Update in local storage
      final storageService = Get.find<LocalStorageService>();

      // Get existing chat to update its username
      final existingChat = storageService.getChat(deviceId);
      if (existingChat != null) {
        final updatedChat = existingChat.copyWith(userName: username);
        await storageService.saveChat(updatedChat);
        debugPrint('💾 Username updated in local storage: $username');
      } else {
        // Save chat name directly if no existing chat
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('chat_name_$deviceId', username);
        debugPrint(
            '💾 Chat name saved to SharedPreferences: $deviceId -> $username');
      }

      // Sync to backend
      final backendSuccess = await syncUsername(deviceId, username);

      if (backendSuccess) {
        debugPrint(
            '✅ Username updated successfully in both local and backend: $username');
        return true;
      } else {
        debugPrint(
            '⚠️ Username updated locally but failed to sync to backend: $username');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Error updating username: $e');
      return false;
    }
  }
}
