import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../routes/app_routes.dart';

class NotificationPermissionScreen extends StatefulWidget {
  const NotificationPermissionScreen({super.key});

  @override
  State<NotificationPermissionScreen> createState() =>
      _NotificationPermissionScreenState();
}

class _NotificationPermissionScreenState
    extends State<NotificationPermissionScreen> with WidgetsBindingObserver {
  bool _isRequesting = false;
  bool _isPermanentlyDenied = false;
  bool _needsBatteryOptimization = false;
  bool _isSamsungDevice = false;

  static const MethodChannel _batteryChannel =
      MethodChannel('com.pear.messaging/battery');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkCurrentStatus();
    _checkBatteryOptimization();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When user returns from settings, check permission again
    if (state == AppLifecycleState.resumed) {
      _checkCurrentStatus();
      _checkBatteryOptimization();
    }
  }

  Future<void> _checkBatteryOptimization() async {
    if (!Platform.isAndroid) return;

    // Check if device is Samsung
    final deviceInfo = await _getDeviceManufacturer();
    _isSamsungDevice = deviceInfo.toLowerCase().contains('samsung');

    if (!_isSamsungDevice) return;

    try {
      final isIgnoring =
          await _batteryChannel.invokeMethod('isIgnoringBatteryOptimizations');
      setState(() {
        _needsBatteryOptimization = !(isIgnoring as bool);
      });
    } catch (e) {
      print('Error checking battery optimization: $e');
    }
  }

  Future<String> _getDeviceManufacturer() async {
    try {
      return await _batteryChannel.invokeMethod('getDeviceManufacturer') ?? '';
    } catch (e) {
      return '';
    }
  }

  Future<void> _checkCurrentStatus() async {
    if (!Platform.isAndroid) {
      // iOS handles permissions differently, proceed
      _proceedToNextScreen();
      return;
    }

    final status = await Permission.notification.status;
    print('📱 Notification permission status: $status');

    if (status.isGranted) {
      _proceedToNextScreen();
    } else if (status.isPermanentlyDenied) {
      setState(() {
        _isPermanentlyDenied = true;
      });
    }
  }

  Future<void> _requestPermission() async {
    if (_isRequesting) return;

    setState(() {
      _isRequesting = true;
    });

    try {
      final status = await Permission.notification.request();
      print('📱 Notification permission result: $status');

      if (status.isGranted) {
        // For Samsung devices, also request battery optimization exemption
        if (_isSamsungDevice && _needsBatteryOptimization) {
          await _requestBatteryOptimizationExemption();
        } else {
          _proceedToNextScreen();
        }
      } else if (status.isPermanentlyDenied) {
        setState(() {
          _isPermanentlyDenied = true;
        });
      }
    } finally {
      setState(() {
        _isRequesting = false;
      });
    }
  }

  Future<void> _requestBatteryOptimizationExemption() async {
    try {
      await _batteryChannel.invokeMethod('requestIgnoreBatteryOptimizations');
      // After user returns from settings, check again
      await Future.delayed(const Duration(seconds: 1));
      await _checkBatteryOptimization();
      if (!_needsBatteryOptimization) {
        _proceedToNextScreen();
      }
    } catch (e) {
      print('Error requesting battery optimization exemption: $e');
      // Proceed anyway
      _proceedToNextScreen();
    }
  }

  Future<void> _openSettings() async {
    await openAppSettings();
  }

  void _proceedToNextScreen() {
    // Navigate to splash screen to continue normal app flow
    Get.offAllNamed(AppRoutes.splash);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              // Notification icon
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.notifications_active,
                  size: 60,
                  color: Colors.blue.shade600,
                ),
              ),
              const SizedBox(height: 32),
              // Title
              Text(
                'Enable Notifications',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade800,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              // Description
              Text(
                'To receive messages from your contacts, please enable push notifications. This is required for the app to work properly.',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey.shade600,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              // Why it's important
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.amber.shade700),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Without notifications, you won\'t know when someone sends you a message.',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.amber.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Samsung battery optimization warning
              if (_isSamsungDevice && _needsBatteryOptimization) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: Colors.red.shade700),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Samsung Device Detected',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.red.shade900,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'To receive notifications when the app is closed, you must disable battery optimization for this app. Samsung devices restrict background notifications by default.',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.red.shade900,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const Spacer(),
              // Button
              if (_isPermanentlyDenied) ...[
                Text(
                  'Notification permission was denied. Please enable it from app settings.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.red.shade600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: _openSettings,
                    icon: const Icon(Icons.settings),
                    label: const Text(
                      'Open Settings',
                      style: TextStyle(fontSize: 18),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade600,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _isRequesting ? null : _requestPermission,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade600,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isRequesting
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : Text(
                            _isSamsungDevice && _needsBatteryOptimization
                                ? 'Allow Notifications & Disable Battery Optimization'
                                : 'Allow Notifications',
                            style: const TextStyle(fontSize: 18),
                            textAlign: TextAlign.center,
                          ),
                  ),
                ),
                // Additional button for Samsung devices to manually open battery settings
                if (_isSamsungDevice && _needsBatteryOptimization) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await _batteryChannel
                            .invokeMethod('openBatterySettings');
                      },
                      icon: const Icon(Icons.battery_saver),
                      label: const Text(
                        'Open Battery Settings',
                        style: TextStyle(fontSize: 16),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.blue.shade600,
                        side: BorderSide(color: Colors.blue.shade600),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
