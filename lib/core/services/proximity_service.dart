import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proximity_sensor/proximity_sensor.dart';

/// Service to handle proximity sensor during calls
/// Uses native PROXIMITY_SCREEN_OFF_WAKE_LOCK to turn screen OFF when phone is near ear
class ProximityService {
  static final ProximityService _instance = ProximityService._internal();
  factory ProximityService() => _instance;
  ProximityService._internal();

  static const MethodChannel _proximityChannel =
      MethodChannel('com.pear.messaging/proximity');

  StreamSubscription? _proximitySubscription;
  bool _isNear = false;
  bool _isActive = false;

  /// Start listening to proximity sensor
  Future<void> startListening() async {
    if (_isActive) return;
    _isActive = true;

    debugPrint('📱 ProximityService: Started listening');

    // Check device proximity sensor capabilities
    await _checkProximitySensor();

    // Acquire native proximity wake lock - automatically turns screen off when phone is near ear
    await _acquireProximityWakeLock();

    // Listen to proximity sensor events
    // proximity_sensor returns true when NEAR (phone to ear), false when FAR
    _proximitySubscription = ProximitySensor.events.listen(
      (int event) {
        debugPrint('📱 ProximityService: RAW sensor event = $event');
        final isNear = event == 1; // 1 = near (phone at ear), 0 = far (away)
        _handleProximityChange(isNear);
      },
      onError: (error) {
        debugPrint('⚠️ ProximityService: Sensor stream error: $error');
      },
    );
  }

  void _handleProximityChange(bool isNear) {
    if (isNear) {
      // Phone is near ear - native wake lock handles screen OFF automatically
      if (!_isNear) {
        _isNear = true;
        debugPrint(
          '📱 ProximityService: Phone near ear - Screen OFF (native wake lock + manual fallback)',
        );
        // Fallback: manually dim screen if native wake lock doesn't work on this device
        _turnScreenOff();
      }
    } else {
      // Phone is away from ear - screen turns ON automatically
      if (_isNear) {
        _isNear = false;
        debugPrint(
          '📱 ProximityService: Phone away from ear - Screen ON (native wake lock + manual fallback)',
        );
        // Fallback: manually restore screen brightness
        _turnScreenOn();
      }
    }
  }

  /// Stop listening to proximity sensor
  void stopListening() {
    _isActive = false;
    _proximitySubscription?.cancel();
    _proximitySubscription = null;

    // Release native proximity wake lock
    _releaseProximityWakeLock();

    debugPrint('📱 ProximityService: Stopped listening');
  }

  /// Manually turn screen off (when phone near ear)
  void turnScreenOff() {
    if (!_isNear) {
      _isNear = true;
      debugPrint('📱 ProximityService: Screen turned OFF (near ear)');
    }
  }

  /// Manually turn screen on (when phone away from ear)
  void turnScreenOn() {
    if (_isNear) {
      _isNear = false;
      debugPrint('📱 ProximityService: Screen turned ON (away from ear)');
    }
  }

  /// Native fallback: turn screen off by dimming to 0 brightness
  Future<void> _turnScreenOff() async {
    try {
      await _proximityChannel.invokeMethod('turnScreenOff');
      debugPrint('📱 ProximityService: Manual screen OFF invoked');
    } catch (e) {
      debugPrint('⚠️ Failed to manually turn screen off: $e');
    }
  }

  /// Native fallback: turn screen on by restoring brightness
  Future<void> _turnScreenOn() async {
    try {
      await _proximityChannel.invokeMethod('turnScreenOn');
      debugPrint('📱 ProximityService: Manual screen ON invoked');
    } catch (e) {
      debugPrint('⚠️ Failed to manually turn screen on: $e');
    }
  }

  /// Acquire native proximity wake lock
  Future<void> _acquireProximityWakeLock() async {
    try {
      await _proximityChannel.invokeMethod('acquireProximityWakeLock');
      debugPrint('📱 ProximityService: Native wake lock acquired');
    } catch (e) {
      debugPrint('⚠️ Failed to acquire proximity wake lock: $e');
    }
  }

  /// Release native proximity wake lock
  Future<void> _releaseProximityWakeLock() async {
    try {
      await _proximityChannel.invokeMethod('releaseProximityWakeLock');
      debugPrint('📱 ProximityService: Native wake lock released');
    } catch (e) {
      debugPrint('⚠️ Failed to release proximity wake lock: $e');
    }
  }

  /// Check device proximity sensor capabilities
  Future<void> _checkProximitySensor() async {
    try {
      final result = await _proximityChannel
          .invokeMethod<Map<dynamic, dynamic>>('checkProximitySensor');
      if (result != null) {
        debugPrint('📱 ProximityService: Device sensor info:');
        debugPrint('  - hasProximitySensor: ${result['hasProximitySensor']}');
        debugPrint(
          '  - hasProximityWakeLock: ${result['hasProximityWakeLock']}',
        );
        debugPrint('  - sensorName: ${result['sensorName']}');
        debugPrint('  - sensorVendor: ${result['sensorVendor']}');
        debugPrint('  - sensorMaxRange: ${result['sensorMaxRange']}');
        debugPrint('  - sensorResolution: ${result['sensorResolution']}');
      }
    } catch (e) {
      debugPrint('⚠️ Failed to check proximity sensor: $e');
    }
  }

  bool get isNear => _isNear;
  bool get isActive => _isActive;
}
