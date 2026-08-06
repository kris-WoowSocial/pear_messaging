import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'config/flavor_config.dart';
import 'core/theme/app_theme.dart';
import 'core/services/socket_service.dart';
import 'core/services/webrtc_call_service.dart';
import 'features/chat_list/chat_list_controller.dart';
import 'features/chat/chat_controller.dart';
import 'features/call/call_controller.dart';
import 'features/call/call_banner.dart';
import 'routes/app_routes.dart';

class PearMessagingApp extends StatefulWidget {
  final bool skipSplash;

  const PearMessagingApp({super.key, this.skipSplash = false});

  @override
  State<PearMessagingApp> createState() => _PearMessagingAppState();
}

class _PearMessagingAppState extends State<PearMessagingApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Check for pending auto-accept call (for background CallKit accept)
    // This handles cases where CallKit brings app to foreground without triggering lifecycle events
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingAutoAcceptOnStartup();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    debugPrint('📱 App lifecycle state changed: $state');

    if (state == AppLifecycleState.resumed) {
      _onAppResumed();
    }
  }

  String _getInitialRoute() {
    // If returning user (terms accepted), go to chat list
    if (widget.skipSplash) {
      return AppRoutes.chatList;
    }
    // Otherwise show splash/terms screen
    return AppRoutes.splash;
  }

  void _onAppResumed() {
    debugPrint('📱 App resumed from background - refreshing data');

    // 0. If a call is currently connected, jump straight to the active call screen
    try {
      if (Get.isRegistered<CallController>()) {
        final callController = Get.find<CallController>();
        if (callController.isConnected && Get.currentRoute != '/call/active') {
          debugPrint(
            '📞 App resumed with active call, navigating to /call/active',
          );
          Get.offAllNamed('/call/active');
          return;
        }
      }
    } catch (e) {
      debugPrint('⚠️ Error checking active call on resume: $e');
    }

    // 1. Force reconnect if socket is disconnected — Android Doze mode kills
    // WebSocket connections and the internal retry counter may be exhausted
    // Skip reconnect during active call to avoid interrupting it
    try {
      final socketService = Get.find<SocketService>();
      final isInCall = WebRTCCallService().isInCall;
      debugPrint(
        '📱 Socket connected: ${socketService.isConnected.value}, in call: $isInCall',
      );
      if (!socketService.isConnected.value && !isInCall) {
        debugPrint('🔄 Socket disconnected on resume, forcing reconnect...');
        socketService.forceReconnect();
      } else if (isInCall) {
        debugPrint('📱 Skipping socket reconnect — call is active');
      }
    } catch (e) {
      debugPrint('⚠️ Error checking socket: $e');
    }

    // 2. Initialize CallController if not already registered (for background accept handling)
    try {
      debugPrint('📞 Checking if CallController is registered...');
      CallController callController;
      if (!Get.isRegistered<CallController>()) {
        debugPrint('📞 CallController not registered, initializing...');
        callController = Get.put(CallController());
        debugPrint('📞 CallController initialized on app resume');
      } else {
        callController = Get.find<CallController>();
        debugPrint('📞 CallController already registered on app resume');
      }

      // Check for pending auto-accept call (for background accept handling)
      // Small delay to ensure socket is connected
      debugPrint('📞 Will check for pending auto-accept in 500ms...');
      Future.delayed(const Duration(milliseconds: 500), () {
        debugPrint('📞 Calling setPendingAutoAcceptFromStorage...');
        callController.setPendingAutoAcceptFromStorage();
      });
    } catch (e) {
      debugPrint('⚠️ Error initializing CallController: $e');
    }

    // 3. Reload messages from local storage so user sees latest messages instantly
    try {
      if (Get.isRegistered<ChatListController>()) {
        final chatListController = Get.find<ChatListController>();
        chatListController.loadChats();
        debugPrint('📋 Chat list refreshed from local storage');
      }
    } catch (e) {
      debugPrint('⚠️ Error refreshing chat list: $e');
    }

    // 4. If user is on a conversation screen, reload messages from storage
    try {
      if (Get.isRegistered<ChatController>()) {
        final chatController = Get.find<ChatController>();
        chatController.refreshMessagesFromStorage();
        debugPrint('💬 Chat messages refreshed from local storage');
      }
    } catch (e) {
      debugPrint('⚠️ Error refreshing chat messages: $e');
    }
  }

  /// Check for pending auto-accept call on app startup (for CallKit foreground without lifecycle event)
  void _checkPendingAutoAcceptOnStartup() {
    debugPrint('📞 Checking for pending auto-accept on startup');

    // Small delay to ensure services are initialized
    Future.delayed(const Duration(milliseconds: 1000), () {
      try {
        debugPrint('📞 Startup: Checking if CallController is registered...');
        CallController callController;
        if (!Get.isRegistered<CallController>()) {
          debugPrint(
            '📞 Startup: CallController not registered, initializing...',
          );
          callController = Get.put(CallController());
          debugPrint('📞 Startup: CallController initialized');
        } else {
          callController = Get.find<CallController>();
          debugPrint('📞 Startup: CallController already registered');
        }

        // Check for pending auto-accept
        debugPrint('📞 Startup: Calling setPendingAutoAcceptFromStorage...');
        callController.setPendingAutoAcceptFromStorage();

        // Auto-navigate to active call screen if call is already in progress
        // This handles cases where app was killed during an active call
        if (WebRTCCallService().isInCall || callController.isConnected) {
          debugPrint(
            '📞 Startup: Active call detected, navigating to call screen',
          );
          Future.delayed(const Duration(milliseconds: 500), () {
            if (Get.currentRoute != '/call/active') {
              Get.offAllNamed('/call/active');
            }
          });
        }
      } catch (e) {
        debugPrint('⚠️ Startup: Error checking pending auto-accept: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = FlavorConfig.instance;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: GetMaterialApp(
        title: config.appName,
        debugShowCheckedModeBanner: config.showDebugBanner,
        theme: AppTheme.lightTheme,
        themeMode: ThemeMode.light,
        initialRoute: _getInitialRoute(),
        getPages: AppRoutes.routes,

        // Status bar configuration for iOS
        builder: (context, child) {
          final appChild = MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: MediaQuery.of(
                context,
              ).textScaler.clamp(minScaleFactor: 1.0, maxScaleFactor: 1.2),
            ),
            child: child!,
          );

          // Wrap app content with call banner overlay
          final withCallBanner = Column(
            children: [
              const CallBanner(),
              Expanded(child: appChild),
            ],
          );

          // Add DEV banner for dev flavor
          if (FlavorConfig.isDev()) {
            return Banner(
              message: 'DEV',
              location: BannerLocation.topEnd,
              color: Colors.redAccent,
              child: AnnotatedRegion<SystemUiOverlayStyle>(
                value: const SystemUiOverlayStyle(
                  statusBarColor: Colors.transparent,
                  statusBarIconBrightness: Brightness.dark,
                  statusBarBrightness: Brightness.light,
                ),
                child: withCallBanner,
              ),
            );
          }

          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
            ),
            child: withCallBanner,
          );
        },
        unknownRoute: GetPage(
          name: '/unknown',
          page: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
        ),
        routingCallback: (routing) {
          if (routing?.current == null) {
            debugPrint('⚠️ Routing callback received null route, ignoring');
            return;
          }
          debugPrint('🔄 Route changed: ${routing?.current}');
        },
      ),
    );
  }
}
