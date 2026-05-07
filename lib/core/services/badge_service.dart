import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing app icon badge count
/// Handles global unread message counter across all chats
class BadgeService extends GetxService {
  static const String _key = 'total_unread_count';
  static const int _maxBadgeCount = 999;

  /// Get current total unread count from SharedPreferences
  Future<int> getTotalUnreadCount() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_key) ?? 0;
    } catch (e) {
      debugPrint('❌ Error getting badge count: $e');
      return 0;
    }
  }

  /// Set total unread count and update app icon badge
  Future<void> setTotalUnreadCount(int count) async {
    final clampedCount = count.clamp(0, _maxBadgeCount);
    await _saveCount(clampedCount);
  }

  /// Increment badge count by 1
  Future<void> incrementBadge() async {
    final current = await getTotalUnreadCount();
    await _saveCount(current + 1);
  }

  /// Decrement badge count by specified amount
  Future<void> decrementBadge(int amount) async {
    final current = await getTotalUnreadCount();
    final newCount = (current - amount).clamp(0, _maxBadgeCount);
    await _saveCount(newCount);
  }

  /// Reset badge count to 0
  Future<void> resetBadge() async {
    await _saveCount(0);
  }

  /// Handle silent sync from backend (multi-device sync)
  /// Called when backend sends silent FCM with updated badge count
  Future<void> handleSilentSync(int badgeCount) async {
    final clampedCount = badgeCount.clamp(0, _maxBadgeCount);
    await _saveCount(clampedCount);
    debugPrint('🔄 Badge synced from backend: $clampedCount');
  }

  /// Save count to SharedPreferences and update app icon badge
  Future<void> _saveCount(int count) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, count);
      debugPrint('💾 Badge count saved: $count');

      // Update the actual hardware icon
      await updateAppIconBadge(count);
    } catch (e) {
      debugPrint('❌ Error saving badge count: $e');
    }
  }

  /// Update the actual app icon badge on device
  Future<void> updateAppIconBadge(int count) async {
    try {
      if (count == 0) {
        await AppBadgePlus.updateBadge(0);
        debugPrint('🔕 Badge removed');
      } else {
        await AppBadgePlus.updateBadge(count);
        debugPrint('🔔 Badge updated to: $count');
      }
    } catch (e) {
      debugPrint('❌ Error updating app icon badge: $e');
    }
  }
}
