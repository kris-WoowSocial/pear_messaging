import 'package:get/get.dart';
import '../features/splash/splash_screen.dart';
import '../features/splash/splash_controller.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/onboarding/onboarding_controller.dart';
import '../features/chat_list/chat_list_screen.dart';
import '../features/chat_list/chat_list_controller.dart';
import '../features/chat/chat_screen.dart';
import '../features/chat/chat_controller.dart';
import '../features/profile/profile_screen.dart';
import '../features/profile/profile_controller.dart';
import '../features/qr_scanner/qr_scanner_screen.dart';
import '../features/qr_scanner/qr_scanner_controller.dart';
import '../features/notification_permission/notification_permission_screen.dart';
import '../features/membership/membership_screen.dart';
import '../features/membership/membership_controller.dart';
import '../features/call/call_controller.dart';
import '../features/call/incoming_call_screen.dart';
import '../features/call/outgoing_call_screen.dart';
import '../features/call/active_call_screen.dart';

class AppRoutes {
  static const String notificationPermission = '/notification-permission';
  static const String splash = '/splash';
  static const String onboarding = '/onboarding';
  static const String chatList = '/chat-list';
  static const String chat = '/chat';
  static const String profile = '/profile';
  static const String qrScanner = '/qr-scanner';
  static const String membership = '/membership';
  static const String callIncoming = '/call/incoming';
  static const String callOutgoing = '/call/outgoing';
  static const String callActive = '/call/active';

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
    GetPage(
      name: chatList,
      page: () => ChatListScreen(),
      binding: BindingsBuilder(() {
        Get.put(ChatListController());
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
      name: membership,
      page: () => const MembershipScreen(),
      binding: BindingsBuilder(() {
        Get.put(MembershipController());
      }),
    ),
    GetPage(
      name: callIncoming,
      page: () => const IncomingCallScreen(),
      binding: BindingsBuilder(() {
        Get.put(CallController());
      }),
    ),
    GetPage(
      name: callOutgoing,
      page: () => const OutgoingCallScreen(),
      binding: BindingsBuilder(() {
        Get.put(CallController());
      }),
    ),
    GetPage(
      name: callActive,
      page: () => const ActiveCallScreen(),
      binding: BindingsBuilder(() {
        Get.put(CallController());
      }),
    ),
  ];
}
