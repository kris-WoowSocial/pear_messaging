import 'dart:async';
import 'dart:io' show Platform;
import 'package:android_play_install_referrer/android_play_install_referrer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:share_plus/share_plus.dart';
import 'local_storage_service.dart';
import 'api_service.dart';
import 'user_profile_cache.dart';
import 'invitation_storage_service.dart';
import '../../routes/app_routes.dart';
import '../../storage/models/connection_request_entity.dart';
import '../../storage/models/message_entity.dart';
import '../../features/chat_list/chat_list_controller.dart';

/// First-party deep-link service (replaces Branch.io entirely).
///
/// Link shapes handled:
///  - `https://vant.chat/chat?device_id=..&user_name=..&avatar_url=..&referral_code=..`
///    (share links + profile QR payload + Play-Store `referrer=` payload)
///  - `https://vant.chat/referral?code=..&device_id=..` (influencer portal links)
///  - `vantchat://chat?device_id=..` (custom-scheme fallback from the landing page)
///
/// Delivery channels:
///  - `com.pear.messaging/deeplink` — native pushes `onDeepLink` for warm
///    (running-app) link taps on both platforms.
///  - `com.pear.messaging.pear_messaging/applinks` `getInitialLink` — cold-start
///    pull so a launch-time link is never lost before the Dart handler exists.
///  - Play Install Referrer — Android deferred attribution: the landing page
///    redirects to the Play Store with `&referrer=<encoded params>` and Google
///    Play hands that exact string back on first launch.
class DeepLinkService extends GetxService {
  final LocalStorageService _storageService = Get.find();

  static const MethodChannel _channel = MethodChannel(
    'com.pear.messaging/deeplink',
  );
  static const MethodChannel _appLinksChannel = MethodChannel(
    'com.pear.messaging.pear_messaging/applinks',
  );

  // Global flag to prevent duplicate navigation across services
  static bool isGloballyNavigating = false;
  static String? lastGlobalDeviceId;
  static DateTime? lastGlobalNavigationTime;

  // Flag to prevent duplicate navigation within this service
  static bool _isNavigating = false;
  static String? _lastNavigatedDeviceId;
  static DateTime? _lastNavigationTime;

  // Duplicate processing guard, keyed by the incoming URL string.
  static final Set<String> _processedUrls = {};

  /// Initialize deep link service
  Future<DeepLinkService> init() async {
    debugPrint('🔗 Initializing Deep Link Service...');

    try {
      _channel.setMethodCallHandler(_handleMethodCall);

      // Cold start: pull the launch-time link from native. iOS delivers
      // continueUserActivity after didFinishLaunching and stashes it for this
      // query; Android reads it from the launch intent.
      try {
        final initialLink =
            await _appLinksChannel.invokeMethod<String>('getInitialLink');
        if (initialLink != null && initialLink.isNotEmpty) {
          debugPrint('🔗 Initial deep link (cold start): $initialLink');
          await handleIncomingLink(initialLink, isColdStart: true);
        }
      } catch (e) {
        debugPrint('⚠️ getInitialLink failed: $e');
      }

      // Android deferred attribution: a fresh install that arrived via an
      // invite link's Play Store redirect carries the invite params in the
      // install referrer. One-time check — flag persisted so retries don't
      // re-trigger invite processing on later launches.
      if (Platform.isAndroid) {
        await _checkInstallReferrer();
      }

      // Recovery pass: if a link raced ahead of the navigator it was stored
      // as a pending invitation — process it once the app is fully up.
      Future.delayed(const Duration(seconds: 2), () {
        _checkPendingInvitations();
      });

      debugPrint('✅ Deep Link Service initialized');
      return this;
    } catch (e) {
      debugPrint('❌ Error initializing Deep Link Service: $e');
      return this;
    }
  }

  /// Check whether the app is the verified handler for vant.chat links
  /// (Android only; iOS universal links need no equivalent setting).
  Future<bool> isDefaultLinkHandler() async {
    if (!Platform.isAndroid) return true;
    try {
      final result =
          await _appLinksChannel.invokeMethod<bool>('isDefaultLinkHandler');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('❌ Failed to check default link handler: ${e.message}');
      return false;
    }
  }

  /// Open system settings so the user can approve vant.chat link handling
  /// (Android only).
  Future<void> requestDefaultLinkHandler() async {
    if (!Platform.isAndroid) return;
    try {
      await _appLinksChannel.invokeMethod('requestDefaultLinkHandler');
    } on PlatformException catch (e) {
      debugPrint('❌ Failed to request default link handler: ${e.message}');
    }
  }

