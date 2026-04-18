import 'dart:io';

import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkCurrentStatus();
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
        _proceedToNextScreen();
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
                        : const Text(
                            'Allow Notifications',
                            style: TextStyle(fontSize: 18),
                          ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
