import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:pear_messaging/app.dart';
import 'package:pear_messaging/core/services/image_cache_service.dart';
import 'package:pear_messaging/config/flavor_config.dart';
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
import 'core/services/notification_service.dart';
import 'core/services/iap_service.dart';
import 'core/services/report_service.dart';
import 'core/services/api_service.dart';
import 'core/services/app_lifecycle_service.dart';
import 'core/services/badge_service.dart';
import 'core/services/secure_key_service.dart';
import 'core/services/secure_encryption_service.dart';
import 'core/services/secure_image_storage_service.dart';
import 'core/services/chat_media_service.dart';
import 'core/services/call_history_service.dart';
import 'core/services/webrtc_call_service.dart';
import 'core/services/call_foreground_service.dart';
import 'core/services/callkit_service.dart';
import 'core/utils/string_utils.dart';
import 'features/call/call_controller.dart';

void main() async {
  debugPrint('🚀 main() called - app starting fresh');

  // Initialize flavor config for prod
  FlavorConfig(
    flavor: Flavor.prod,
    appName: 'Vant Chat',
    apiBaseUrl: 'https://vant.chat',
    showDebugBanner: false,
  );

  WidgetsFlutterBinding.ensureInitialized();

  // 2. Set the system overlay style globally
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent, // Makes status bar blend in
      statusBarIconBrightness:
          Brightness.dark, // Forces icons (battery/time) to be DARK
      statusBarBrightness:
          Brightness.light, // Required for iOS to show DARK icons
    ),
  );

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

  // Register FCM background handler BEFORE Firebase.initializeApp and before
  // other services. This is required for the handler to be available when the
  // app is killed and an FCM message arrives.
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

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
  // Initialize secure key service FIRST - Required for encryption
  // Wrapped in try-catch to prevent crash if secure storage fails
  try {
    await Get.putAsync(() => SecureKeyService().init());
    debugPrint('✅ SecureKeyService initialized');
  } catch (e) {
    debugPrint('❌ SecureKeyService initialization failed: $e');
    debugPrint('⚠️ App will continue without secure encryption');
    // Create a dummy service to prevent crashes when other services try to find it
    Get.put(SecureKeyService());
  }

  // Initialize secure encryption service
  try {
    await Get.putAsync(() => SecureEncryptionService().init());
    debugPrint('✅ SecureEncryptionService initialized');
  } catch (e) {
    debugPrint('❌ SecureEncryptionService initialization failed: $e');
    debugPrint('⚠️ App will continue without encryption');
    // Create a dummy service to prevent crashes
    Get.put(SecureEncryptionService());
  }

  // Initialize secure image storage service
  try {
    await Get.putAsync(() => SecureImageStorageService().init());
    debugPrint('✅ SecureImageStorageService initialized');
  } catch (e) {
    debugPrint('❌ SecureImageStorageService initialization failed: $e');
    debugPrint('⚠️ App will continue without secure image storage');
    // Create a dummy service to prevent crashes
    Get.put(SecureImageStorageService());
  }

  // Initialize chat media service
  try {
    await Get.putAsync(() => ChatMediaService().init());
    debugPrint('✅ ChatMediaService initialized');
  } catch (e) {
    debugPrint('❌ ChatMediaService initialization failed: $e');
    debugPrint('⚠️ App will continue without chat media service');
    // Create a dummy service to prevent crashes
    Get.put(ChatMediaService());
  }

  // Initialize storage service - CRITICAL for app data
  // This MUST succeed for the app to function
  try {
    final storageService = await Get.putAsync(
      () => LocalStorageService().init(),
    );
    debugPrint('✅ LocalStorageService initialized');

    // Get or create device ID - CRITICAL for messaging
    String deviceId = storageService.deviceId ?? '';
    if (deviceId.isEmpty) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
      await storageService.setDeviceId(deviceId);
    }
  } catch (e) {
    debugPrint('❌ CRITICAL: LocalStorageService initialization failed: $e');
    debugPrint('❌ App cannot function without local storage');
    rethrow; // This is critical - let the app crash with a clear error
  }

  // Initialize ApiService - all HTTP calls go through this
  try {
    await Get.putAsync(() => ApiService().init());
    debugPrint('✅ ApiService initialized');
  } catch (e) {
    debugPrint('❌ ApiService initialization failed: $e');
    debugPrint('⚠️ App will continue but network features may not work');
    // Create a dummy service to prevent crashes
    Get.put(ApiService());
  }

  // Initialize socket service FIRST - BlockService depends on it
  final socketService = Get.put(SocketService());
  // Don't wait for socket initialization - let it connect in background
  try {
    final storageService = Get.find<LocalStorageService>();
    final deviceId = storageService.deviceId ?? '';
    socketService.init(deviceId); // Fire and forget - don't await
    debugPrint('✅ SocketService initialized');
  } catch (e) {
    debugPrint('❌ SocketService initialization failed: $e');
    debugPrint('⚠️ App will continue but real-time features may not work');
  }

  // Initialize basic services that depend on SocketService
  Get.put(LocalAuthService());
  Get.put(BlockService()); // Now this can find SocketService
  Get.put(ConnectionRequestService());
  Get.put(
    AppLifecycleService(),
  ); // Track app lifecycle for notification suppression

  try {
    Get.put(await Get.putAsync(() => UsernameSyncService().init()));
    debugPrint('✅ UsernameSyncService initialized');
  } catch (e) {
    debugPrint('❌ UsernameSyncService initialization failed: $e');
    debugPrint('⚠️ App will continue without username sync');
    Get.put(UsernameSyncService());
  }

  // Initialize call history service - must be ready before UI renders
  try {
    await Get.putAsync(() => CallHistoryService().init());
    debugPrint('✅ CallHistoryService initialized');
  } catch (e) {
    debugPrint('❌ CallHistoryService initialization failed: $e');
    debugPrint('⚠️ App will continue without call history');
    Get.put(CallHistoryService());
  }

  // Initialize CallController for handling incoming calls when app launches from background
  Get.put(CallController());
  debugPrint('✅ CallController initialized');
}

