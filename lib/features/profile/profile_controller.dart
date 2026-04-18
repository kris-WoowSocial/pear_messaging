import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../../core/constants/app_strings.dart';
import '../../core/services/branch_service.dart';
import '../../core/services/local_auth_service.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/utils/string_utils.dart';
import '../chat_list/chat_list_controller.dart';

class ProfileController extends GetxController {
  final LocalStorageService _storageService = Get.find();
  final LocalAuthService _authService = Get.find();

  final RxString deviceId = ''.obs;
  final RxBool isAuthEnabled = false.obs;
  final RxString userName = ''.obs;
  final RxBool isEditingName = false.obs;
  final Rx<TextEditingController> nameController = TextEditingController().obs;

  @override
  void onInit() {
    super.onInit();
    deviceId.value = _storageService.deviceId ?? 'Unknown';
    isAuthEnabled.value = _storageService.isAuthEnabled;

    // Initialize user name - use saved name or generate friendly name
    final savedName = _storageService.getUserName();
    userName.value =
        savedName ?? StringUtils.generateFriendlyName(deviceId.value);
    nameController.value.text = userName.value;
  }

  @override
  void onClose() {
    nameController.value.dispose();
    super.onClose();
  }

  Future<void> toggleAuth(bool enabled) async {
    if (enabled) {
      // Check if biometric is available
      final isAvailable = await _authService.isAvailable();
      if (!isAvailable) {
        Get.snackbar(
          'Not Available',
          'Biometric authentication is not available on this device',
          snackPosition: SnackPosition.BOTTOM,
        );
        return;
      }

      // Test authentication before enabling
      final authenticated = await _authService.authenticate();
      if (!authenticated) {
        Get.snackbar(
          'Setup Failed',
          'Please verify your biometric authentication to enable app lock',
          snackPosition: SnackPosition.BOTTOM,
        );
        return;
      }
    }

    // Save preference
    await _storageService.setAuthEnabled(enabled);
    isAuthEnabled.value = enabled;

    Get.snackbar(
      'App Lock',
      enabled ? 'App lock enabled' : 'App lock disabled',
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  void copyDeviceId() {
    Clipboard.setData(ClipboardData(text: deviceId.value));
    Get.snackbar(
      'Copied',
      'Device ID copied to clipboard',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  void clearChatHistory() {
    Get.defaultDialog(
      title: 'Clear Chat History',
      middleText: AppStrings.clearHistoryConfirm,
      textConfirm: AppStrings.yes,
      textCancel: AppStrings.no,
      confirmTextColor: Get.theme.colorScheme.onError,
      cancelTextColor: Get.theme.colorScheme.primary,
      buttonColor: Get.theme.colorScheme.error,
      onConfirm: () async {
        await _storageService.clearAllChats();

        // Notify ChatListController to refresh the UI
        try {
          final chatListController = Get.find<ChatListController>();
          chatListController.loadChats();
        } catch (e) {
          print(
              '⚠️ ChatListController not found, changes will be visible on restart');
        }

        Get.back(); // Close dialog
        Get.snackbar(
          'Success',
          'Chat history cleared successfully',
          snackPosition: SnackPosition.BOTTOM,
        );
      },
    );
  }

  void shareApp() async {
    try {
      // Get or initialize Branch service
      BranchService branchService;
      try {
        branchService = Get.find<BranchService>();
      } catch (e) {
        // Branch service not initialized, create one
        branchService = BranchService();
        Get.put(branchService);
        await branchService.init();
      }

      // Share the app
      await branchService.shareApp();
    } catch (e) {
      print('❌ Error sharing app: $e');
      Get.snackbar(
        'Share Failed',
        'Unable to share the app. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  void reAuthenticate() async {
    final authenticated = await _authService.authenticate();
    if (authenticated) {
      Get.snackbar(
        'Success',
        'Authentication successful',
        snackPosition: SnackPosition.BOTTOM,
      );
    } else {
      Get.snackbar(
        'Failed',
        'Authentication failed',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  void startEditingName() {
    isEditingName.value = true;
    nameController.value.text = userName.value;
  }

  Future<void> saveUserName() async {
    // Unfocus the text field first
    FocusScope.of(Get.context!).unfocus();

    final newName = nameController.value.text.trim();
    if (newName.isNotEmpty && newName != userName.value) {
      // Update via ChatListController to ensure centralized management
      try {
        final chatListController = Get.find<ChatListController>();
        await chatListController.setUserName(newName);
      } catch (e) {
        // Fallback if ChatListController not found
        await _storageService.setUserName(newName);
      }

      userName.value = newName;
      Get.snackbar(
        'Success',
        'Name updated successfully',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
    // Always close editing mode, even if name didn't change
    isEditingName.value = false;
  }

  void cancelEditingName() {
    // Unfocus the text field first
    FocusScope.of(Get.context!).unfocus();

    isEditingName.value = false;
    nameController.value.text = userName.value;
  }

  String get userInitial {
    if (userName.value.isEmpty) return '?';
    return userName.value[0].toUpperCase();
  }
}
