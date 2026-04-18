import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

class InvitationStorageService extends GetxService {
  late SharedPreferences _prefs;

  static const String _pendingInvitationKey = 'pending_invitation';
  static const String _pendingDeviceIdKey = 'pending_device_id';
  static const String _pendingUserNameKey = 'pending_user_name';
  static const String _invitationTimestampKey = 'invitation_timestamp';

  /// Initialize the service
  Future<InvitationStorageService> init() async {
    _prefs = await SharedPreferences.getInstance();
    debugPrint('📋 Invitation Storage Service initialized');

    // Enhanced cleanup: Run startup cleanup to remove stale invitations
    _cleanupExpiredInvitations();

    return this;
  }

  /// Clean up expired invitations on startup
  void _cleanupExpiredInvitations() {
    try {
      if (hasPendingInvitation()) {
        final pendingInvitation = getPendingInvitation();
        if (pendingInvitation == null) {
          // getPendingInvitation() already cleared expired invitation
          debugPrint('📋 Startup cleanup: Removed expired invitation');
        }
      }
    } catch (e) {
      debugPrint('⚠️ Error during startup cleanup: $e');
    }
  }

  /// Store invitation data when user clicks link but doesn't have app
  Future<void> storePendingInvitation({
    required String deviceId,
    required String userName,
  }) async {
    try {
      await _prefs.setString(_pendingDeviceIdKey, deviceId);
      await _prefs.setString(_pendingUserNameKey, userName);
      await _prefs.setInt(
          _invitationTimestampKey, DateTime.now().millisecondsSinceEpoch);
      await _prefs.setBool(_pendingInvitationKey, true);

      debugPrint('📋 Stored pending invitation: $deviceId ($userName)');
    } catch (e) {
      debugPrint('❌ Error storing pending invitation: $e');
    }
  }

  /// Check if there's a pending invitation
  bool hasPendingInvitation() {
    return _prefs.getBool(_pendingInvitationKey) ?? false;
  }

  /// Get pending invitation data
  Map<String, String>? getPendingInvitation() {
    if (!hasPendingInvitation()) {
      return null;
    }

    try {
      final deviceId = _prefs.getString(_pendingDeviceIdKey);
      final userName = _prefs.getString(_pendingUserNameKey);
      final timestamp = _prefs.getInt(_invitationTimestampKey) ??
          DateTime.now().millisecondsSinceEpoch;

      if (deviceId != null && userName != null) {
        // Check if invitation is not too old (24 hours)
        final invitationTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
        final now = DateTime.now();

        if (now.difference(invitationTime).inHours < 24) {
          return {
            'deviceId': deviceId,
            'userName': userName,
            'timestamp': timestamp.toString(),
          };
        } else {
          // Invitation is too old, clear it
          clearPendingInvitation();
          debugPrint('📋 Cleared expired pending invitation');
          return null;
        }
      }
    } catch (e) {
      debugPrint('❌ Error retrieving pending invitation: $e');
    }

    return null;
  }

  /// Clear pending invitation after processing
  Future<void> clearPendingInvitation() async {
    try {
      await _prefs.remove(_pendingInvitationKey);
      await _prefs.remove(_pendingDeviceIdKey);
      await _prefs.remove(_pendingUserNameKey);
      await _prefs.remove(_invitationTimestampKey);

      debugPrint('📋 Cleared pending invitation');
    } catch (e) {
      debugPrint('❌ Error clearing pending invitation: $e');
    }
  }

  /// Store invitation data from Branch link (for first-time installs)
  Future<void> storeBranchInvitation(Map<String, dynamic> branchData) async {
    try {
      String? deviceId;
      String? userName = 'Unknown User';

      // Extract device ID from branch data
      if (branchData.containsKey('device_id')) {
        deviceId = branchData['device_id'] as String?;
      } else if (branchData.containsKey('~canonical_identifier')) {
        final canonical = branchData['~canonical_identifier'] as String?;
        if (canonical != null && canonical.startsWith('chat/')) {
          deviceId = canonical.substring(5);
        }
      }

      // Extract user name
      if (branchData.containsKey('user_name')) {
        userName = branchData['user_name'] as String?;
      }

      if (deviceId != null && deviceId.isNotEmpty) {
        await storePendingInvitation(
            deviceId: deviceId, userName: userName ?? 'Unknown User');
        debugPrint('📋 Stored Branch invitation for post-install processing');
      }
    } catch (e) {
      debugPrint('❌ Error storing Branch invitation: $e');
    }
  }

  /// Store invitation data from URL parameters (fallback mechanism)
  Future<void> storeInvitationFromUrl(String url) async {
    try {
      debugPrint('📋 Attempting to extract invitation from URL: $url');

      // Parse the URL to extract device ID
      final uri = Uri.parse(url);

      // Try to get device ID from various possible parameters
      String? deviceId;
      String? userName = 'Unknown User';

      // Check query parameters
      if (uri.queryParameters.containsKey('device_id')) {
        deviceId = uri.queryParameters['device_id'];
      }
      if (uri.queryParameters.containsKey('user_name')) {
        userName = uri.queryParameters['user_name'];
      }

      // Check path segments
      if (deviceId == null && uri.pathSegments.isNotEmpty) {
        for (final segment in uri.pathSegments) {
          if (segment.length > 10 && segment.length < 50) {
            // Assume it's a device ID if it's reasonably long
            deviceId = segment;
            break;
          }
        }
      }

      if (deviceId != null && deviceId.isNotEmpty) {
        await storePendingInvitation(
            deviceId: deviceId, userName: userName ?? 'Unknown User');
        debugPrint('📋 Stored invitation from URL: $deviceId ($userName)');
        return;
      }

      debugPrint('⚠️ Could not extract device ID from URL');
    } catch (e) {
      debugPrint('❌ Error storing invitation from URL: $e');
    }
  }
}
