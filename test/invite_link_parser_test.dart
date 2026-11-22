import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/invite_link_parser.dart';

String source(String path) => File(path).readAsStringSync();

/// iOS install flow: iOS has no first-party deferred deep-link mechanism, so
/// a fresh install that didn't arrive via a universal link gets no invite
/// automatically. The user can paste the invite link into a normal text
/// field — which does NOT trigger the system pasteboard prompt. The parser
/// must recognise real invite shapes, flag retired legacy links, and reject
/// garbage.
void main() {
  group('paste-link parser', () {
    test('vantchat custom scheme link yields device_id and user_name', () {
      final p = parseInviteLink(
        'vantchat://chat?device_id=dev_abc123&user_name=Alice',
      )!;
      expect(p.isLegacyLink, isFalse);
      expect(p.deviceId, 'dev_abc123');
      expect(p.userName, 'Alice');
    });

    test('vant.chat/chat link yields device_id, user_name and avatar', () {
      final p = parseInviteLink(
        'https://vant.chat/chat?device_id=dev_xyz789'
        '&user_name=Bob&avatar_url=https%3A%2F%2Fcdn.x%2Fa.png',
      )!;
      expect(p.isLegacyLink, isFalse);
      expect(p.deviceId, 'dev_xyz789');
      expect(p.userName, 'Bob');
      expect(p.avatarUrl, 'https://cdn.x/a.png');
    });

    test('vant.chat/referral link yields referral code', () {
      final p = parseInviteLink(
        'https://vant.chat/referral?code=INF42&device_id=dev_r1',
      )!;
      expect(p.deviceId, 'dev_r1');
      expect(p.referralCode, 'INF42');
    });

    test('referral_code param is captured on /chat links', () {
      final p = parseInviteLink(
        'https://vant.chat/chat?device_id=dev_r2&referral_code=CODE9',
      )!;
      expect(p.deviceId, 'dev_r2');
      expect(p.referralCode, 'CODE9');
    });

    test('chat_device_id param is accepted', () {
      final p = parseInviteLink(
        'https://vant.chat/chat?chat_device_id=dev_alt',
      )!;
      expect(p.deviceId, 'dev_alt');
    });

    test('legacy app.link URL with device_id still resolves', () {
      final p = parseInviteLink(
        'https://vantchatting.app.link/?device_id=dev_q1&user_name=Bob',
      )!;
      expect(p.isLegacyLink, isFalse);
      expect(p.deviceId, 'dev_q1');
      expect(p.userName, 'Bob');
    });

    test('opaque legacy app.link URL is flagged as expired', () {
      final p = parseInviteLink('https://vantchatting.app.link/AbCdEf')!;
      expect(p.isLegacyLink, isTrue);
      expect(p.deviceId, 'https://vantchatting.app.link/AbCdEf');
    });

    test('alternate legacy domain is flagged too', () {
      final p = parseInviteLink(
        'https://vantchatting-alternate.app.link/xyz',
      )!;
      expect(p.isLegacyLink, isTrue);
    });

    test('whitespace and newlines are trimmed', () {
      final p = parseInviteLink(
        '  vantchat://chat?device_id=dev_pad\n',
      )!;
      expect(p.deviceId, 'dev_pad');
    });

    test('garbage is rejected', () {
      expect(parseInviteLink(''), isNull);
      expect(parseInviteLink('   '), isNull);
      expect(parseInviteLink('hello world'), isNull);
      expect(parseInviteLink('not a url at all'), isNull);
      expect(parseInviteLink('https://example.com/page'), isNull);
      expect(parseInviteLink('ftp://files.example.com/x'), isNull);
      // vant.chat with no device_id has nothing to connect to — rejected so
      // random pasted links can't create phantom contacts.
      expect(parseInviteLink('https://vant.chat/chat'), isNull);
    });
  });

  group('first-party deep link wiring', () {
    final deepLink = source('lib/core/services/deep_link_service.dart');
    final splash = source('lib/features/splash/splash_controller.dart');
    final fcm = source('lib/core/services/fcm_service.dart');

    test('deep link service consumes native pushes and the cold-start pull', () {
      expect(deepLink, contains("'com.pear.messaging/deeplink'"));
      expect(deepLink, contains("'onDeepLink'"));
      expect(
        deepLink,
        contains("'com.pear.messaging.pear_messaging/applinks'"),
      );
      expect(deepLink, contains("'getInitialLink'"));
    });

    test('deep link service reads the Play Install Referrer once', () {
      expect(deepLink, contains('AndroidPlayInstallReferrer.installReferrer'));
      expect(deepLink, contains('hasCheckedInstallReferrer'));
      expect(deepLink, contains('setHasCheckedInstallReferrer(true)'));
    });

    test('share link generation is first-party vant.chat', () {
      expect(deepLink, contains("Uri.https('vant.chat', '/chat'"));
      expect(deepLink, isNot(contains('app.link')));
      expect(deepLink, isNot(contains('branch')));
    });

    test('invite params feed the pending-invitation and referral stores', () {
      expect(deepLink, contains('storePendingInvitation'));
      expect(deepLink, contains('storeReferralContext'));
      expect(deepLink, contains('UserProfileCache'));
    });

    test('unmatched invite on iOS still shows the fallback sheet', () {
      expect(splash, contains('iosInviteOnboarding'));
      expect(splash, contains('InviteFallbackSheet.show()'));
    });

    test('no paste explainer or Branch gate remains in splash', () {
      expect(splash, isNot(contains('showPasteExplainer')));
      expect(splash, isNot(contains('allowPasteCheck')));
      expect(splash, isNot(contains('Branch')));
    });

    test('notification permission is deferred until the invite step', () {
      expect(fcm, contains('InvitePromptGate.inviteDone'));
      expect(
        fcm.indexOf('InvitePromptGate.inviteDone'),
        lessThan(fcm.indexOf('_messaging.requestPermission')),
      );
      expect(splash, contains('InvitePromptGate.inviteStepDone()'));
    });

    test('Android keeps the original behavior — no gate, no sheet', () {
      // gating is explicitly Platform.isIOS-scoped
      expect(splash, contains('Platform.isIOS &&'));
      expect(fcm, contains('Platform.isIOS'));
    });

    test('no Branch SDK references remain in production lib/', () {
      // invite_link_parser + invite_fallback_sheet legitimately reference the
      // retired app.link domain to detect & flag expired legacy links.
      const legacyExempt = {
        'lib/core/services/invite_link_parser.dart',
        'lib/features/invite/invite_fallback_sheet.dart',
      };
      final libDir = Directory('lib');
      final offenders = <String>[];
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final text = entity.readAsStringSync();
        if (text.contains('flutter_branch_sdk') ||
            text.contains('FlutterBranchSdk') ||
            text.contains('key_live_') ||
            text.contains('api2.branch.io') ||
            (!legacyExempt.contains(entity.path) &&
                text.contains('app.link'))) {
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty, reason: 'Branch remnants: $offenders');
    });
  });
}
