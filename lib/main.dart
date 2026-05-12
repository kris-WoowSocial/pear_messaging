import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:pear_messaging/app.dart';
import 'package:pear_messaging/core/services/image_cache_service.dart';
import 'package:pear_messaging/firebase_options.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pear_messaging/storage/models/message_entity.dart';
import 'core/services/fcm_service.dart';
import 'core/services/url_preview_service.dart';
import 'core/services/local_storage_service.dart';
import 'core/services/socket_service.dart';
import 'core/services/local_auth_service.dart';
import 'core/services/block_service.dart';
import 'core/services/connection_request_service.dart';
import 'core/services/username_sync_service.dart';
import 'core/services/invitation_storage_service.dart';
import 'core/services/branch_service.dart';
import 'core/services/app_link_service.dart';
import 'core/services/app_update_service.dart';
import 'core/services/review_service.dart';
import 'core/services/region_service.dart';
import 'core/services/membership_service.dart';
import 'core/services/iap_service.dart';
import 'core/services/stripe_service.dart';
import 'core/services/crypto_service.dart';
import 'core/services/report_service.dart';
import 'core/services/app_lifecycle_service.dart';
import 'core/services/badge_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Set the system overlay style globally
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent, // Makes status bar blend in
    statusBarIconBrightness:
        Brightness.dark, // Forces icons (battery/time) to be DARK
    statusBarBrightness:
        Brightness.light, // Required for iOS to show DARK icons
  ));

  // iOS-specific status bar configuration
  if (Platform.isIOS) {
    // Force dark status bar content on iOS
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  // Initialize Hive - CRITICAL for local storage
  await Hive.initFlutter();

  // Initialize only critical services before app launch
  await initializeCriticalServices();

  // Check if this is a returning user (terms already accepted)
  final termsAccepted = await checkTermsAccepted();

  // Request notification permission directly on app launch (Android 13+ requirement)
  // This shows the system permission popup immediately
  await requestNotificationPermission();

  runApp(PearMessagingApp(skipSplash: termsAccepted));

  // Initialize all non-critical services in background after app starts
  initializeNonCriticalServices();
}

/// Initialize only critical services needed for app to function
Future<void> initializeCriticalServices() async {
  // Initialize storage service first - CRITICAL for app data
  final storageService = await Get.putAsync(() => LocalStorageService().init());

  // Get or create device ID - CRITICAL for messaging
  String deviceId = storageService.deviceId ?? '';
  if (deviceId.isEmpty) {
    deviceId = DateTime.now().millisecondsSinceEpoch.toString();
    await storageService.setDeviceId(deviceId);
  }

  // Initialize socket service FIRST - BlockService depends on it
  final socketService = Get.put(SocketService());
  // Don't wait for socket initialization - let it connect in background
  socketService.init(deviceId); // Fire and forget - don't await

  // Initialize basic services that depend on SocketService
  Get.put(LocalAuthService());
  Get.put(BlockService()); // Now this can find SocketService
  Get.put(ConnectionRequestService());
  Get.put(
      AppLifecycleService()); // Track app lifecycle for notification suppression
  Get.put(await Get.putAsync(() => UsernameSyncService().init()));
}

