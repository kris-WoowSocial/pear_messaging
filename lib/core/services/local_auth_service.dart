import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:local_auth/local_auth.dart';
import '../constants/app_strings.dart';

class LocalAuthService extends GetxService {
  final LocalAuthentication _localAuth = LocalAuthentication();
  
  Future<bool> authenticate() async {
    try {
      // Check if device supports biometric authentication
      final bool canCheckBiometrics = await _localAuth.canCheckBiometrics;
      final bool isDeviceSupported = await _localAuth.isDeviceSupported();
      
      if (!canCheckBiometrics || !isDeviceSupported) {
        return false;
      }
      
      // Get available biometrics
      final List<BiometricType> availableBiometrics = 
          await _localAuth.getAvailableBiometrics();
      
      if (availableBiometrics.isEmpty) {
        return false;
      }
      
      // Authenticate
      final bool authenticated = await _localAuth.authenticate(
        localizedReason: AppStrings.authReason,
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
      
      return authenticated;
    } catch (e) {
      debugPrint('Authentication error: $e');
      return false;
    }
  }
  
  Future<bool> isAvailable() async {
    try {
      final bool canCheckBiometrics = await _localAuth.canCheckBiometrics;
      final bool isDeviceSupported = await _localAuth.isDeviceSupported();
      return canCheckBiometrics && isDeviceSupported;
    } catch (e) {
      return false;
    }
  }
  
  Future<void> stopAuthentication() async {
    await _localAuth.stopAuthentication();
  }
}
