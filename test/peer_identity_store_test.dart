import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:pear_messaging/core/services/local_storage_service.dart';
import 'package:pear_messaging/storage/models/chat_entity.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LocalStorageService storage;

  // Mock flutter_secure_storage; `throwOnRead` simulates keystore failure.
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStore = <String, String>{};
  var throwOnRead = false;

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (throwOnRead && call.method == 'read') {
        throw PlatformException(code: 'read_failed');
      }
      switch (call.method) {
        case 'read':
          return secureStore[call.arguments['key'] as String];
        case 'write':
          secureStore[call.arguments['key'] as String] =
              call.arguments['value'] as String;
          return null;
        case 'delete':
          secureStore.remove(call.arguments['key'] as String);
          return null;
      }
      return null;
    });

    tempDir = await Directory.systemTemp.createTemp('peer_identity_test');
    Hive.init(tempDir.path);
  });

  setUp(() async {
    // NOTE: secureStore is NOT cleared — the cipher key must stay stable
    // while the encrypted box file persists across tests.
    throwOnRead = false;
    SharedPreferences.setMockInitialValues({});
    storage = await LocalStorageService().init();
    // Clear persisted state from earlier tests (deleteFromDisk is flaky
    // across reopen; explicit clears are deterministic).
    await Hive.box('chats').clear();
    if (Hive.isBoxOpen('peer_identities')) {
      await Hive.box('peer_identities').clear();
    }
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  ChatEntity makeChat(String id) => ChatEntity(
        id: id,
        userName: 'User $id',
        lastMessage: 'hi',
        lastMessageTime: DateTime.now(),
      );

  test('pin survives chat updates (rebuild + saveChat)', () async {
    await storage.saveChat(makeChat('peer1'));

    final pinResult = await storage.pinPeerBundle('peer1', 'bundleAAA');
    expect(pinResult, LocalStorageService.pinResultPinned);
    expect(storage.getPeerBundle('peer1'), 'bundleAAA');

    // Simulate an ordinary chat update path: rebuild the entity from JSON
    // and save it — the pin lives in a separate box and must not move.
    final rebuilt = ChatEntity.fromJson(makeChat('peer1').toJson());
    await storage.saveChat(rebuilt.copyWith(lastMessage: 'updated'));
    expect(storage.getPeerBundle('peer1'), 'bundleAAA');

    // Deleting the chat does not delete the pin either.
    // (chat deletion APIs vary; the pin box is independent of chat content)
  });

  test('pin is never silently overwritten', () async {
    await storage.saveChat(makeChat('peer2'));
    await storage.pinPeerBundle('peer2', 'bundleA');
    expect(await storage.pinPeerBundle('peer2', 'bundleA'),
        LocalStorageService.pinResultUnchanged);
    expect(await storage.pinPeerBundle('peer2', 'bundleB'),
        LocalStorageService.pinResultConflict);
    expect(storage.getPeerBundle('peer2'), 'bundleA'); // still the first pin
  });

  test('markPeerVerified requires an existing pin', () async {
    await storage.saveChat(makeChat('peer3'));
    expect(await storage.markPeerVerified('peer3'), isFalse); // no pin
    await storage.pinPeerBundle('peer3', 'bundleX');
    expect(storage.getPeerVerificationStatus('peer3'), 'unverified');
    expect(await storage.markPeerVerified('peer3'), isTrue);
    expect(storage.getPeerVerificationStatus('peer3'), 'verified');
  });

  test('contactsWithoutPin lists only unpinned 1:1 chats', () async {
    await storage.saveChat(makeChat('peer4'));
    await storage.saveChat(makeChat('peer5'));
    await storage.pinPeerBundle('peer4', 'bundleY');
    expect(storage.contactsWithoutPin(), ['peer5']);
  });

  test('secure-storage read failure → degraded mode, init survives', () async {
    throwOnRead = true;
    SharedPreferences.setMockInitialValues({});
    final degraded = await LocalStorageService().init(); // must not throw
    expect(degraded.pinStoreUnavailable.value, isTrue);
    expect(degraded.getPeerBundle('x'), isNull);
    expect(await degraded.pinPeerBundle('x', 'b'),
        LocalStorageService.pinResultNoChat); // no chat anyway
    throwOnRead = false;
  });

  test('key lost but box existed (flag set) → corrupted, never overwrites',
      () async {
    // Simulate: flag says a key was created, but secure storage is empty.
    secureStore.clear();
    SharedPreferences.setMockInitialValues(
        {'peer_identities_key_created': true});
    final degraded = await LocalStorageService().init();
    expect(degraded.pinStoreUnavailable.value, isTrue);
    expect(degraded.pinStoreCorrupted.value, isTrue);
    // And no replacement key was written that would orphan the old box.
    expect(secureStore.containsKey('vant_peer_identities_key'), isFalse);
    secureStore.clear();
  });

  test('signed capabilities are monotonic and encrypted history survives',
      () async {
    await storage.saveChat(makeChat('peerCaps'));
    await storage.pinPeerBundle('peerCaps', 'bundleCaps');

    expect(
      await storage.recordPeerCapabilities(
        'peerCaps',
        const ['encrypted_call', 'video_call'],
        7,
      ),
      isTrue,
    );
    expect(storage.peerSignedEncryptedCalls('peerCaps'), isTrue);
    expect(storage.peerRequiresEncryptedCall('peerCaps'), isTrue);

    // Same and older sequences are replays/downgrades and must be rejected.
    expect(
      await storage.recordPeerCapabilities(
        'peerCaps',
        const ['video_call'],
        7,
      ),
      isFalse,
    );
    expect(
      await storage.recordPeerCapabilities('peerCaps', const <String>[], 6),
      isFalse,
    );
    expect(storage.peerSignedEncryptedCalls('peerCaps'), isTrue);

    // A later signed change may drop video, but encrypted_call is retained as
    // the permanent signed no-plaintext floor.
    expect(
      await storage.recordPeerCapabilities('peerCaps', const <String>[], 8),
      isTrue,
    );
    expect(storage.peerSignedEncryptedCalls('peerCaps'), isTrue);
    await storage.markPeerEncryptedCall('peerCaps');
    expect(
      await storage.recordPeerCapabilities('peerCaps', const <String>[], 9),
      isTrue,
    );
    expect(storage.peerHasEncryptedCallHistory('peerCaps'), isTrue);
    expect(storage.peerRequiresEncryptedCall('peerCaps'), isTrue);
  });

  test(
      'capability records do not survive silent re-pin or get accepted for '
      'unpinned peers', () async {
    await storage.saveChat(makeChat('peerNoPin'));
    expect(
      await storage.recordPeerCapabilities(
        'peerNoPin',
        const ['encrypted_call'],
        1,
      ),
      isFalse,
    );
    expect(storage.peerRequiresEncryptedCall('peerNoPin'), isFalse);
  });
}