/// Initialize non-critical services in background after app launches
void initializeNonCriticalServices() async {
  try {
    // Initialize Firebase FIRST - FCM depends on it!
    await _initializeFirebase();
    debugPrint('✅ Firebase initialized');

    // Initialize Firebase Analytics in background
    _initializeFirebaseAnalytics();

    // Set preferred orientations in background
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    // IMPORTANT: Initialize InvitationStorageService FIRST before BranchService
    // BranchService depends on InvitationStorageService to store deep link data
    // for deferred deep linking (when user installs app from Play Store after clicking link)
    await Get.putAsync(() => InvitationStorageService().init());

    // Run remaining non-critical initializations in parallel for speed
    await Future.wait([
      // FCM for push notifications - now Firebase is ready
      Get.putAsync(() => FCMService().init()),

      // Image cache - not critical for launch
      Get.putAsync(() => ImageCacheService().init()),

      // Deep linking services - must run AFTER InvitationStorageService is ready
      Get.putAsync(() => BranchService().init()),
      Get.putAsync(() => AppLinkService().init()),

      // App updates - not critical for immediate use
      Get.putAsync(() => AppUpdateService().init()),

      // In-app review - not critical for immediate use
      Get.putAsync(() => ReviewService().init()),

      // Region detection for pricing
      Get.putAsync(() => RegionService().init()),

      // Membership tracking
      Get.putAsync(() => MembershipService().init()),

      // In-app purchase service
      Get.putAsync(() => IAPService().init()),

      // Stripe payment service
      Get.putAsync(() => StripeService().init()),

      // Crypto payment service
      Get.putAsync(() => CryptoService().init()),

      // URL preview service for link previews
      Get.putAsync(() => UrlPreviewService().init()),
    ]);

    // Initialize badge service (not async, doesn't need to be in Future.wait)
    Get.put(BadgeService());

    // Recalculate badge count from local storage on app startup
    // Count actual unread messages based on message status, not chat.unreadCount
    try {
      final storageService = Get.find<LocalStorageService>();
      final allChats = storageService.getAllChats();
      int totalUnread = 0;

      for (final chat in allChats) {
        final messages = storageService.getChatMessages(chat.id);
        final unreadCount = messages
            .where((msg) => !msg.isMe && msg.status != MessageStatus.read)
            .length;
        totalUnread += unreadCount;

        // Update chat entity's unreadCount to match actual count
        if (chat.unreadCount != unreadCount) {
          final updatedChat = chat.copyWith(unreadCount: unreadCount);
          await storageService.saveChat(updatedChat);
        }
      }

      final badgeService = Get.find<BadgeService>();
      await badgeService.setTotalUnreadCount(totalUnread);
      debugPrint('📊 Badge count recalculated on startup: $totalUnread');
    } catch (e) {
      debugPrint('⚠️ Error recalculating badge on startup: $e');
    }

    // Initialize report service - not async, very fast
    Get.put(ReportService());

    debugPrint('✅ Non-critical services initialized in background');

    // Handle notification tap that arrived while app was terminated
    await checkPendingNotificationNavigation();

    // Check app link handler status after initialization
    _checkAppLinkHandler();
  } catch (e) {
    debugPrint('⚠️ Error initializing non-critical services: $e');
    // Don't block the app if non-critical services fail
  }
}

/// Initialize Firebase in background (was blocking app launch)
Future<void> _initializeFirebase() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('✅ Firebase initialized in background');
  } catch (e) {
    if (e.toString().contains('duplicate-app')) {
      debugPrint('⚠️ Firebase already initialized');
    } else {
      debugPrint('❌ Firebase initialization error: $e');
    }
  }
}

/// Initialize Firebase Analytics in background
void _initializeFirebaseAnalytics() async {
  try {
    FirebaseAnalytics analytics = FirebaseAnalytics.instance;
    await analytics.logAppOpen();
    debugPrint('✅ Firebase Analytics initialized in background');
  } catch (e) {
    debugPrint('⚠️ Error initializing Firebase Analytics: $e');
  }
}

/// Check app link handler status (non-blocking)
void _checkAppLinkHandler() async {
  try {
    final appLinkService = Get.find<AppLinkService>();
    final isDefault = await appLinkService.isDefaultLinkHandler();
    if (!isDefault) {
      debugPrint('⚠️ App is not set as default link handler');
    } else {
      debugPrint('✅ App is set as default link handler');
    }
  } catch (e) {
    debugPrint('⚠️ Error checking app link handler: $e');
  }
}

/// Check if terms have been accepted (for fast startup)
Future<bool> checkTermsAccepted() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('terms_accepted') ?? false;
  } catch (e) {
    debugPrint('⚠️ Error checking terms status: $e');
    return false;
  }
}

/// Request notification permission directly (Android 13+ requirement)
/// Shows the system permission popup immediately on app launch
Future<void> requestNotificationPermission() async {
  try {
    if (Platform.isAndroid) {
      // Android 13+ permission handling
      final status = await Permission.notification.status;
      debugPrint('📱 Android notification permission status: $status');

      if (status.isDenied) {
        debugPrint('📱 Requesting Android notification permission...');
        final result = await Permission.notification.request();
        debugPrint('📱 Android notification permission result: $result');
      } else if (status.isPermanentlyDenied) {
        debugPrint(
          '⚠️ Notification permission permanently denied - user must enable in settings',
        );
      } else if (status.isGranted) {
        debugPrint('✅ Notification permission already granted');
      }
    } else if (Platform.isIOS) {
      // iOS notification permission handling
      debugPrint('📱 iOS: Requesting notification permissions via Firebase...');
      // Firebase will handle iOS permissions when FCM is initialized
      // This is handled in FCMService.init() with requestPermission()
    }
  } catch (e) {
    debugPrint('⚠️ Error requesting notification permission: $e');
  }
}
