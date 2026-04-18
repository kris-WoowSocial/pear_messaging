import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pear_messaging/core/services/local_storage_service.dart';
import 'package:pear_messaging/core/services/report_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/rating_dialog.dart';

class ReviewService extends GetxService {
  static const String _hasReviewedKey = 'has_reviewed_app';
  static const String _installDateKey = 'app_install_date';
  static const String _lastShownKey = 'review_last_shown';
  static const String _lastCancelledKey = 'review_last_cancelled';
  static const int _delayDays = 2;

  late SharedPreferences _prefs;

  final RxBool hasReviewed = false.obs;
  final RxInt daysInstalled = 0.obs;

  /// Initialize the service
  Future<ReviewService> init() async {
    _prefs = await SharedPreferences.getInstance();

    // Load review status
    hasReviewed.value = _prefs.getBool(_hasReviewedKey) ?? false;

    // Set install date if not set
    if (!_prefs.containsKey(_installDateKey)) {
      await _prefs.setInt(
          _installDateKey, DateTime.now().millisecondsSinceEpoch);
    }

    // Calculate days since install
    final installDate =
        _prefs.getInt(_installDateKey) ?? DateTime.now().millisecondsSinceEpoch;
    final daysSince = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(installDate))
        .inDays;
    daysInstalled.value = daysSince;

    print(
        '✅ ReviewService initialized - hasReviewed: ${hasReviewed.value}, daysInstalled: $daysSince');

