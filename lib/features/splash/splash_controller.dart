import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io' show Platform;
import '../../core/constants/network_constants.dart';
import '../../core/services/local_auth_service.dart';
import '../../core/services/local_storage_service.dart';
import '../../core/services/invitation_storage_service.dart';
import '../../core/services/review_service.dart';
import '../../core/services/username_sync_service.dart';
import '../../core/utils/device_utils.dart';
import '../../routes/app_routes.dart';
import '../../storage/models/connection_request_entity.dart';
import '../../storage/models/message_entity.dart';

class SplashController extends GetxController {
  final LocalAuthService _authService = Get.find();
  final LocalStorageService _storageService = Get.find();

  // Observable for first launch state
  final RxBool isFirstLaunch = false.obs;
  final RxBool isLoading = true.obs;
  bool _isNameSetupOpen = false;

  @override
  void onInit() {
    super.onInit();
    _checkFirstLaunch();
  }

  Future<void> showInitialNameSetup() async {
    if (_isNameSetupOpen) return;
    _isNameSetupOpen = true;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('initial_name_setup_completed') ?? false) {
      _isNameSetupOpen = false;
      return;
    }

    final existingName = _storageService.getUserName()?.trim();
    if (existingName?.isNotEmpty == true) {
      await prefs.setBool('initial_name_setup_completed', true);
      _isNameSetupOpen = false;
      return;
    }

    final nameController = TextEditingController();
    String? errorText;
    bool isSaving = false;

