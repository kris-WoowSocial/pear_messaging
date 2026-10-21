import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/local_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the native-readable contact-name cache that lets PushKit/CallKit
/// show a saved contact name when the app is killed. The store is the App
/// Group UserDefaults (group.com.vant.chatting) written through the existing
/// com.vant.chatting/app_group method channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.vant.chatting/app_group');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('contactNameCacheEntries', () {
    test('maps chat_name_* keys to callerId -> name, skips others', () async {
      SharedPreferences.setMockInitialValues({
        'chat_name_dev_1': 'Waqar',
        'chat_name_dev_2': 'Ali',
        'device_id': 'me',
        'last_seen_dev_1': 123,
        'chat_name_empty': '',
      });
      final prefs = await SharedPreferences.getInstance();
      final entries = LocalStorageService.contactNameCacheEntries(prefs);
      expect(entries, {'dev_1': 'Waqar', 'dev_2': 'Ali'});
    });

    test('respects the size limit', () async {
      SharedPreferences.setMockInitialValues({
        for (var i = 0; i < 5; i++) 'chat_name_dev_$i': 'N$i',
      });
      final prefs = await SharedPreferences.getInstance();
      final entries =
          LocalStorageService.contactNameCacheEntries(prefs, limit: 3);
      expect(entries.length, 3);
    });
  });

  group('writeContactNameToAppGroup', () {
    test('save writes the chat_name_ key to the App Group', () async {
      await LocalStorageService.writeContactNameToAppGroup('dev_1', 'Waqar');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'saveToAppGroup');
      expect(calls.single.arguments, {
        'key': 'chat_name_dev_1',
        'value': 'Waqar',
      });
    });

    test('rename overwrites the same key', () async {
      await LocalStorageService.writeContactNameToAppGroup('dev_1', 'Waqar');
      await LocalStorageService.writeContactNameToAppGroup('dev_1', 'W. Khan');
      expect(calls, hasLength(2));
      expect(calls.last.arguments['value'], 'W. Khan');
      expect(calls.last.arguments['key'], 'chat_name_dev_1');
    });

    test('null/empty name removes the key', () async {
      await LocalStorageService.writeContactNameToAppGroup('dev_1', null);
      await LocalStorageService.writeContactNameToAppGroup('dev_1', '');
      expect(calls, hasLength(2));
      for (final call in calls) {
        expect(call.method, 'removeFromAppGroup');
        expect(call.arguments, {'key': 'chat_name_dev_1'});
      }
    });
  });

  group('source inspection — the native lookup must run before CallKit', () {
    final swift = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final storage =
        File('lib/core/services/local_storage_service.dart').readAsStringSync();
    final sync =
        File('lib/core/services/username_sync_service.dart').readAsStringSync();

    String body(String src, String start, String end) {
      final s = src.indexOf(start);
      final e = src.indexOf(end, s);
      expect(s, greaterThanOrEqualTo(0), reason: 'missing: $start');
      expect(e, greaterThan(s), reason: 'missing: $end');
      return src.substring(s, e);
    }

    test('PushKit handler reads the App Group cache before showCallkitIncoming',
        () {
      final handler = body(
        swift,
        'didReceiveIncomingPushWith payload: PKPushPayload',
        'showCallkitIncoming(callData, fromPushKit: true)',
      );
      expect(handler, contains('savedContactName(for: handle)'));
      // The cache read must happen before the CallKit Data is constructed —
      // iOS requires reportNewIncomingCall synchronously in the push handler.
      expect(
        handler.indexOf('savedContactName(for: handle)'),
        lessThan(handler.indexOf('Data(id: callKitId')),
      );
      // Fallback chain: saved name -> push callerName -> neutral name.
      expect(handler, contains('"Vant Call"'));
    });

    test('savedContactName reads the App Group suite with the chat_name_ key',
        () {
      final helper = body(swift, 'private func savedContactName(', '}\n\n  //');
      expect(helper, contains('group.com.vant.chatting'));
      expect(helper, contains('chat_name_'));
    });

    test('resolved name is carried in extra so accept path shows the same name',
        () {
      final handler = body(
        swift,
        'didReceiveIncomingPushWith payload: PKPushPayload',
        'showCallkitIncoming(callData, fromPushKit: true)',
      );
      expect(handler, contains('extra["callerName"] = nameCaller'));
    });

    test('Swift message-notification paths use the same cache', () {
      // The old code read UserDefaults.standard without the flutter. prefix
      // and could never hit — every lookup must go through savedContactName.
      expect(swift, isNot(contains('UserDefaults.standard.string(forKey: "chat_name_')));
      expect(swift, contains('savedContactName(for: senderId)'));
    });

    test('Dart saveChat mirrors names to the App Group', () {
      final save = body(storage, 'Future<void> saveChat(', 'saveGroupChatFromApi');
      expect(save, contains('writeContactNameToAppGroup(chat.id, chat.userName)'));
    });

    test('Dart deleteChat removes the App Group entry', () {
      expect(storage,
          contains('writeContactNameToAppGroup(chatId, null)'));
    });

    test('init seeds the cache for existing contacts', () {
      final init = body(storage, 'Future<LocalStorageService> init()', 'return this;');
      expect(init, contains('syncContactNamesToAppGroup()'));
    });

    test('direct chat_name_ writes in username_sync_service also mirror', () {
      expect(sync,
          contains('LocalStorageService.writeContactNameToAppGroup(deviceId, username)'));
    });

    test('cache stores names only — a single string value per callerId', () {
      final helper = body(swift, 'private func savedContactName(', '}\n\n  //');
      expect(helper, contains('string(forKey: "chat_name_'));
      // The channel payload is exactly {key, value} — nothing else is stored.
      expect(storage, contains("'value': name,"));
    });
  });
}
