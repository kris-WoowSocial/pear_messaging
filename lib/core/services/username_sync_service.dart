import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'local_storage_service.dart';

/// Service to sync usernames with backend for notification titles
class UsernameSyncService extends GetxService {
  /// Initialize the service
  Future<UsernameSyncService> init() async {
    debugPrint('🔄 UsernameSyncService initialized');
    return this;
  }

  /// Sync username to backend
  Future<bool> syncUsername(String deviceId, String username) async {
    try {
      debugPrint('🔄 Syncing username to backend: $deviceId -> $username');
      await ApiService.to.setUsername(deviceId, username);
      debugPrint('✅ Username synced successfully: $username');
      return true;
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
          '🔄 Syncing contact name: $ownerDeviceId calls $contactDeviceId as "$displayName"');
      await ApiService.to.syncContactName(
        ownerDeviceId: ownerDeviceId,
        contactDeviceId: contactDeviceId,
        displayName: displayName,
      );
      debugPrint('✅ Contact name synced successfully: "$displayName"');
      return true;
    } catch (e) {
      debugPrint('❌ Error syncing contact name: $e');
      return false;
    }
  }

  /// Get username from backend
  Future<String?> getUsername(String deviceId) async {
    try {
      debugPrint('🔄 Fetching username from backend: $deviceId');
      final data = await ApiService.to.getUsername(deviceId);
      final username = data?['username'] as String?;
      debugPrint('✅ Username fetched from backend: $username');
      return username;
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
        // Mirror to the App Group store so native iOS code can read it
        // before Flutter starts (PushKit incoming-call name lookup).
        if (Platform.isIOS) {
          unawaited(
              LocalStorageService.writeContactNameToAppGroup(deviceId, username));
        }
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
