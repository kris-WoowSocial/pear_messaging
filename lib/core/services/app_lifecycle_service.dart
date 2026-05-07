import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// Service to track global app lifecycle state
/// Used to suppress notifications on iOS when app is in foreground
class AppLifecycleService extends GetxService with WidgetsBindingObserver {
  static AppLifecycleService get instance => Get.find<AppLifecycleService>();

  final RxBool _isInForeground = false.obs;
  bool get isInForeground => _isInForeground.value;

  @override
  void onInit() {
    super.onInit();
    debugPrint('📱 AppLifecycleService initialized');
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('📱 App lifecycle state changed: $state');

    switch (state) {
      case AppLifecycleState.resumed:
        _isInForeground.value = true;
        debugPrint('📱 App moved to foreground');
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _isInForeground.value = false;
        debugPrint('📱 App moved to background');
        break;
    }
  }
}
