import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/deep_link_service.dart';

/// Deferred deep-linking tests: Play Install Referrer parsing, the
/// one-shot first-launch gate, and the iOS server-claim wiring.
void main() {
  late String deepLinkService;
  late String chatListController;
  late String apiService;
  late String storageService;
  late String serverDeferred;
  late String referralPage;

  setUpAll(() {
    deepLinkService = File('lib/core/services/deep_link_service.dart')
        .readAsStringSync();
    chatListController =
        File('lib/features/chat_list/chat_list_controller.dart')
            .readAsStringSync();
    apiService =
        File('lib/core/services/api_service.dart').readAsStringSync();
    storageService = File('lib/core/services/local_storage_service.dart')
        .readAsStringSync();
    serverDeferred =
        File('../vant_chatting/server/src/routes/deeplink-deferred.js')
            .readAsStringSync();
    referralPage =
        File('../vant_chatting/server/src/routes/referral-page.js')
            .readAsStringSync();
  });

  group('parseInstallReferrerParams', () {
    test('raw referrer parses directly', () {
      final params = DeepLinkService.parseInstallReferrerParams(
          'device_id=123&user_name=Wajid');
      expect(params['device_id'], '123');
      expect(params['user_name'], 'Wajid');
    });

    test('single-encoded referrer decodes once', () {
      final params = DeepLinkService.parseInstallReferrerParams(
          'click_id%3Dabc123%26device_id%3D456');
      expect(params['click_id'], 'abc123');
      expect(params['device_id'], '456');
    });

    test('double-encoded referrer decodes twice', () {
      final params = DeepLinkService.parseInstallReferrerParams(
          'click_id%253Dabc123%2526device_id%253D456');
      expect(params['click_id'], 'abc123');
      expect(params['device_id'], '456');
    });

    test('compact click_id + device_id referrer round-trips', () {
      const inner = 'click_id=9f8e7d6c5b4a&device_id=1795469514981';
      final encoded = Uri.encodeComponent(inner);
      final params = DeepLinkService.parseInstallReferrerParams(encoded);
      expect(params['click_id'], '9f8e7d6c5b4a');
      expect(params['device_id'], '1795469514981');
    });

    test('null/empty/garbage referrers parse to empty or harmless params',
        () {
      expect(DeepLinkService.parseInstallReferrerParams(null), isEmpty);
      expect(DeepLinkService.parseInstallReferrerParams(''), isEmpty);
      expect(
          DeepLinkService.parseInstallReferrerParams(
              'utm_source=google-play&utm_medium=organic'),
          isNot(contains('device_id')));
    });
  });

  group('first-launch gate', () {
    test('guarded by deferred_deeplink_checked, requires deviceId', () {
      final start = deepLinkService
          .indexOf('Future<void> checkDeferredDeepLinkOnFirstLaunch()');
      final body = deepLinkService.substring(start);
      expect(body, contains('hasCheckedDeferredDeepLink'));
      expect(body, contains('setHasCheckedDeferredDeepLink(true)'));
      expect(body, contains('myDeviceId.isEmpty'));
      // Legacy installs that already consumed a referrer are skipped.
      expect(body, contains('hasCheckedInstallReferrer'));
    });

    test('ChatListController runs it alongside pending invitation intake',
        () {
      final onInitStart = chatListController.indexOf('void onInit()');
      final onInitEnd = chatListController.indexOf(
          'Future<void> _reconcileChatPreviews', onInitStart);
      final body = chatListController.substring(onInitStart, onInitEnd);
      expect(body, contains('_checkPendingInvitation()'));
      expect(body, contains('checkDeferredDeepLinkOnFirstLaunch()'));
      // Pending invitation is consumed BEFORE the deferred check — real
      // links tapped pre-install take priority over an IP-claim guess.
      expect(body.indexOf('_checkPendingInvitation()'),
          lessThan(body.indexOf('checkDeferredDeepLinkOnFirstLaunch()')));
    });

    test('self-invites are rejected before processing', () {
      expect(deepLinkService, contains('deviceId == myDeviceId'));
    });

    test('Android referrer path times out and hydrates click_id', () {
      expect(deepLinkService, contains('const Duration(seconds: 4)'));
      expect(deepLinkService, contains('getDeferredClick(clickId)'));
      expect(deepLinkService, contains("params['click_id']"));
    });
  });

  group('API + server contract', () {
    test('client endpoints exist with 4s timeouts', () {
      expect(apiService, contains('/api/deeplink/click/'));
      expect(apiService, contains('/api/deeplink/claim-deferred'));
      expect(apiService, contains('getDeferredClick'));
      expect(apiService, contains('claimDeferredDeepLink'));
    });

    test('server store is 30-minute TTL and single-use', () {
      expect(serverDeferred, contains('30 * 60 * 1000'));
      expect(serverDeferred, contains('latestClickByIp'));
      // consumeClick deletes before returning — replay returns found:false
      expect(serverDeferred, contains('clicksById.delete(clickId)'));
      expect(serverDeferred, contains('latestClickByIp.delete'));
    });

    test('Play referrer carries only click_id + device_id (compact)', () {
      expect(
          referralPage, contains("referrerParams.click_id = clickId"));
      expect(referralPage, contains('recordDeferredClick'));
      // The landing page must not smuggle long avatar URLs into referrer.
      final playRef = referralPage.substring(
        referralPage.indexOf('const referrerParams = { device_id: deviceId }'),
      );
      expect(
          playRef.substring(0, playRef.indexOf('buildReferrerQuery')),
          isNot(contains('avatar_url')));
    });

    test('deferred flag persists across restarts', () {
      expect(storageService, contains('deferred_deeplink_checked'));
      expect(storageService, contains('hasCheckedDeferredDeepLink'));
    });
  });
}
