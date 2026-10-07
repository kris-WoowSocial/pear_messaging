import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Mocks the flutter_secure_storage method channel with an in-memory map.
// 'throwOnRead' simulates a keystore/keychain failure; 'corrupt' lets a test
// write data that fails the bundle-vs-seed check.
class _FakeSecureStorage {
  _FakeSecureStorage() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }
  static const _channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final Map<String, String> store = {};
  bool throwOnRead = false;

  Future<dynamic> _handle(MethodCall call) async {
    if (throwOnRead && call.method == 'read') {
      throw PlatformException(code: 'read_failed', message: 'keystore error');
    }
    switch (call.method) {
      case 'read':
        return store[call.arguments['key'] as String];
      case 'write':
        store[call.arguments['key'] as String] =
            call.arguments['value'] as String;
        return null;
      case 'delete':
        store.remove(call.arguments['key'] as String);
        return null;
      case 'deleteAll':
        store.clear();
        return null;
    }
    return null;
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorage fakeStorage;

  setUp(() {
    fakeStorage = _FakeSecureStorage();
  });
  tearDown(() => fakeStorage.dispose());

  test('fresh install generates identity → loaded', () async {
    SharedPreferences.setMockInitialValues({});
    final svc = await IdentityService().init();
    expect(svc.storageState.value, IdentityStorageState.loaded);
    expect(svc.hasIdentity.value, isTrue);
    expect(svc.requiresNewDeviceId.value, isFalse);
  });

  test('read failure → unreadable, NEVER requiresNewDeviceId', () async {
    SharedPreferences.setMockInitialValues({
      'device_id': '1791072063360',
      'identity_initialized': true,
    });
    fakeStorage.throwOnRead = true;
    final svc = await IdentityService().init();
    expect(svc.storageState.value, IdentityStorageState.unreadable);
    expect(svc.hasIdentity.value, isFalse);
    expect(svc.requiresNewDeviceId.value, isFalse); // must not mint a new ID
  });

  test('confirmed-missing keys on existing ID → missing + orphan flag',
      () async {
    SharedPreferences.setMockInitialValues({
      'device_id': '1791072063360',
      'identity_initialized': true,
    });
    // store empty — reads succeed and return nothing
    final svc = await IdentityService().init();
    expect(svc.storageState.value, IdentityStorageState.missing);
    expect(svc.requiresNewDeviceId.value, isTrue);
    expect(svc.hasIdentity.value, isFalse);
  });

  test('partial key material → unreadable, not healed', () async {
    SharedPreferences.setMockInitialValues({
      'device_id': '1791072063360',
      'identity_initialized': true,
    });
    fakeStorage.store['vant_identity_x25519_sk'] = base64Encode([1, 2, 3]);
    // ed25519 + bundle absent → partial
    final svc = await IdentityService().init();
    expect(svc.storageState.value, IdentityStorageState.unreadable);
    expect(svc.requiresNewDeviceId.value, isFalse);
  });

  test('bundle-vs-seed mismatch → unreadable', () async {
    // Write a valid seed pair but a bundle that doesn't match it.
    final x = await X25519().newKeyPair();
    final e = await Ed25519().newKeyPair();
    final xSeed = (await x.extract() as SimpleKeyPairData).bytes;
    final eSeed = (await e.extract() as SimpleKeyPairData).bytes;
    // Bundle claims different public keys.
    final wrongBundle = base64Encode(
      List<int>.from([1, ...List.filled(32, 7), ...List.filled(32, 9)]),
    );
    fakeStorage.store['vant_identity_x25519_sk'] = base64Encode(xSeed);
    fakeStorage.store['vant_identity_ed25519_sk'] = base64Encode(eSeed);
    fakeStorage.store['vant_identity_bundle'] = wrongBundle;

    SharedPreferences.setMockInitialValues({
      'device_id': '1791072063360',
      'identity_initialized': true,
    });
    final svc = await IdentityService().init();
    expect(svc.storageState.value, IdentityStorageState.unreadable);
    expect(svc.requiresNewDeviceId.value, isFalse);
  });

  test('stored keys that match → loaded (survives restart)', () async {
    // First init generates + stores.
    SharedPreferences.setMockInitialValues({});
    await IdentityService().init();
    // Second init with the same "storage" reads them back.
    SharedPreferences.setMockInitialValues({
      'device_id': '1791072063360',
      'identity_initialized': true,
    });
    final svc = await IdentityService().init();
    expect(svc.storageState.value, IdentityStorageState.loaded);
    expect(svc.hasIdentity.value, isTrue);
  });

  test('signBytes signs a length-prefixed domain plus message', () async {
    SharedPreferences.setMockInitialValues({});
    final svc = await IdentityService().init();
    final message = Uint8List.fromList([1, 2, 3, 250]);
    final signature = await svc.signBytes(
      IdentityService.domainCallFingerprintCaller,
      message,
    );
    final parsed = IdentityService.parseBundle(svc.identityBundleBase64!)!;
    final domain = utf8.encode(IdentityService.domainCallFingerprintCaller);
    final expected = Uint8List.fromList([
      0,
      0,
      0,
      domain.length,
      ...domain,
      ...message,
    ]);
    final publicKey = SimplePublicKey(
      parsed.ed25519Pub,
      type: KeyPairType.ed25519,
    );
    expect(
      await Ed25519().verify(
        expected,
        signature: Signature(signature, publicKey: publicKey),
      ),
      isTrue,
    );
    expect(
      await Ed25519().verify(
        message,
        signature: Signature(signature, publicKey: publicKey),
      ),
      isFalse,
    );
  });
}