    return this;
  }

  /// Check if user has already reviewed
  bool hasUserReviewed() {
    return hasReviewed.value;
  }

  /// Reset review status (for testing purposes)
  Future<void> resetReviewStatus() async {
    try {
      await _prefs.remove(_hasReviewedKey);
      await _prefs.remove(_lastCancelledKey);
      hasReviewed.value = false;
      print('✅ Review status reset - user can review again');
    } catch (e) {
      print('❌ Error resetting review status: $e');
    }
  }

  /// Check if review should be shown automatically
  /// Returns true if: 2+ days since install OR 2+ days since last cancel AND not reviewed yet
  bool shouldShowReview() {
    // If already reviewed, never show again
    if (hasReviewed.value) {
      return false;
    }

    final now = DateTime.now();

    // Check if user has cancelled before
    final lastCancelledTimestamp = _prefs.getInt(_lastCancelledKey);

    if (lastCancelledTimestamp != null) {
      // User has cancelled before - check if 2 days have passed since cancellation
      final lastCancelled =
          DateTime.fromMillisecondsSinceEpoch(lastCancelledTimestamp);
      final daysSinceCancelled = now.difference(lastCancelled).inDays;
      return daysSinceCancelled >= _delayDays;
    } else {
      // First time - check if 2 days have passed since install
      final installDate =
          _prefs.getInt(_installDateKey) ?? now.millisecondsSinceEpoch;
      final installDateTime = DateTime.fromMillisecondsSinceEpoch(installDate);
      final daysSinceInstall = now.difference(installDateTime).inDays;
      return daysSinceInstall >= _delayDays;
    }
  }

  /// Request review - show custom rating dialog
  Future<void> requestReview() async {
    // Check if already reviewed
    // if (hasReviewed.value) {
    //   Get.snackbar(
    //     'Thank You',
    //     'You have already submitted your feedback.',
    //     snackPosition: SnackPosition.BOTTOM,
    //   );
    //   return;
    // }

    // Show custom rating dialog
    final result = await Get.dialog(
      RatingDialog(
        onRatingSubmitted: (int stars, String? feedback) async {
          // Always allow users to rate on the store regardless of star rating
          await triggerGoogleReview();

          // Also submit feedback if provided
          if (feedback != null && feedback.isNotEmpty) {
            await submitFeedback(stars, feedback);
          }
        },
        onCancelled: () async {
          // User cancelled - save timestamp for 2-day delay
          await markAsCancelled();
        },
      ),
      barrierDismissible: true,
    );

    // If dialog was dismissed without action (barrierDismissible), also mark as cancelled
    if (result == null) {
      await markAsCancelled();
    }
  }

  /// Trigger App Store review - detects platform and opens correct store
  Future<void> triggerGoogleReview() async {
    try {
      print('🔄 Opening app store for review...');

      // Show loading feedback
      Get.snackbar(
        'Opening Store',
        'Taking you to the store to rate our app...',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
        backgroundColor: Colors.blue.shade100,
        colorText: Colors.blue.shade800,
        showProgressIndicator: true,
      );

      // Open correct store based on platform
      if (GetPlatform.isIOS) {
        await _openAppStoreListing();
      } else {
        await _openPlayStoreListing();
      }

      // Wait for store to open
      await Future.delayed(const Duration(seconds: 2));

      // Show final message
      Get.snackbar(
        'Store Opened',
        'Please rate us on the store page to help improve our app!',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.green.shade100,
        colorText: Colors.green.shade800,
      );

      // Mark as reviewed after a delay (gives user time to actually rate)
      print('⏳ Store opened - will mark as reviewed after delay');
      Future.delayed(const Duration(minutes: 5), () async {
        try {
          await markAsReviewed();
          print('✅ Marked as reviewed after delay');
        } catch (e) {
          print('⚠️ Error marking as reviewed after delay: $e');
        }
      });
    } catch (e) {
      print('❌ Error opening store: $e');
      Get.snackbar(
        'Error',
        'Could not open store. Please try again later.',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
    }
  }

  /// Open App Store listing directly using url_launcher
  Future<void> _openAppStoreListing() async {
    try {
      const String appId = '6478718953'; // Your App Store ID
      final Uri url = Uri.parse(
        'https://apps.apple.com/app/id$appId?action=write-review',
      );

      if (await canLaunchUrl(url)) {
        print('🚀 Opening App Store URL: $url');
        await launchUrl(
          url,
          mode: LaunchMode.externalApplication,
        );
        print('✅ App Store opened successfully');
      } else {
        print('❌ Cannot launch App Store URL');
        // Try generic App Store URL
        final genericUrl = Uri.parse('https://apps.apple.com/app/id$appId');
        if (await canLaunchUrl(genericUrl)) {
          print('🚀 Opening generic App Store URL: $genericUrl');
          await launchUrl(
            genericUrl,
            mode: LaunchMode.externalApplication,
          );
          print('✅ Generic App Store opened successfully');
        } else {
          print('❌ Cannot launch App Store URL either');
        }
      }
    } catch (e) {
      print('❌ Error opening App Store: $e');
      rethrow;
    }
  }

  /// Open Play Store listing directly using url_launcher
  Future<void> _openPlayStoreListing() async {
    try {
      const String appId = 'com.vant.chat';
      final Uri url = Uri.parse(
        'https://play.google.com/store/apps/details?id=$appId',
      );

      if (await canLaunchUrl(url)) {
        print('🚀 Opening Play Store URL: $url');
        await launchUrl(
          url,
          mode: LaunchMode.externalApplication,
        );
        print('✅ Play Store opened successfully');
      } else {
        print('❌ Cannot launch Play Store URL');
        // Try market:// fallback
        final marketUrl = Uri.parse('market://details?id=$appId');
        if (await canLaunchUrl(marketUrl)) {
          print('🚀 Opening market URL: $marketUrl');
          await launchUrl(
            marketUrl,
            mode: LaunchMode.externalApplication,
          );
          print('✅ Market opened successfully');
        } else {
          print('❌ Cannot launch market URL either');
        }
      }
    } catch (e) {
      print('❌ Error opening Play Store: $e');
      rethrow;
    }
  }

  /// Submit feedback to contact API (for 1-3 star ratings)
  Future<void> submitFeedback(int stars, String feedback) async {
    try {
      print('📝 Submitting feedback: $stars stars');

      final reportService = Get.find<ReportService>();
      final storageService = Get.find<LocalStorageService>();
      final deviceId = storageService.deviceId ?? 'unknown';

      // Format message with rating and feedback
      final message =
          'Rating: $stars stars\n\n Feedback: ${feedback.isNotEmpty ? feedback : 'No additional feedback provided.'}';

      // Submit to contact API
      final success = await reportService.submitContactMessage(
        name: deviceId,
        email: '$deviceId@vantcomplaints.com',
        message: message,
      );

      if (success) {
        print('✅ Feedback submitted successfully');

        // Mark as reviewed
        await markAsReviewed();

        // Show success message
        Get.snackbar(
          'Thank You',
          'Your feedback has been submitted. We appreciate your input!',
          snackPosition: SnackPosition.BOTTOM,
        );
      } else {
        print('❌ Failed to submit feedback');
        Get.snackbar(
          'Error',
          'Failed to submit feedback. Please try again later.',
          snackPosition: SnackPosition.BOTTOM,
        );
      }
    } catch (e) {
      print('❌ Error submitting feedback: $e');
      Get.snackbar(
        'Error',
        'An error occurred. Please try again later.',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  /// Mark as reviewed - save to SharedPreferences
  Future<void> markAsReviewed() async {
    await _prefs.setBool(_hasReviewedKey, true);
    hasReviewed.value = true;
    print('✅ Marked as reviewed');
  }

  /// Update last shown timestamp (for cooldown tracking)
  Future<void> updateLastShown() async {
    await _prefs.setInt(_lastShownKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// Mark as cancelled - save timestamp for 2-day delay
  Future<void> markAsCancelled() async {
    await _prefs.setInt(
        _lastCancelledKey, DateTime.now().millisecondsSinceEpoch);
    print('⏰ Review cancelled - will show again in $_delayDays days');
  }
}
