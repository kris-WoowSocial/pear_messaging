import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'socket_service.dart';

/// Global service to manage user block state across the entire app
class BlockService extends GetxService {
  static BlockService get to => Get.find();

  final SocketService _socketService = Get.find();

  // Map to store block state for all users
  final RxMap<String, bool> _blockedUsers = <String, bool>{}.obs;

  // Map to store users who have blocked me
  final RxMap<String, bool> _blockedByUsers = <String, bool>{}.obs;

  // Getters
  Set<String> get blockedUsers => _blockedUsers.keys.toSet();
  RxMap<String, bool> get blockedUsersRx => _blockedUsers;
  Set<String> get blockedByUsers => _blockedByUsers.keys.toSet();
  RxMap<String, bool> get blockedByUsersRx => _blockedByUsers;

  /// Check if a user is blocked
  bool isUserBlocked(String deviceId) {
    return _blockedUsers[deviceId] ?? false;
  }

  /// Check if a user has blocked me
  bool hasUserBlockedMe(String deviceId) {
    return _blockedByUsers[deviceId] ?? false;
  }

  /// Check if messaging is allowed (both directions)
  bool isMessagingAllowed(String deviceId) {
    return !isUserBlocked(deviceId) && !hasUserBlockedMe(deviceId);
  }

  /// Block a user globally
  Future<bool> blockUser(String deviceId) async {
    try {
      // Send block request via socket
      _socketService.blockUser(deviceId);

      // Update local state immediately (optimistic update)
      _blockedUsers[deviceId] = true;

      debugPrint('🚫 User blocked globally: $deviceId');
      return true;
    } catch (e) {
      debugPrint('❌ Failed to block user: $e');
      return false;
    }
  }

  /// Unblock a user globally
  Future<bool> unblockUser(String deviceId) async {
    try {
      // Send unblock request via socket
      _socketService.unblockUser(deviceId);

      // Update local state immediately (optimistic update)
      _blockedUsers.remove(deviceId);

      debugPrint('✅ User unblocked globally: $deviceId');
      return true;
    } catch (e) {
      debugPrint('❌ Failed to unblock user: $e');
      return false;
    }
  }

  /// Check block status with server and update local state
  void checkBlockStatus(String deviceId) {
    _socketService.checkBlockStatus(deviceId);
  }

  /// Initialize block status listeners
  void initializeListeners() {
    // Listen for block status responses
    _socketService.onBlockStatus = (Map<String, dynamic> data) {
      if (data['status'] == 'success') {
        final targetDeviceId = data['targetDeviceId'] as String?;
        if (targetDeviceId != null) {
          // Update local block state based on server response
          final isBlockedByMe =
              data['isBlockedByMe'] == true || data['isBlockedByMe'] == 1;
          if (isBlockedByMe) {
            _blockedUsers[targetDeviceId] = true;
          } else {
            _blockedUsers.remove(targetDeviceId);
          }
          debugPrint(
              '🔍 Block status updated for $targetDeviceId: blockedByMe=$isBlockedByMe');
        }
      }
    };

    // Listen for user blocked notifications
    _socketService.onUserBlocked = (Map<String, dynamic> data) {
      final status = data['status'] as String?;
      final targetDeviceId = data['targetDeviceId'] as String?;
      final blockerDeviceId = data['blockerDeviceId'] as String?;

      debugPrint(
          '🔔 Received user_blocked notification: status=$status, targetDeviceId=$targetDeviceId, blockerDeviceId=$blockerDeviceId');

      if ((status == 'success' || status == 'blocked_by_other') &&
          targetDeviceId != null) {
        if (blockerDeviceId == null) {
          // I blocked the recipient (no blockerDeviceId means I initiated)
          _blockedUsers[targetDeviceId] = true;
          debugPrint('🚫 I blocked user: $targetDeviceId');
        } else {
          // Someone else blocked the target
          if (blockerDeviceId == _socketService.deviceId) {
            // I blocked the recipient
            _blockedUsers[targetDeviceId] = true;
            debugPrint('🚫 I blocked user: $targetDeviceId');
          } else {
            // The blocker blocked me
            _blockedByUsers[blockerDeviceId] = true;
            debugPrint('🚫 User $blockerDeviceId blocked me');
          }
        }
      } else {
        debugPrint(
            '⚠️ Ignoring user_blocked notification: status=$status, targetDeviceId=$targetDeviceId');
      }
    };

    // Listen for user unblocked notifications
    _socketService.onUserUnblocked = (Map<String, dynamic> data) {
      final status = data['status'] as String?;
      final targetDeviceId = data['targetDeviceId'] as String?;
      final unblockerDeviceId = data['unblockerDeviceId'] as String?;

      debugPrint(
          '🔔 Received user_unblocked notification: status=$status, targetDeviceId=$targetDeviceId, unblockerDeviceId=$unblockerDeviceId');

      if ((status == 'success' || status == 'unblocked_by_other') &&
          targetDeviceId != null) {
        if (unblockerDeviceId == null) {
          // I unblocked the recipient (no unblockerDeviceId means I initiated)
          _blockedUsers.remove(targetDeviceId);
          debugPrint('✅ I unblocked user: $targetDeviceId');
        } else {
          // Someone else unblocked the target
          if (unblockerDeviceId == _socketService.deviceId) {
            // I unblocked the recipient
            _blockedUsers.remove(targetDeviceId);
            debugPrint('✅ I unblocked user: $targetDeviceId');
          } else {
            // The unblocker unblocked me
            _blockedByUsers.remove(unblockerDeviceId);
            debugPrint('✅ User $unblockerDeviceId unblocked me');
          }
        }
      } else {
        debugPrint(
            '⚠️ Ignoring user_unblocked notification: status=$status, targetDeviceId=$targetDeviceId');
      }
    };
  }

  @override
  void onInit() {
    super.onInit();
    initializeListeners();
  }
}