/// Initialize non-critical services in background after app launches
void initializeNonCriticalServices() async {
  try {
    // Initialize Firebase FIRST - FCM depends on it!
    await _initializeFirebase();
    debugPrint('✅ Firebase initialized');
  } catch (e) {
    debugPrint('❌ Firebase initialization failed: $e');
    debugPrint('⚠️ App will continue without Firebase');
  }

  try {
    // Initialize Firebase Analytics in background
    _initializeFirebaseAnalytics();
  } catch (e) {
    debugPrint('❌ Firebase Analytics initialization failed: $e');
  }

  try {
    // Set preferred orientations in background
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  } catch (e) {
    debugPrint('❌ Failed to set preferred orientations: $e');
  }

  try {
    // IMPORTANT: Initialize InvitationStorageService FIRST before BranchService
    // BranchService depends on InvitationStorageService to store deep link data
    // for deferred deep linking (when user installs app from Play Store after clicking link)
    await Get.putAsync(() => InvitationStorageService().init());
    debugPrint('✅ InvitationStorageService initialized');
  } catch (e) {
    debugPrint('❌ InvitationStorageService initialization failed: $e');
    debugPrint('⚠️ App will continue without invitation storage');
    Get.put(InvitationStorageService());
  }

  // Initialize CallKit native UI event listeners BEFORE FCM so any incoming call
  // shown by FCM can have its accept/decline/end events handled immediately.
  try {
    await CallKitService().initialize();
    debugPrint('✅ CallKitService initialized');
  } catch (e) {
    debugPrint('❌ CallKitService initialization failed: $e');
    debugPrint('⚠️ App will continue without native CallKit events');
  }

  // Run remaining non-critical initializations in parallel for speed
  // Each wrapped in try-catch to prevent one failure from blocking others
  final futures = <Future>[];

  // FCM for push notifications - now Firebase is ready
  futures.add(
    Get.putAsync(() => FCMService().init()).catchError((e) {
      debugPrint('❌ FCMService initialization failed: $e');
      debugPrint('⚠️ App will continue without push notifications');
      return Get.put(FCMService());
    }),
  );

  // Image cache - not critical for launch
  futures.add(
    Get.putAsync(() => ImageCacheService().init()).catchError((e) {
      debugPrint('❌ ImageCacheService initialization failed: $e');
      debugPrint('⚠️ App will continue without image cache');
      return Get.put(ImageCacheService());
    }),
  );

  // Deep linking services - must run AFTER InvitationStorageService is ready
  futures.add(
    Get.putAsync(() => BranchService().init()).catchError((e) {
      debugPrint('❌ BranchService initialization failed: $e');
      debugPrint('⚠️ App will continue without Branch deep linking');
      return Get.put(BranchService());
    }),
  );

  futures.add(
    Get.putAsync(() => AppLinkService().init()).catchError((e) {
      debugPrint('❌ AppLinkService initialization failed: $e');
      debugPrint('⚠️ App will continue without app linking');
      return Get.put(AppLinkService());
    }),
  );

  // App updates - not critical for immediate use
  futures.add(
    Get.putAsync(() => AppUpdateService().init()).catchError((e) {
      debugPrint('❌ AppUpdateService initialization failed: $e');
      debugPrint('⚠️ App will continue without app updates');
      return Get.put(AppUpdateService());
    }),
  );

  // In-app review - not critical for immediate use
  futures.add(
    Get.putAsync(() => ReviewService().init()).catchError((e) {
      debugPrint('❌ ReviewService initialization failed: $e');
      debugPrint('⚠️ App will continue without in-app review');
      return Get.put(ReviewService());
    }),
  );

  // Region detection for pricing
  futures.add(
    Get.putAsync(() => RegionService().init()).catchError((e) {
      debugPrint('❌ RegionService initialization failed: $e');
      debugPrint('⚠️ App will continue without region detection');
      return Get.put(RegionService());
    }),
  );

  // Membership tracking
  futures.add(
    Get.putAsync(() => MembershipService().init()).catchError((e) {
      debugPrint('❌ MembershipService initialization failed: $e');
      debugPrint('⚠️ App will continue without membership tracking');
      return Get.put(MembershipService());
    }),
  );

  // In-app purchase service
  futures.add(
    Get.putAsync(() => IAPService().init()).catchError((e) {
      debugPrint('❌ IAPService initialization failed: $e');
      debugPrint('⚠️ App will continue without in-app purchases');
      return Get.put(IAPService());
    }),
  );

  // URL preview service for link previews
  futures.add(
    Get.putAsync(() => UrlPreviewService().init()).catchError((e) {
      debugPrint('❌ UrlPreviewService initialization failed: $e');
      debugPrint('⚠️ App will continue without URL previews');
      return Get.put(UrlPreviewService());
    }),
  );

  try {
    await Future.wait(futures);
    debugPrint('✅ Non-critical async services initialized');
  } catch (e) {
    debugPrint('⚠️ Some non-critical services failed to initialize: $e');
  }

  // Initialize badge service (not async, doesn't need to be in Future.wait)
  try {
    Get.put(BadgeService());
    debugPrint('✅ BadgeService initialized');
  } catch (e) {
    debugPrint('❌ BadgeService initialization failed: $e');
  }

  // Recalculate badge count from local storage on app startup
  // Count actual unread messages based on message status, not chat.unreadCount
  try {
    final storageService = Get.find<LocalStorageService>();
    final allChats = storageService.getAllChats();
    int totalUnread = 0;

    for (final chat in allChats) {
      final messages = await storageService.getChatMessages(chat.id);
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
  try {
    Get.put(ReportService());
    debugPrint('✅ ReportService initialized');
  } catch (e) {
    debugPrint('❌ ReportService initialization failed: $e');
  }

  // Initialize foreground service channel for Android call persistence
  try {
    if (Platform.isAndroid) {
      await CallForegroundService.initialize();
      debugPrint('✅ CallForegroundService initialized');
    }
  } catch (e) {
    debugPrint('❌ CallForegroundService initialization failed: $e');
  }

  // Initialize notification service for WhatsApp-style call notifications
  try {
    await NotificationService().initialize();
    debugPrint('✅ NotificationService initialized');
  } catch (e) {
    debugPrint('❌ NotificationService initialization failed: $e');
  }

  // Initialize WebRTC call service
  try {
    Get.put(WebRTCCallService());
    await Get.find<WebRTCCallService>().initialize();
    debugPrint('✅ WebRTCCallService initialized');
  } catch (e) {
    debugPrint('❌ WebRTCCallService initialization failed: $e');
    debugPrint('⚠️ App will continue without WebRTC calls');
    Get.put(WebRTCCallService());
  }

  // Initialize CallController to listen for incoming calls
  try {
    Get.put(CallController());
    debugPrint('✅ CallController initialized');
  } catch (e) {
    debugPrint('❌ CallController initialization failed: $e');
  }

  // Check if user accepted a call while app was killed (cold-start resync)
  try {
    await _handlePendingAcceptedCall();
  } catch (e) {
    debugPrint('❌ Error handling pending accepted call: $e');
  }

  debugPrint('✅ Non-critical services initialized in background');

  // Handle notification tap that arrived while app was terminated
  try {
    await checkPendingNotificationNavigation();
  } catch (e) {
    debugPrint('❌ Error handling pending notification navigation: $e');
  }

  // Check app link handler status after initialization
  try {
    _checkAppLinkHandler();
  } catch (e) {
    debugPrint('❌ Error checking app link handler: $e');
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

/// Request microphone permission for audio calls
/// Shows the system permission popup immediately on app launch
/// NOTE: On iOS, if permission was previously denied, the system won't show the dialog again
/// The user must manually enable it in Settings
Future<void> requestMicrophonePermission() async {
  try {
    final status = await Permission.microphone.status;
    debugPrint('🎤 Microphone permission status: $status');

    if (status.isGranted) {
      debugPrint('✅ Microphone permission already granted');
      return;
    }

    if (status.isPermanentlyDenied) {
      debugPrint(
        '⚠️ Microphone permission permanently denied - user must enable in Settings',
      );
      // Snackbar is shown by SplashController where Get context is ready
      return;
    }

    // Request permission if not granted (including denied but not permanently)
    debugPrint('🎤 Requesting microphone permission...');
    final result = await Permission.microphone.request();
    debugPrint('🎤 Microphone permission result: $result');
  } catch (e) {
    debugPrint('⚠️ Error requesting microphone permission: $e');
  }
}

/// Handle cold-start after user accepted call from background/killed state
/// This checks SharedPreferences for pendingAcceptedCallId set by CallKitService
/// and triggers call_resync to get the SDP offer from server
Future<void> _handlePendingAcceptedCall() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final pendingCallId = prefs.getString('pendingAcceptedCallId');
    if (pendingCallId == null || pendingCallId.isEmpty) return;

    // Clear immediately to prevent re-processing on next launch
    await prefs.remove('pendingAcceptedCallId');
    debugPrint('📞 Cold start: pendingAcceptedCallId = $pendingCallId');

    // Wait for socket to be connected and registered
    final socketService = Get.find<SocketService>();
    int attempts = 0;
    while (!socketService.isConnected.value && attempts < 30) {
      await Future.delayed(const Duration(milliseconds: 200));
      attempts++;
    }

    if (!socketService.isConnected.value) {
      debugPrint('📞 Cold start resync: socket connection timeout');
      return;
    }

    // Set auto-accept flag and emit resync to get SDP offer
    final callController = Get.find<CallController>();
    await callController.setPendingAutoAccept(pendingCallId);
    socketService.socket?.emit('call_resync', {'callId': pendingCallId});
    debugPrint('📞 Cold start: emitted call_resync for $pendingCallId');
  } catch (e) {
    debugPrint('📞 Error handling pending accepted call: $e');
  }
}