  /// First launch on Android: read the Play Install Referrer and feed any
  /// invite params into the cold-start flow.
  Future<void> _checkInstallReferrer() async {
    if (_storageService.hasCheckedInstallReferrer) return;
    await _storageService.setHasCheckedInstallReferrer(true);
    try {
      final details = await AndroidPlayInstallReferrer.installReferrer;
      final referrer = details.installReferrer;
      if (referrer == null || referrer.isEmpty) return;

      debugPrint('🔗 Install referrer: $referrer');
      final params = Uri.parse('https://vant.chat/x?$referrer').queryParameters;
      final deviceId =
          params['device_id']?.trim() ?? params['chat_device_id']?.trim();
      if (deviceId == null || deviceId.isEmpty) return;

      await _processInviteParams(
        deviceId: deviceId,
        userName: params['user_name'],
        avatarUrl: params['avatar_url'],
        referralCode: params['referral_code'],
        isColdStart: true,
      );
    } catch (e) {
      // No Play Services / no referrer — normal for side-loads and iOS-parity.
      debugPrint('⚠️ Install referrer unavailable: $e');
    }
  }

  /// Handle method calls from native (warm-link pushes)
  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onDeepLink') {
      final arguments = call.arguments as Map<dynamic, dynamic>;
      final url = arguments['url'] as String?;
      if (url != null && url.isNotEmpty) {
        debugPrint('🔗 Deep link received from native: $url');
        await handleIncomingLink(url);
      }
    }
  }

  /// Entry point for any deep-link URL (warm pushes, cold-start pull, pasted
  /// links). Parses invite params and routes to the right path.
  Future<void> handleIncomingLink(
    String url, {
    bool isColdStart = false,
  }) async {
    if (_processedUrls.contains(url)) {
      debugPrint('🔗 Duplicate deep link, skipping: $url');
      return;
    }
    _processedUrls.add(url);

    final uri = Uri.tryParse(url);
    if (uri == null) {
      debugPrint('⚠️ Could not parse deep link: $url');
      return;
    }

    final host = uri.host.toLowerCase();
    final isVantScheme = uri.scheme == 'vantchat';
    final isVantDomain =
        host == 'vant.chat' || host == 'www.vant.chat';
    if (!isVantScheme && !isVantDomain) {
      debugPrint('⚠️ Ignoring non-Vant deep link: $url');
      return;
    }

    final deviceId = uri.queryParameters['device_id']?.trim() ??
        uri.queryParameters['chat_device_id']?.trim();
    if (deviceId == null || deviceId.isEmpty) {
      debugPrint('⚠️ Deep link carries no device_id: $url');
      return;
    }

    await _processInviteParams(
      deviceId: deviceId,
      userName: uri.queryParameters['user_name'],
      avatarUrl: uri.queryParameters['avatar_url'] ??
          uri.queryParameters['inviter_avatar_url'],
      referralCode:
          uri.queryParameters['referral_code'] ?? uri.queryParameters['code'],
      isColdStart: isColdStart,
    );
  }

  /// Shared invite processing for links and the install referrer: avatar
  /// hydration, pending-invitation + referral-context storage, then cold or
  /// warm handling.
  Future<void> _processInviteParams({
    required String deviceId,
    String? userName,
    String? avatarUrl,
    String? referralCode,
    required bool isColdStart,
  }) async {
    // Hydrate the inviter's avatar immediately — every surface renders it
    // before the chat even opens.
    if (avatarUrl != null &&
        avatarUrl.isNotEmpty &&
        Get.isRegistered<UserProfileCache>()) {
      unawaited(Get.find<UserProfileCache>().setAvatar(deviceId, avatarUrl));
      unawaited(
        Get.find<UserProfileCache>().fetchAndCacheProfile(deviceId),
      );
    }

    // Persist for splash/first-launch handling plus referral attribution.
    try {
      final invitationService = Get.find<InvitationStorageService>();
      await invitationService.storePendingInvitation(
        deviceId: deviceId,
        userName: userName?.trim().isNotEmpty == true
            ? userName!.trim()
            : _storageService.getDisplayName(deviceId),
      );
      await invitationService.storeReferralContext(
        inviterDeviceId: deviceId,
        influencerCode: referralCode,
      );
    } catch (e) {
      debugPrint('⚠️ InvitationStorageService not available: $e');
    }

    // The navigator may not exist yet (services init, splash, onboarding) —
    // the pending invitation we just stored is picked up by the splash
    // controller, which owns the connection-request card flow.
    final navigatorReady = Get.context != null &&
        Get.currentRoute != '/' &&
        Get.currentRoute != AppRoutes.splash &&
        Get.currentRoute != AppRoutes.onboarding;
    if (isColdStart || !navigatorReady) {
      debugPrint(
        '🔗 Cold path: stored pending invitation for $deviceId '
        '(coldStart: $isColdStart, navigatorReady: $navigatorReady)',
      );
      return;
    }

    await _handleDeepLink(deviceId, inviterName: userName);
  }

  /// Recovery for a pending invitation that was stored while the navigator
  /// wasn't ready — runs once, shortly after init.
  void _checkPendingInvitations() {
    try {
      if (!Get.isRegistered<InvitationStorageService>()) return;
      final invitationService = Get.find<InvitationStorageService>();
      final pendingInvitation = invitationService.getPendingInvitation();
      if (pendingInvitation == null) return;

      final currentRoute = Get.currentRoute;
      if (currentRoute == '/chat') {
        invitationService.clearPendingInvitation();
        return;
      }
      // Splash/onboarding owns the pending-invitation flow — don't double.
      if (currentRoute == '/splash' ||
          currentRoute == '/onboarding' ||
          currentRoute == '/' ||
          Get.context == null) {
        return;
      }

      _handleDeepLink(
        pendingInvitation['deviceId']!,
        inviterName: pendingInvitation['userName'],
      );
      invitationService.clearPendingInvitation();
    } catch (e) {
      debugPrint('⚠️ Error checking pending invitations: $e');
    }
  }

  /// Handle an invite for a specific device while the app is running:
  /// existing chat → open it; pending request → chat list; new → create the
  /// connection request and go to the chat list.
  Future<void> _handleDeepLink(
    String deviceId, {
    String? inviterName,
  }) async {
    final linkUserName = inviterName?.trim().isNotEmpty == true
        ? inviterName!.trim()
        : _storageService.getDisplayName(deviceId);

    final now = DateTime.now();
    if (isGloballyNavigating &&
        lastGlobalDeviceId == deviceId &&
        lastGlobalNavigationTime != null &&
        now.difference(lastGlobalNavigationTime!).inSeconds < 3) {
      debugPrint('🔗 Global duplicate deep link, skipping navigation');
      return;
    }
    if (_isNavigating &&
        _lastNavigatedDeviceId == deviceId &&
        _lastNavigationTime != null &&
        now.difference(_lastNavigationTime!).inSeconds < 3) {
      debugPrint('🔗 Local duplicate deep link, skipping navigation');
      return;
    }

    final currentRoute = Get.currentRoute;
    if (currentRoute == AppRoutes.chat) {
      debugPrint('🔗 Already in chat screen, skipping deep link navigation');
      return;
    }

    isGloballyNavigating = true;
    lastGlobalDeviceId = deviceId;
    lastGlobalNavigationTime = now;
    _isNavigating = true;
    _lastNavigatedDeviceId = deviceId;
    _lastNavigationTime = now;

    try {
      final existingChat = _storageService.getChat(deviceId);
      final existingRequests = _storageService.getPendingConnectionRequests();
      final hasExistingRequest = existingRequests.any((request) =>
          request.senderDeviceId == deviceId ||
          request.receiverDeviceId == deviceId);

      if (existingChat != null) {
        debugPrint('📱 Opening existing chat with: ${existingChat.userName}');
        Get.offAllNamed(AppRoutes.chat, arguments: {
          'chatId': deviceId,
          'userName': existingChat.userName,
          'recipientDeviceId': deviceId,
          'myDeviceId': _storageService.deviceId,
        });
      } else if (hasExistingRequest) {
        debugPrint('📱 Connection request already pending for: $linkUserName');
        Get.offAllNamed(AppRoutes.chatList);
        try {
          Get.find<ChatListController>().loadConnectionRequests();
        } catch (e) {
          debugPrint('⚠️ Error reloading connection requests: $e');
        }
        Get.snackbar(
          'Connection Request',
          'Connection request already pending for $linkUserName',
          snackPosition: SnackPosition.TOP,
          backgroundColor: Colors.orange.shade100,
          colorText: Colors.orange.shade800,
        );
      } else {
        debugPrint('📱 Creating connection request for: $linkUserName');
        try {
          final connectionRequest = ConnectionRequestEntity(
            id: 'req_${DateTime.now().millisecondsSinceEpoch}',
            senderDeviceId: deviceId,
            receiverDeviceId: _storageService.deviceId!,
            timestamp: DateTime.now(),
            status: ConnectionRequestStatus.pending,
            messageContent: null,
            messageType: MessageType.text,
            senderName: linkUserName,
          );
          await _storageService.saveConnectionRequest(connectionRequest);

          final chatListController = Get.find<ChatListController>();
          chatListController.pendingConnectionRequests.add(connectionRequest);
          chatListController.loadChats();

          Get.offAllNamed(AppRoutes.chatList);
          Get.snackbar(
            'Connection Request',
            'New connection request from $linkUserName',
            snackPosition: SnackPosition.TOP,
            backgroundColor: Colors.blue.shade100,
            colorText: Colors.blue.shade800,
          );
        } catch (e) {
          debugPrint('⚠️ Error creating connection request: $e');
          Get.offAllNamed(AppRoutes.chatList);
        }
      }
    } catch (e) {
      debugPrint('❌ Error handling deep link: $e');
      debugPrint('❌ Stack trace: ${StackTrace.current}');
    } finally {
      isGloballyNavigating = false;
      lastGlobalDeviceId = null;
      lastGlobalNavigationTime = null;
      _isNavigating = false;
      _lastNavigatedDeviceId = null;
      _lastNavigationTime = null;
    }
  }

  /// Generate the canonical first-party share link:
  /// `https://vant.chat/chat?device_id=..&user_name=..[&avatar_url=..][&referral_code=..]`
  Future<String> generateShareLink() async {
    final deviceId = _storageService.deviceId;
    if (deviceId == null) {
      throw Exception('Device ID not available');
    }

    final friendlyName = _storageService.getDisplayName(deviceId);
    debugPrint('📎 Generating vant.chat link for device: $deviceId');

    // If this device is linked to an influencer, use the influencer's referral
    // code so shares from the app and from the dashboard are attributed the same way.
    String? influencerCode;
    try {
      final influencerData =
          await ApiService.to.getInfluencerByDeviceId(deviceId);
      if (influencerData != null) {
        final influencer =
            influencerData['influencer'] as Map<String, dynamic>;
        if (influencer['status'] == 'active') {
          influencerCode = influencer['referralCode'] as String?;
          debugPrint('🔗 Device linked to influencer $influencerCode');
        }
      }
    } catch (e) {
      debugPrint(
          '⚠️ Could not fetch linked influencer, falling back to plain share: $e');
    }

    // Only public https avatars can ride the link — link-preview crawlers
    // (and the landing page's og:image) can't fetch anything else.
    final cachedAvatar = Get.isRegistered<UserProfileCache>()
        ? Get.find<UserProfileCache>().myAvatarUrl.value
        : '';
    final inviterAvatarUrl =
        cachedAvatar.startsWith('https://') ? cachedAvatar : '';

    return Uri.https('vant.chat', '/chat', {
      'device_id': deviceId,
      'user_name': friendlyName,
      if (inviterAvatarUrl.isNotEmpty) 'avatar_url': inviterAvatarUrl,
      if (influencerCode != null && influencerCode.isNotEmpty)
        'referral_code': influencerCode,
    }).toString();
  }

  /// Share app with the first-party link
  Future<void> shareApp({Rect? sharePositionOrigin}) async {
    try {
      final deviceId = _storageService.deviceId;
      if (deviceId == null) {
        throw Exception('Device ID not available');
      }

      final friendlyName = _storageService.getDisplayName(deviceId);
      final link = await generateShareLink();
      debugPrint('✅ Generated vant.chat link: $link');

      final message = '''Hi! Let's chat on Vant Chat🔒

    I'm $friendlyName. Click this link to start chatting:

  $link

Once installed, the connection will be established automatically, and you can begin messaging me.

Experience total privacy with military-grade encryption and a direct, peer-to-peer connection that bypasses third-party servers entirely.''';

      await Share.share(
        message,
        subject: 'Chat with me on Vant Chat',
        sharePositionOrigin: sharePositionOrigin,
      );
      debugPrint('✅ App shared successfully');
    } catch (e) {
      debugPrint('❌ Error sharing app: $e');
      Get.snackbar(
        'Share Failed',
        'Unable to share the app. Please try again.',
        snackPosition: SnackPosition.TOP,
      );
    }
  }
}