    await Get.bottomSheet<void>(
      PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (context, setState) {
            final mediaQuery = MediaQuery.of(context);
            final keyboardHeight = mediaQuery.viewInsets.bottom;
            final sheetHeight = keyboardHeight > 0
                ? mediaQuery.size.height -
                    keyboardHeight -
                    mediaQuery.padding.top -
                    8
                : mediaQuery.size.height * 0.5;

            return AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              height: sheetHeight,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: IntrinsicHeight(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Center(
                                  child: Container(
                                    width: 42,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade300,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 28),
                                const Text(
                                  'What should people call you?',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                const Text(
                                  'Your name will be included when you invite friends and shown on connection requests.',
                                  style: TextStyle(
                                    fontSize: 15,
                                    height: 1.4,
                                    color: Colors.black54,
                                  ),
                                ),
                                const SizedBox(height: 24),
                                TextField(
                                  controller: nameController,
                                  autofocus: true,
                                  textCapitalization: TextCapitalization.words,
                                  textInputAction: TextInputAction.done,
                                  maxLength: 30,
                                  enabled: !isSaving,
                                  decoration: InputDecoration(
                                    labelText: 'Your name',
                                    hintText: 'Enter your name',
                                    errorText: errorText,
                                    prefixIcon:
                                        const Icon(Icons.person_outline),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  onSubmitted: isSaving
                                      ? null
                                      : (_) => _saveInitialName(
                                            nameController: nameController,
                                            prefs: prefs,
                                            setState: setState,
                                            setError: (value) =>
                                                errorText = value,
                                            setSaving: (value) =>
                                                isSaving = value,
                                          ),
                                ),
                                const Spacer(),
                                SizedBox(
                                  width: double.infinity,
                                  height: 52,
                                  child: ElevatedButton(
                                    onPressed: isSaving
                                        ? null
                                        : () => _saveInitialName(
                                              nameController: nameController,
                                              prefs: prefs,
                                              setState: setState,
                                              setError: (value) =>
                                                  errorText = value,
                                              setSaving: (value) =>
                                                  isSaving = value,
                                            ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFB9D58C),
                                      foregroundColor: Colors.black87,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                    ),
                                    child: isSaving
                                        ? const SizedBox(
                                            width: 22,
                                            height: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.black54,
                                            ),
                                          )
                                        : const Text(
                                            'Continue',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        ),
      ),
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
    );

    nameController.dispose();
    _isNameSetupOpen = false;
  }

  Future<void> _saveInitialName({
    required TextEditingController nameController,
    required SharedPreferences prefs,
    required StateSetter setState,
    required ValueChanged<String?> setError,
    required ValueChanged<bool> setSaving,
  }) async {
    final name = nameController.text.trim();
    if (name.isEmpty) {
      setState(() => setError('Please enter your name'));
      return;
    }

    setState(() {
      setError(null);
      setSaving(true);
    });

    try {
      await _storageService.setUserName(name);
      await prefs.setBool('initial_name_setup_completed', true);

      try {
        if (Get.isRegistered<UsernameSyncService>()) {
          final deviceId = _storageService.deviceId;
          if (deviceId != null && deviceId.isNotEmpty) {
            await Get.find<UsernameSyncService>().syncUsername(deviceId, name);
          }
        }
      } catch (e) {
        debugPrint('⚠️ Initial name saved locally but could not sync: $e');
      }

      Get.back();
    } catch (e) {
      debugPrint('❌ Error saving initial name: $e');
      setState(() {
        setSaving(false);
        setError('Could not save your name. Please try again.');
      });
    }
  }

  /// Check if this is the first launch of the app
  Future<void> _checkFirstLaunch() async {
    try {
      // Check if terms have been accepted
      final termsAccepted = await _getTermsAccepted();
      isFirstLaunch.value = !termsAccepted;
      isLoading.value = false;

      // If not first launch, proceed with normal initialization
      if (!isFirstLaunch.value) {
        // On iOS, always check microphone permission on every launch
        // Small delay ensures the splash UI is fully visible before requesting
        if (Platform.isIOS) {
          await Future.delayed(const Duration(milliseconds: 800));
          await _requestMicrophonePermissionOnSplash();
        }
        _initializeApp();
      }
    } catch (e) {
      debugPrint('❌ Error checking first launch: $e');
      isFirstLaunch.value = true;
      isLoading.value = false;
    }
  }

  /// Accept terms and continue to app
  Future<void> acceptTermsAndContinue() async {
    try {
      // Mark terms as accepted
      await _setTermsAccepted(true);

      // Update UI state
      isFirstLaunch.value = false;
      isLoading.value = true;

      // Request microphone permission on iOS splash screen (like Android)
      // Small delay ensures the splash UI is fully visible before requesting
      if (Platform.isIOS) {
        await Future.delayed(const Duration(milliseconds: 800));
        await _requestMicrophonePermissionOnSplash();
      }

      // Proceed with app initialization
      await _initializeApp();
    } catch (e) {
      debugPrint('❌ Error accepting terms: $e');
      Get.snackbar(
        'Error',
        'Failed to continue. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  /// Request microphone permission on splash screen for iOS
  /// Shows the native iOS permission popup, or opens Settings if permanently denied
  Future<void> _requestMicrophonePermissionOnSplash() async {
    try {
      final status = await Permission.microphone.status;
      debugPrint('🎤 Splash microphone permission status: $status');

      if (status.isGranted) {
        debugPrint('✅ Microphone permission already granted');
        return;
      }

      if (status.isPermanentlyDenied) {
        debugPrint(
          '🎤 Microphone permanently denied - will prompt after navigation',
        );
        // Delay until after navigation to home so snackbar is visible
        Future.delayed(const Duration(seconds: 3), () {
          Get.snackbar(
            'Microphone Access Required',
            'Please enable microphone in Settings to make calls.',
            snackPosition: SnackPosition.BOTTOM,
            duration: const Duration(seconds: 8),
            mainButton: TextButton(
              onPressed: () => openAppSettings(),
              child: const Text(
                'Open Settings',
                style: TextStyle(color: Colors.white),
              ),
            ),
          );
        });
        return;
      }

      // Request the native iOS microphone permission popup
      debugPrint('🎤 Requesting microphone permission on splash screen...');
      final result = await Permission.microphone.request();
      debugPrint('🎤 Splash microphone permission result: $result');
    } catch (e) {
      debugPrint('⚠️ Error requesting microphone permission on splash: $e');
    }
  }

  /// Get terms accepted status
  Future<bool> _getTermsAccepted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('terms_accepted') ?? false;
    } catch (e) {
      debugPrint('❌ Error getting terms status: $e');
      return false;
    }
  }

  /// Set terms accepted status
  Future<void> _setTermsAccepted(bool accepted) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('terms_accepted', accepted);
    } catch (e) {
      debugPrint('❌ Error setting terms status: $e');
    }
  }

  /// Open Terms of Service in external browser
  Future<void> openTermsOfService() async {
    final Uri url = Uri.parse(NetworkConstants.termsUrl);
    try {
      debugPrint('🌐 Attempting to launch URL: $url');

      // Check if URL can be launched
      final canLaunch = await canLaunchUrl(url);
      debugPrint('🔍 Can launch URL: $canLaunch');

      if (canLaunch) {
        // Try external application mode first
        final launched = await launchUrl(
          url,
          mode: LaunchMode.externalApplication,
        );

        if (!launched) {
          // Fallback to platform default
          debugPrint('🔄 External launch failed, trying platform default...');
          await launchUrl(url, mode: LaunchMode.platformDefault);
        }
      } else {
        debugPrint('❌ Cannot launch URL: $url');
        Get.snackbar(
          'Error',
          'Could not open Terms of Service. No browser available.',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.shade100,
          colorText: Colors.red.shade800,
        );
      }
    } catch (e) {
      debugPrint('❌ Error launching Terms of Service: $e');
      Get.snackbar(
        'Error',
        'Could not open Terms of Service',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
    }
  }

  /// Open Privacy Policy in external browser
  Future<void> openPrivacyPolicy() async {
    final Uri url = Uri.parse(NetworkConstants.privacyPolicyUrl);
    try {
      debugPrint('🌐 Attempting to launch URL: $url');

      // Check if URL can be launched
      final canLaunch = await canLaunchUrl(url);
      debugPrint('🔍 Can launch URL: $canLaunch');

      if (canLaunch) {
        // Try external application mode first
        final launched = await launchUrl(
          url,
          mode: LaunchMode.externalApplication,
        );

        if (!launched) {
          // Fallback to platform default
          debugPrint('🔄 External launch failed, trying platform default...');
          await launchUrl(url, mode: LaunchMode.platformDefault);
        }
      } else {
        debugPrint('❌ Cannot launch URL: $url');
        Get.snackbar(
          'Error',
          'Could not open Privacy Policy. No browser available.',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.shade100,
          colorText: Colors.red.shade800,
        );
      }
    } catch (e) {
      debugPrint('❌ Error launching Privacy Policy: $e');
      Get.snackbar(
        'Error',
        'Could not open Privacy Policy',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
    }
  }

  Future<void> _initializeApp() async {
    try {
      debugPrint('🚀 Starting app initialization...');

      // Set up device ID if not exists
      debugPrint('📱 Setting up device ID...');
      await _setupDeviceId();
      debugPrint('✅ Device ID: ${_storageService.deviceId}');

      // Authenticate user
      debugPrint('🔐 Authenticating user...');
      final authenticated = await _authenticate();
      debugPrint('✅ Authentication result: $authenticated');

      if (authenticated) {
        // Check for pending invitations before navigating
        await _checkPendingInvitationAndNavigate();
      } else {
        // Authentication failed - show error and allow retry
        debugPrint('❌ Authentication failed');
        Get.snackbar(
          'Authentication Failed',
          'Tap to retry authentication',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 5),
          onTap: (_) => _initializeApp(),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('💥 Error during initialization: $e');
      debugPrint('Stack trace: $stackTrace');
      Get.snackbar(
        'Error',
        'Failed to initialize app: $e',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 5),
      );
    }
  }

  Future<void> _setupDeviceId() async {
    if (_storageService.deviceId == null) {
      final deviceId = await DeviceUtils.getDeviceId();
      await _storageService.setDeviceId(deviceId);
    }
  }

  /// Check for pending invitations and navigate accordingly
  Future<void> _checkPendingInvitationAndNavigate() async {
    try {
      // Check if we're already in a chat route (Branch SDK handled navigation)
      final currentRoute = Get.currentRoute;
      if (currentRoute == AppRoutes.chat) {
        debugPrint(
          '📋 Already in chat route, skipping pending invitation processing',
        );
        // Clear any pending invitation since navigation already happened
        if (Get.isRegistered<InvitationStorageService>()) {
          final invitationService = Get.find<InvitationStorageService>();
          invitationService.clearPendingInvitation();
        }
        return;
      }

      // Wait for InvitationStorageService to be ready (for deferred deep linking)
      // This handles the case where user accepts terms quickly after fresh install
      int retries = 0;
      const maxRetries = 10;
      while (!Get.isRegistered<InvitationStorageService>() &&
          retries < maxRetries) {
        debugPrint(
          '📋 Waiting for InvitationStorageService... (${retries + 1}/$maxRetries)',
        );
        await Future.delayed(const Duration(milliseconds: 300));
        retries++;
      }

      if (!Get.isRegistered<InvitationStorageService>()) {
        debugPrint(
          '⚠️ InvitationStorageService not available after waiting, navigating to chat list',
        );
        Get.offAllNamed(AppRoutes.main);
        return;
      }

      final invitationService = Get.find<InvitationStorageService>();

      // Wait a bit more for BranchService to finish processing and storing deep link data
      // This handles deferred deep linking where Branch SDK needs time to process the link
      if (!invitationService.hasPendingInvitation()) {
        debugPrint(
          '📋 No pending invitation yet, waiting for BranchService to process...',
        );
        await Future.delayed(const Duration(milliseconds: 1500));
      }

      final pendingInvitation = invitationService.getPendingInvitation();

      if (pendingInvitation != null) {
        debugPrint(
          '📋 Found pending invitation during splash: ${pendingInvitation['deviceId']}',
        );

        // Create a connection request and navigate to chat list (NOT directly to chat)
        // The user should see a connection request card and choose to accept/reject
        final deviceId = pendingInvitation['deviceId']!;
        final userName = pendingInvitation['userName']!;

        try {
          // Enhanced validation: Check if chat already exists
          final existingChat = _storageService.getChat(deviceId);
          if (existingChat != null) {
            debugPrint(
              '📋 Chat already exists for device $deviceId, clearing pending invitation',
            );
            invitationService.clearPendingInvitation();
            Get.offAllNamed(AppRoutes.main);
            return;
          }

          // Enhanced validation: Check if connection request already exists
          final existingRequests =
              _storageService.getPendingConnectionRequests();
          final hasExistingRequest = existingRequests.any(
            (request) =>
                request.senderDeviceId == deviceId ||
                request.receiverDeviceId == deviceId,
          );

          if (hasExistingRequest) {
            debugPrint(
              '📋 Connection request already exists for device $deviceId, clearing pending invitation',
            );
            invitationService.clearPendingInvitation();
            Get.offAllNamed(AppRoutes.main);
            return;
          }

          // Create connection request entity
          final connectionRequest = ConnectionRequestEntity(
            id: 'req_${DateTime.now().millisecondsSinceEpoch}',
            senderDeviceId: deviceId,
            receiverDeviceId: _storageService.deviceId!,
            timestamp: DateTime.now(),
            status: ConnectionRequestStatus.pending,
            messageContent: null,
            messageType: MessageType.text,
            senderName: userName,
          );

          // Save connection request to storage
          await _storageService.saveConnectionRequest(connectionRequest);
          debugPrint('💾 Connection request saved during splash');

          // Clear the pending invitation after processing
          invitationService.clearPendingInvitation();

          // Navigate to chat list to show the connection request card
          Get.offAllNamed(AppRoutes.main);
          debugPrint('✅ Navigated to chat list with connection request');
        } catch (e) {
          debugPrint('⚠️ Error creating connection request: $e');
          // Fallback: navigate to chat list anyway
          invitationService.clearPendingInvitation();
          Get.offAllNamed(AppRoutes.main);
        }
      } else {
        // No pending invitation, navigate to chat list normally
        Get.offAllNamed(AppRoutes.main);
        debugPrint('🏠 Navigating to chat list (no pending invitation)');

        // Auto-trigger review dialog after navigation (for testing)
        _checkAndShowReview();
      }
    } catch (e) {
      debugPrint('⚠️ Error checking pending invitations: $e');
      // Fallback to normal navigation
      Get.offAllNamed(AppRoutes.main);
      debugPrint('🏠 Fallback: Navigating to chat list');

      // Auto-trigger review dialog after navigation (for testing)
      _checkAndShowReview();
    }
  }

  /// Check and show review dialog if conditions are met
  Future<void> _checkAndShowReview() async {
    try {
      // Wait for ReviewService to be ready
      await Future.delayed(const Duration(milliseconds: 500));

      if (!Get.isRegistered<ReviewService>()) {
        debugPrint('⚠️ ReviewService not registered yet');
        return;
      }

      final reviewService = Get.find<ReviewService>();

      // Check if review should be shown
      if (reviewService.shouldShowReview()) {
        // Show after a small delay (3 seconds after home screen loads)
        Future.delayed(const Duration(seconds: 3), () {
          debugPrint('⭐ Auto-triggering review dialog');
          reviewService.requestReview();
        });
      }
    } catch (e) {
      debugPrint('❌ Error checking review: $e');
    }
  }

  Future<bool> _authenticate() async {
    try {
      // Check if auth is enabled by user
      if (!_storageService.isAuthEnabled) {
        debugPrint('🔒 Authentication is disabled by user, skipping...');
        return true;
      }

      // Check if biometric is available
      final isAvailable = await _authService.isAvailable();

      if (!isAvailable) {
        debugPrint('🔒 Biometric authentication not available, skipping...');
        return true;
      }

      return await _authService.authenticate();
    } catch (e) {
      debugPrint('❌ Authentication error: $e');
      // Return true to allow app to continue in case of error
      return true;
    }
  }
}
