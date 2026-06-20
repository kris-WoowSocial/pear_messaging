import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:package_info_plus/package_info_plus.dart';
import '../constants/app_colors.dart';
import '../constants/network_constants.dart';
import 'dart:math' as math;

class AppUpdateService extends GetxService {
  String _currentVersion = '1.6.1';
  final String _minimumRequiredVersion = '1.6.1';
  PackageInfo? _packageInfo;

  /// Initialize the service
  Future<AppUpdateService> init() async {
    // Get actual installed version
    await _loadPackageInfo();

    // Check for updates on app startup
    await checkForUpdates();

    return this;
  }

  /// Load package info to get actual installed version
  Future<void> _loadPackageInfo() async {
    try {
      _packageInfo = await PackageInfo.fromPlatform();
      _currentVersion = _packageInfo!.version;
      debugPrint('📱 Installed version: $_currentVersion');
    } catch (e) {
      debugPrint('❌ Error loading package info: $e');
    }
  }

  final RxBool isCheckingForUpdate = false.obs;
  final RxBool updateAvailable = false.obs;
  final RxBool isForceUpdate = false.obs;
  final RxString updateMessage = ''.obs;

  /// Check for app updates on startup
  Future<void> checkForUpdates({bool showNoUpdateDialog = false}) async {
    try {
      isCheckingForUpdate.value = true;

      // Platform-specific update check
      if (Platform.isAndroid) {
        await _checkPlayStoreUpdate();
      } else if (Platform.isIOS) {
        await _checkAppStoreUpdate();
      }
    } catch (e) {
      debugPrint('❌ Error checking for updates: $e');
    } finally {
      isCheckingForUpdate.value = false;
    }
  }

  /// Check Play Store for updates
  Future<void> _checkPlayStoreUpdate() async {
    try {
      final appInfo = await InAppUpdate.checkForUpdate();

      if (appInfo.updateAvailability == UpdateAvailability.updateAvailable) {
        debugPrint('🔄 Update available - showing custom update dialog');
        updateAvailable.value = true;
        isForceUpdate.value = true;

        // Show custom update dialog instead of immediate update
        _showCustomUpdateDialog();
      } else if (appInfo.updateAvailability ==
          UpdateAvailability.updateNotAvailable) {
        debugPrint('✅ App is up to date');
        updateAvailable.value = false;
      }
    } catch (e) {
      debugPrint('❌ Error checking Play Store update: $e');
    }
  }

