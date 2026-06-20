import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:proximity_sensor/proximity_sensor.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Service to handle proximity sensor during calls
/// Turns screen OFF when phone is near ear, ON when away
class ProximityService {
  static final ProximityService _instance = ProximityService._internal();
  factory ProximityService() => _instance;
  ProximityService._internal();

  StreamSubscription? _proximitySubscription;
  bool _isNear = false;
  bool _isActive = false;

  /// Start listening to proximity sensor
  void startListening() {
    if (_isActive) return;
    _isActive = true;

    debugPrint('📱 ProximityService: Started listening');

    // Enable wakelock to keep screen on initially
    WakelockPlus.enable();

    // Listen to proximity sensor events
    // proximity_sensor returns true when NEAR (phone to ear), false when FAR
    _proximitySubscription = ProximitySensor.events.listen((int event) {
      final isNear = event == 1; // 1 = near (phone at ear), 0 = far (away)
      _handleProximityChange(isNear);
    });
  }

  void _handleProximityChange(bool isNear) {
    if (isNear) {
      // Phone is near ear - turn screen OFF (black)
      if (!_isNear) {
        _isNear = true;
        WakelockPlus.disable(); // Allow screen to turn off
        debugPrint('📱 ProximityService: Phone near ear - Screen OFF');
      }
    } else {
      // Phone is away from ear - turn screen ON
      if (_isNear) {
        _isNear = false;
        WakelockPlus.enable(); // Keep screen on
        debugPrint('📱 ProximityService: Phone away from ear - Screen ON');
      }
    }
  }

  /// Stop listening to proximity sensor
  void stopListening() {
    _isActive = false;
    _proximitySubscription?.cancel();
    _proximitySubscription = null;

    // Disable wakelock - let screen turn off normally
    WakelockPlus.disable();

    debugPrint('📱 ProximityService: Stopped listening');
  }

  /// Manually turn screen off (when phone near ear)
  void turnScreenOff() {
    if (!_isNear) {
      _isNear = true;
      // Disable wakelock - allow screen to turn off
      WakelockPlus.disable();
      debugPrint('📱 ProximityService: Screen turned OFF (near ear)');
    }
  }

  /// Manually turn screen on (when phone away from ear)
  void turnScreenOn() {
    if (_isNear) {
      _isNear = false;
      // Enable wakelock - keep screen on
      WakelockPlus.enable();
      debugPrint('📱 ProximityService: Screen turned ON (away from ear)');
    }
  }

  bool get isNear => _isNear;
  bool get isActive => _isActive;
}
