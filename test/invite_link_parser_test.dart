import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/invite_link_parser.dart';

String source(String path) => File(path).readAsStringSync();

/// iOS install flow: when the Branch install match fails (paste prompt
/// denied / "Get the App without Copying" / fingerprint miss) the user can
/// paste the invite link into a normal text field — which does NOT trigger
/// the system pasteboard prompt. The parser must recognise real invite
/// shapes and reject garbage.
void main() {
  group('paste-link parser', () {
    test('vantchat custom scheme link yields device_id and user_name', () {
      final p = parseInviteLink(
        'vantchat://chat?device_id=dev_abc123&user_name=Alice',
      )!;
      expect(p.isBranchLink, isFalse);
      expect(p.deviceId, 'dev_abc123');
      expect(p.userName, 'Alice');
    });

    test('QR payload URL (vant.chat/chat?device_id=) is accepted', () {
      final p =
          parseInviteLink('https://vant.chat/chat?device_id=dev_xyz789')!;
      expect(p.deviceId, 'dev_xyz789');
      expect(p.userName, isNull);
    });

    test('Branch quick link carrying device_id params resolves directly', () {
      final p = parseInviteLink(
        'https://vantchatting.app.link/?device_id=dev_q1&user_name=Bob',
      )!;
      expect(p.isBranchLink, isFalse);
      expect(p.deviceId, 'dev_q1');
      expect(p.userName, 'Bob');
    });

    test('opaque Branch short link is marked for SDK resolution', () {
      final p = parseInviteLink('https://vantchatting.app.link/AbCdEf')!;
      expect(p.isBranchLink, isTrue);
      expect(p.branchUrl, 'https://vantchatting.app.link/AbCdEf');
    });

    test('alternate Branch domain is recognised', () {
      final p = parseInviteLink(
        'https://vantchatting-alternate.app.link/xyz',
      )!;
      expect(p.isBranchLink, isTrue);
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
      // app.link with device_id would have resolved; bare other-domain URL is
      // rejected so random pasted links can't create phantom contacts.
      expect(parseInviteLink('https://vant.chat/chat'), isNull);
    });
  });

  group('unmatched-invite decision logic', () {
    final splash = source('lib/features/splash/splash_controller.dart');
    final branch = source('lib/core/services/branch_service.dart');
    final fcm = source('lib/core/services/fcm_service.dart');

    test('iOS first launch holds Branch init until the gate opens', () {
      expect(branch, contains('Platform.isIOS'));
      expect(branch, contains('InvitePromptGate.pasteCheckReady'));
      expect(
        branch.indexOf('pasteCheckReady'),
        lessThan(branch.indexOf('await FlutterBranchSdk.init(')),
      );
      // timed out — a stuck gate can never kill deep linking
      expect(branch, contains('Duration(seconds: 120)'));
    });

    test('explainer runs before the gate opens (pre-prompt)', () {
      expect(splash, contains('InviteFallbackSheet.showPasteExplainer()'));
      expect(
        splash.indexOf('showPasteExplainer()'),
        lessThan(splash.indexOf('InvitePromptGate.allowPasteCheck()')),
      );
      // wait for the name sheet first so prompts do not stack
      expect(splash, contains('_waitForInitialNameSetup'));
    });

    test('unmatched invite on iOS shows the fallback sheet', () {
      expect(splash, contains('iosInviteOnboarding'));
      expect(splash, contains('InviteFallbackSheet.show()'));
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

    test('AppDelegate skips the early prompt only on first launch', () {
      final appDelegate = source('ios/Runner/AppDelegate.swift');
      expect(
        appDelegate,
        contains('flutter.initial_name_setup_completed'),
      );
      expect(appDelegate, contains('requestAuthorization'));
    });
  });
}
