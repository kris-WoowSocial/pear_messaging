import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

class InvitationStorageService extends GetxService {
  late SharedPreferences _prefs;

  static const String _pendingInvitationKey = 'pending_invitation';
  static const String _pendingDeviceIdKey = 'pending_device_id';
  static const String _pendingUserNameKey = 'pending_user_name';
  static const String _invitationTimestampKey = 'invitation_timestamp';

  // Referral attribution context (captured from an install link).
  // Used once, when the referred user accepts the invite that brought them in.
  static const String _referralInviterDeviceIdKey = 'referral_inviter_device_id';
  static const String _referralInfluencerCodeKey = 'referral_influencer_code';
  static const String _referralTimestampKey = 'referral_timestamp';

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

  /// Store referral attribution context captured from an install link.
  /// [inviterDeviceId] is the device id embedded in the link (influencer's Vant
  /// account for influencer links, or a referred user for chat invites).
  /// [influencerCode] is only present for influencer referral links.
  Future<void> storeReferralContext({
    required String inviterDeviceId,
    String? influencerCode,
  }) async {
    try {
      // Do not overwrite an existing, still-valid referral context. Attribution
      // must never be retroactive or reassigned once captured.
      if (getReferralInviterDeviceId() != null) {
        debugPrint('📋 Referral context already present, not overwriting');
        return;
      }
      await _prefs.setString(_referralInviterDeviceIdKey, inviterDeviceId);
      if (influencerCode != null && influencerCode.isNotEmpty) {
        await _prefs.setString(_referralInfluencerCodeKey, influencerCode);
      }
      await _prefs.setInt(
          _referralTimestampKey, DateTime.now().millisecondsSinceEpoch);
      debugPrint(
        '📋 Stored referral context (inviter: $inviterDeviceId, code: ${influencerCode ?? "none"})',
      );
    } catch (e) {
      debugPrint('❌ Error storing referral context: $e');
    }
  }

  /// Get the stored referral inviter device id, or null if none / expired.
  String? getReferralInviterDeviceId() {
    try {
      final inviter = _prefs.getString(_referralInviterDeviceIdKey);
      if (inviter == null) return null;
      final timestamp = _prefs.getInt(_referralTimestampKey) ??
          DateTime.now().millisecondsSinceEpoch;
      final captured = DateTime.fromMillisecondsSinceEpoch(timestamp);
      // Referral context is valid for 30 days after install.
      if (DateTime.now().difference(captured).inDays >= 30) {
        clearReferralContext();
        return null;
      }
      return inviter;
    } catch (e) {
      debugPrint('❌ Error reading referral inviter: $e');
      return null;
    }
  }

  /// Get the stored influencer referral code, or null if none.
  String? getReferralInfluencerCode() {
    return _prefs.getString(_referralInfluencerCodeKey);
  }

  /// Clear referral context after it has been claimed (one-time use).
  Future<void> clearReferralContext() async {
    try {
      await _prefs.remove(_referralInviterDeviceIdKey);
      await _prefs.remove(_referralInfluencerCodeKey);
      await _prefs.remove(_referralTimestampKey);
      debugPrint('📋 Cleared referral context');
    } catch (e) {
      debugPrint('❌ Error clearing referral context: $e');
    }
  }

}