  /// Check App Store for updates (iOS)
  Future<void> _checkAppStoreUpdate() async {
    try {
      // Get bundle ID from package info
      final bundleId = _packageInfo?.packageName ?? 'com.vant.chat';
      final String url =
          '${NetworkConstants.appStoreLookupUrl}?bundleId=$bundleId&country=US';

      debugPrint('🔍 Checking App Store for bundle ID: $bundleId');

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data['resultCount'] > 0) {
          final storeVersion = data['results'][0]['version'];
          final storeVersionCode = _versionToNumber(storeVersion);
          final currentVersionCode = _versionToNumber(_currentVersion);

          debugPrint('📱 App Store version: $storeVersion ($storeVersionCode)');
          debugPrint(
            '📱 Current version: $_currentVersion ($currentVersionCode)',
          );

          if (storeVersionCode > currentVersionCode) {
            debugPrint('🔄 Update available on App Store');
            updateAvailable.value = true;
            isForceUpdate.value = true;
            _showCustomUpdateDialog();
          } else {
            debugPrint('✅ App is up to date');
            updateAvailable.value = false;
          }
        } else {
          debugPrint('⚠️ No results found for bundle ID: $bundleId');
        }
      }
    } catch (e) {
      debugPrint('❌ Error checking App Store update: $e');
    }
  }

  /// Convert version string to number for comparison (e.g., "1.2.3" -> 10203)
  int _versionToNumber(String version) {
    final parts = version.split('.');
    int result = 0;
    for (int i = 0; i < parts.length && i < 3; i++) {
      result += int.parse(parts[i]) * math.pow(100, 2 - i).toInt();
    }
    return result;
  }

  /// Show custom update dialog (eye-catching with animations)
  void _showCustomUpdateDialog() {
    Get.dialog(
      WillPopScope(
        onWillPop: () async => false, // Prevent dialog dismissal
        child: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.primary,
                AppColors.primaryDark,
                AppColors.primaryLight,
              ],
            ),
          ),
          child: Stack(
            children: [
              // Animated bubbles background
              _buildAnimatedBubble(100, 100, 60, Colors.white.withOpacity(0.1)),
              _buildAnimatedBubble(
                300,
                200,
                40,
                Colors.white.withOpacity(0.08),
              ),
              _buildAnimatedBubble(50, 400, 80, Colors.white.withOpacity(0.06)),
              _buildAnimatedBubble(
                250,
                500,
                50,
                Colors.white.withOpacity(0.09),
              ),
              _buildAnimatedBubble(
                350,
                350,
                70,
                Colors.white.withOpacity(0.07),
              ),

              SafeArea(
                child: Column(
                  children: [
                    // Header section with animations
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 32,
                      ),
                      child: Column(
                        children: [
                          TweenAnimationBuilder(
                            duration: Duration(milliseconds: 800),
                            tween: Tween<double>(begin: 0, end: 1),
                            builder: (context, double value, child) {
                              return Transform.scale(
                                scale: value,
                                child: Container(
                                  padding: EdgeInsets.all(20),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        Colors.white.withOpacity(0.2),
                                        Colors.white.withOpacity(0.1),
                                      ],
                                    ),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.4),
                                      width: 2,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.white.withOpacity(0.2),
                                        blurRadius: 20,
                                        spreadRadius: 5,
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    Icons.system_update_alt,
                                    color: Colors.white,
                                    size: 56,
                                  ),
                                ),
                              );
                            },
                          ),
                          SizedBox(height: 20),
                          TweenAnimationBuilder(
                            duration: Duration(milliseconds: 1000),
                            tween: Tween<double>(begin: -50, end: 0),
                            builder: (context, double value, child) {
                              return Transform.translate(
                                offset: Offset(0, value),
                                child: Text(
                                  'Update Available',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                    decoration: TextDecoration.none,
                                    shadows: [
                                      Shadow(
                                        color: Colors.black.withOpacity(0.3),
                                        blurRadius: 10,
                                        offset: Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),

                    // Content section with slide-up animation
                    Expanded(
                      child: TweenAnimationBuilder(
                        duration: Duration(milliseconds: 1200),
                        tween: Tween<double>(begin: 100, end: 0),
                        builder: (context, double value, child) {
                          return Transform.translate(
                            offset: Offset(0, value),
                            child: Container(
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.only(
                                  topLeft: Radius.circular(32),
                                  topRight: Radius.circular(32),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.1),
                                    blurRadius: 30,
                                    offset: Offset(0, -10),
                                  ),
                                ],
                              ),
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    SizedBox(height: 20),

                                    // Pulsing title
                                    TweenAnimationBuilder(
                                      duration: Duration(milliseconds: 1500),
                                      tween: Tween<double>(
                                        begin: 0.8,
                                        end: 1.0,
                                      ),
                                      builder: (context, double value, child) {
                                        return Transform.scale(
                                          scale: value,
                                          child: Text(
                                            '🚀 Time to Update!',
                                            style: TextStyle(
                                              fontSize: 26,
                                              fontWeight: FontWeight.bold,
                                              color: AppColors.textPrimary,
                                              height: 1.2,
                                              decoration: TextDecoration.none,
                                            ),
                                            textAlign: TextAlign.center,
                                          ),
                                        );
                                      },
                                    ),

                                    SizedBox(height: 16),

                                    Text(
                                      'Experience the best with new features\nand performance improvements',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: AppColors.textSecondary,
                                        height: 1.4,
                                        decoration: TextDecoration.none,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),

                                    SizedBox(height: 32),

                                    // Animated feature items
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _buildAnimatedFeatureItem(
                                            icon: Icons.speed,
                                            title: 'Lightning Fast',
                                            subtitle: '2x Performance',
                                            color: AppColors.primary,
                                            delay: 200,
                                          ),
                                        ),
                                        SizedBox(width: 16),
                                        Expanded(
                                          child: _buildAnimatedFeatureItem(
                                            icon: Icons.security,
                                            title: 'Ultra Secure',
                                            subtitle: 'Enhanced Protection',
                                            color: AppColors.primaryDark,
                                            delay: 400,
                                          ),
                                        ),
                                      ],
                                    ),

                                    SizedBox(height: 16),

                                    Row(
                                      children: [
                                        Expanded(
                                          child: _buildAnimatedFeatureItem(
                                            icon: Icons.bug_report,
                                            title: 'Bug Free',
                                            subtitle: 'All Issues Fixed',
                                            color: AppColors.success,
                                            delay: 600,
                                          ),
                                        ),
                                        SizedBox(width: 16),
                                        Expanded(
                                          child: _buildAnimatedFeatureItem(
                                            icon: Icons.auto_awesome,
                                            title: 'Brand New',
                                            subtitle: 'Amazing Features',
                                            color: AppColors.info,
                                            delay: 800,
                                          ),
                                        ),
                                      ],
                                    ),

                                    Spacer(),

                                    // Animated update button
                                    TweenAnimationBuilder(
                                      duration: Duration(milliseconds: 1800),
                                      tween: Tween<double>(begin: 0, end: 1),
                                      builder: (context, double value, child) {
                                        return Transform.scale(
                                          scale: 0.8 + (0.2 * value),
                                          child: Container(
                                            width: double.infinity,
                                            height: 64,
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                                colors: [
                                                  AppColors.primary,
                                                  AppColors.primaryDark,
                                                ],
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: AppColors.primary
                                                      .withOpacity(0.4),
                                                  blurRadius: 20 * value,
                                                  offset: Offset(0, 8),
                                                ),
                                              ],
                                            ),
                                            child: Material(
                                              color: Colors.transparent,
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                onTap: () {
                                                  Get.back(); // Close dialog
                                                  _openStoreForUpdate();
                                                },
                                                child: Center(
                                                  child: Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      Icon(
                                                        Icons.download_rounded,
                                                        color: Colors.white,
                                                        size: 24,
                                                      ),
                                                      SizedBox(width: 12),
                                                      Text(
                                                        'Update Now',
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 20,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          letterSpacing: 0.5,
                                                          decoration:
                                                              TextDecoration
                                                                  .none,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      barrierDismissible: false,
    );
  }

  /// Build animated bubble
  Widget _buildAnimatedBubble(
    double left,
    double top,
    double size,
    Color color,
  ) {
    return Positioned(
      left: left,
      top: top,
      child: TweenAnimationBuilder(
        duration: Duration(milliseconds: 3000),
        tween: Tween<double>(begin: 0, end: 2 * 3.14159),
        builder: (context, double value, child) {
          return Transform.translate(
            offset: Offset(20 * math.sin(value), 20 * math.cos(value)),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          );
        },
      ),
    );
  }

  /// Build animated feature item
  Widget _buildAnimatedFeatureItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required int delay,
  }) {
    return TweenAnimationBuilder(
      duration: Duration(milliseconds: 600 + delay),
      tween: Tween<double>(begin: 0, end: 1),
      builder: (context, double value, child) {
        return Transform.scale(
          scale: value,
          child: Transform.rotate(
            angle: (1 - value) * 0.2,
            child: Container(
              padding: EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.senderBubble,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: color.withValues(alpha: 0.2),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.1 * value),
                    blurRadius: 10,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Container(
                    padding: EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: color, size: 28),
                  ),
                  SizedBox(height: 8),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                      decoration: TextDecoration.none,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.none,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Open app store for update (Play Store or App Store)
  Future<void> _openStoreForUpdate() async {
    try {
      Uri url;

      if (Platform.isAndroid) {
        final bundleId = _packageInfo?.packageName ?? 'com.vant.chat';
        url = Uri.parse('${NetworkConstants.playStoreUrl}?id=$bundleId');
        debugPrint('🔄 Opening Play Store for update...');
      } else if (Platform.isIOS) {
        final bundleId = _packageInfo?.packageName ?? 'com.vant.chat';
        url = Uri.parse(
            '${NetworkConstants.appStoreReviewUrl}?bundleId=$bundleId');
        debugPrint('🔄 Opening App Store for update...');
      } else {
        debugPrint('❌ Unsupported platform');
        return;
      }

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
        debugPrint('✅ Store opened successfully');
      } else {
        debugPrint('❌ Could not open store');
        Get.snackbar(
          'Error',
          'Could not open store. Please try again.',
          backgroundColor: Colors.red[100],
          colorText: Colors.red[800],
        );
      }
    } catch (e) {
      debugPrint('❌ Error opening store: $e');
      Get.snackbar(
        'Error',
        'Could not open store. Please try again.',
        backgroundColor: Colors.red[100],
        colorText: Colors.red[800],
      );
    }
  }

  /// Check for updates immediately (for manual refresh)
  Future<void> checkForUpdatesNow() async {
    await checkForUpdates(showNoUpdateDialog: true);
  }

  /// Get current app version
  String get currentVersion => _currentVersion;

  /// Get minimum required version
  String get minimumRequiredVersion => _minimumRequiredVersion;
}
