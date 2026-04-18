// import 'dart:io';
// import 'package:flutter/material.dart';
// import 'package:get/get.dart';
// import 'package:in_app_update/in_app_update.dart';
// import 'package:shared_preferences/shared_preferences.dart';
// import 'package:flutter/services.dart';

// class AppUpdateService extends GetxService {
//   static const String _currentVersion = '1.1.0';
//   static const String _forceUpdateKey = 'force_update_completed';

//   // Server-side version that will trigger force update
//   // You should update this when you release new versions
//   static const String _minimumRequiredVersion = '1.1.0';

//   /// Initialize the service
//   Future<AppUpdateService> init() async {
//     // Check for updates on app startup
//     await checkForUpdates();

//     return this;
//   }

//   final RxBool isCheckingForUpdate = false.obs;
//   final RxBool updateAvailable = false.obs;
//   final RxBool isForceUpdate = false.obs;
//   final RxString updateMessage = ''.obs;
//   final RxBool needsFreshRestart = false.obs;

//   /// Check if force update was just completed
//   Future<void> _checkForceUpdateStatus() async {
//     try {
//       final prefs = await SharedPreferences.getInstance();
//       final forceUpdateCompleted = prefs.getBool(_forceUpdateKey) ?? false;

//       if (forceUpdateCompleted) {
//         debugPrint(' Force update completed, triggering fresh restart...');
//         needsFreshRestart.value = true;

//         // Clear the flag IMMEDIATELY to prevent multiple triggers
//         await prefs.remove(_forceUpdateKey);

//         // Add a guard to prevent multiple restarts
//         final lastRestartTime = prefs.getInt('last_restart_time') ?? 0;
//         final currentTime = DateTime.now().millisecondsSinceEpoch;

//         // Only restart if it's been more than 10 seconds since last restart
//         if (currentTime - lastRestartTime > 10000) {
//           // Record this restart time
//           await prefs.setInt('last_restart_time', currentTime);

//           // Trigger fresh restart after a short delay
//           Future.delayed(const Duration(milliseconds: 1000), () {
//             _performFreshRestart();
//           });
//         } else {
//           debugPrint(' Restart already attempted recently, skipping...');
//         }
//       }
//     } catch (e) {
//       debugPrint(' Error checking force update status: $e');
//     }
//   }

//   /// Check for app updates on startup
//   Future<void> checkForUpdates({bool showNoUpdateDialog = false}) async {
//     try {
//       isCheckingForUpdate.value = true;

//       // For Play Store, we'll use a simple version comparison
//       // In production, you might want to fetch this from your server
//       await _checkPlayStoreUpdate();
//     } catch (e) {
//       debugPrint('❌ Error checking for updates: $e');
//     } finally {
//       isCheckingForUpdate.value = false;
//     }
//   }

//   /// Check Play Store for updates
//   Future<void> _checkPlayStoreUpdate() async {
//     try {
//       final appInfo = await InAppUpdate.checkForUpdate();

//       if (appInfo.updateAvailability == UpdateAvailability.updateAvailable) {
//         debugPrint('🔄 Update available - showing custom update dialog');
//         updateAvailable.value = true;
//         isForceUpdate.value = true;

//         // Show custom update dialog instead of immediate update
//         _showCustomUpdateDialog();
//       } else if (appInfo.updateAvailability ==
//           UpdateAvailability.updateNotAvailable) {
//         debugPrint('✅ App is up to date');
//         updateAvailable.value = false;
//       }
//     } catch (e) {
//       debugPrint('❌ Error checking Play Store update: $e');
//     }
//   }

//   /// Show custom update dialog
//   void _showCustomUpdateDialog() {
//     Get.dialog(
//       WillPopScope(
//         onWillPop: () async => false, // Prevent dialog dismissal
//         child: AlertDialog(
//           title: Row(
//             children: [
//               Icon(Icons.system_update, color: Colors.blue, size: 28),
//               SizedBox(width: 12),
//               Text('Update Required'),
//             ],
//           ),
//           content: Column(
//             mainAxisSize: MainAxisSize.min,
//             crossAxisAlignment: CrossAxisAlignment.start,
//             children: [
//               Text(
//                 'A new version of the app is available!',
//                 style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
//               ),
//               SizedBox(height: 8),
//               Text(
//                 'Please update to the latest version to continue using the app. This update includes important improvements and bug fixes.',
//                 style: TextStyle(fontSize: 14, color: Colors.grey[600]),
//               ),
//               SizedBox(height: 16),
//               Container(
//                 padding: EdgeInsets.all(12),
//                 decoration: BoxDecoration(
//                   color: Colors.blue[50],
//                   borderRadius: BorderRadius.circular(8),
//                 ),
//                 child: Row(
//                   children: [
//                     Icon(Icons.info_outline, color: Colors.blue, size: 20),
//                     SizedBox(width: 8),
//                     Expanded(
//                       child: Text(
//                         'Tap "Update Now" to go to Play Store and update the app.',
//                         style: TextStyle(fontSize: 12, color: Colors.blue[700]),
//                       ),
//                     ),
//                   ],
//                 ),
//               ),
//             ],
//           ),
//           actions: [
//             ElevatedButton.icon(
//               onPressed: () {
//                 Get.back(); // Close dialog
//                 _openPlayStoreForUpdate();
//               },
//               icon: Icon(Icons.system_update_alt),
//               label: Text('Update Now'),
//               style: ElevatedButton.styleFrom(
//                 backgroundColor: Colors.blue,
//                 foregroundColor: Colors.white,
//                 padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
//               ),
//             ),
//           ],
//         ),
//       ),
//       barrierDismissible: false,
//     );
//   }

//   /// Open Play Store for update
//   Future<void> _openPlayStoreForUpdate() async {
//     try {
//       const String appId = 'com.vant.chat';
//       final Uri url = Uri.parse(
//         'https://play.google.com/store/apps/details?id=$appId',
//       );

//       debugPrint('🔄 Opening Play Store for update...');

//       if (await canLaunchUrl(url)) {
//         await launchUrl(url, mode: LaunchMode.externalApplication);
//         debugPrint('✅ Play Store opened successfully');
//       } else {
//         debugPrint('❌ Could not open Play Store');
//         Get.snackbar(
//           'Error',
//           'Could not open Play Store. Please try again.',
//           backgroundColor: Colors.red[100],
//           colorText: Colors.red[800],
//         );
//       }
//     } catch (e) {
//       debugPrint('❌ Error opening Play Store: $e');
//       Get.snackbar(
//         'Error',
//         'Could not open Play Store. Please try again.',
//         backgroundColor: Colors.red[100],
//         colorText: Colors.red[800],
//       );
//     }
//   }

//   /// Check for updates immediately (for manual refresh)
//   Future<void> checkForUpdatesNow() async {
//     await checkForUpdates(showNoUpdateDialog: true);
//   }

//   /// Get current app version
//   String get currentVersion => _currentVersion;

//   /// Get minimum required version
//   String get minimumRequiredVersion => _minimumRequiredVersion;
// }
