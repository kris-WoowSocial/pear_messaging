import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'core/theme/app_theme.dart';
import 'core/services/socket_service.dart';
import 'features/chat_list/chat_list_controller.dart';
import 'features/chat/chat_controller.dart';
import 'routes/app_routes.dart';

class PearMessagingApp extends StatefulWidget {
  final bool skipSplash;

  const PearMessagingApp({
    super.key,
    this.skipSplash = false,
  });

  @override
  State<PearMessagingApp> createState() => _PearMessagingAppState();
}

class _PearMessagingAppState extends State<PearMessagingApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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

    // 1. Force reconnect if socket is disconnected — Android Doze mode kills
    // WebSocket connections and the internal retry counter may be exhausted
    try {
      final socketService = Get.find<SocketService>();
      if (!socketService.isConnected.value) {
        debugPrint('🔄 Socket disconnected on resume, forcing reconnect...');
        socketService.forceReconnect();
      }
    } catch (e) {
      debugPrint('⚠️ Error checking socket: $e');
    }

    // 2. Reload messages from local storage so user sees latest messages instantly
    try {
      if (Get.isRegistered<ChatListController>()) {
        final chatListController = Get.find<ChatListController>();
        chatListController.loadChats();
        debugPrint('📋 Chat list refreshed from local storage');
      }
    } catch (e) {
      debugPrint('⚠️ Error refreshing chat list: $e');
    }

    // 3. If user is on a conversation screen, reload messages from storage
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: GetMaterialApp(
        title: 'Pear Messaging',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        themeMode: ThemeMode.light,
        initialRoute: _getInitialRoute(),
        getPages: AppRoutes.routes,

        // Status bar configuration for iOS
        builder: (context, child) {
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
            ),
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: MediaQuery.of(context).textScaler.clamp(
                      minScaleFactor: 1.0,
                      maxScaleFactor: 1.2,
                    ),
              ),
              child: child!,
            ),
          );
        },
        unknownRoute: GetPage(
          name: '/unknown',
          page: () => const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          ),
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
