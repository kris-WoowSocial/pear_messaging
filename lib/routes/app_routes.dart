import 'package:get/get.dart';
import '../features/splash/splash_screen.dart';
import '../features/splash/splash_controller.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/onboarding/onboarding_controller.dart';
import '../features/main/main_navigation_screen.dart';
import '../features/chat_list/chat_list_controller.dart';
import '../features/chat/chat_screen.dart';
import '../features/chat/chat_controller.dart';
import '../features/profile/profile_screen.dart';
import '../features/profile/profile_controller.dart';
import '../features/qr_scanner/qr_scanner_screen.dart';
import '../features/qr_scanner/qr_scanner_controller.dart';
import '../features/notification_permission/notification_permission_screen.dart';
import '../features/membership/stripe_subscription_screen.dart';
import '../features/call/incoming_call_screen.dart';
import '../features/call/outgoing_call_screen.dart';
import '../features/call/active_call_screen.dart';
import '../features/call/call_controller.dart';
import '../features/call_history/call_history_screen.dart';
import '../features/call_history/call_history_controller.dart';
import '../features/groups/create_group_screen.dart';
import '../features/groups/group_settings_screen.dart';

class AppRoutes {
  static const String notificationPermission = '/notification-permission';
  static const String splash = '/splash';
  static const String onboarding = '/onboarding';
  static const String main = '/main'; // 3-tab navigation
  static const String chatList = '/chat-list'; // Kept for compatibility
  static const String chat = '/chat';
  static const String profile = '/profile';
  static const String qrScanner = '/qr-scanner';
  static const String membership = '/membership';
  static const String stripeSubscription = '/stripe-subscription';
  static const String callIncoming = '/call/incoming';
  static const String callOutgoing = '/call/outgoing';
  static const String callActive = '/call/active';
  static const String callHistory = '/call-history';
  static const String createGroup = '/create-group';
  static const String groupSettings = '/group-settings';

  static final routes = [
    GetPage(
      name: notificationPermission,
      page: () => const NotificationPermissionScreen(),
    ),
    GetPage(
      name: splash,
      page: () => const SplashScreen(),
      binding: BindingsBuilder(() {
        Get.put(SplashController());
      }),
    ),
    GetPage(
      name: onboarding,
      page: () => const OnboardingScreen(),
      binding: BindingsBuilder(() {
        Get.put(OnboardingController());
      }),
    ),
    // Main navigation with 3 tabs (Invite | Chats | Calls)
    GetPage(
      name: main,
      page: () => const MainNavigationScreen(),
      binding: BindingsBuilder(() {
        Get.put(ChatListController());
        Get.put(CallHistoryController());
        Get.put(CallController());
      }),
    ),

    // Legacy route - redirects to main navigation (Chats tab)
    GetPage(
      name: chatList,
      page: () => const MainNavigationScreen(),
      binding: BindingsBuilder(() {
        Get.put(ChatListController());
        Get.put(CallHistoryController());
        Get.put(CallController());
      }),
    ),

    // Individual screens (for deep linking/navigation)
    GetPage(
      name: callHistory,
      page: () => const CallHistoryScreen(),
      binding: BindingsBuilder(() {
        Get.put(CallHistoryController());
      }),
    ),
    GetPage(
      name: chat,
      page: () => const ChatScreen(),
      binding: BindingsBuilder(() {
        Get.put(ChatController());
      }),
    ),
    GetPage(
      name: createGroup,
      page: () => const CreateGroupScreen(),
    ),
    GetPage(
      name: groupSettings,
      page: () => const GroupSettingsScreen(),
    ),
    GetPage(
      name: profile,
      page: () => const ProfileScreen(),
      binding: BindingsBuilder(() {
        Get.put(ProfileController());
      }),
    ),
    GetPage(
      name: qrScanner,
      page: () => const QRScannerScreen(),
      binding: BindingsBuilder(() {
        Get.put(QRScannerController());
      }),
    ),
    GetPage(
      name: stripeSubscription,
      page: () => const StripeSubscriptionScreen(),
    ),
    GetPage(
      name: callIncoming,
      page: () => const IncomingCallScreen(),
      binding: BindingsBuilder(() {
        if (!Get.isRegistered<CallController>()) {
          Get.put(CallController());
        }
      }),
    ),
    GetPage(
      name: callOutgoing,
      page: () => const OutgoingCallScreen(),
      binding: BindingsBuilder(() {
        if (!Get.isRegistered<CallController>()) {
          Get.put(CallController());
        }
      }),
    ),
    GetPage(
      name: callActive,
      page: () => const ActiveCallScreen(),
      binding: BindingsBuilder(() {
        if (!Get.isRegistered<CallController>()) {
          Get.put(CallController());
        }
      }),
    ),
  ];
}
