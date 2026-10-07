import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File('lib/core/services/socket_service.dart').readAsStringSync();
  });

  test('matching device_registered triggers FCM registration', () {
    final handlerStart = source.indexOf("_socket?.on('device_registered'");
    final handlerEnd = source.indexOf("_socket?.on('disconnect'", handlerStart);
    final handler = source.substring(handlerStart, handlerEnd);

    expect(handler, contains('deviceId == _deviceId'));
    expect(handler, contains('isRegistered.value = true'));
    expect(handler, contains('unawaited(_registerFCMTokenIfAvailable())'));
  });

  test('register request does not send FCM before server confirmation', () {
    final methodStart = source.indexOf('Future<void> _registerDevice()');
    final methodEnd = source.indexOf('/// Client version', methodStart);
    final method = source.substring(methodStart, methodEnd);

    expect(method, isNot(contains('_registerFCMTokenIfAvailable')));
    expect(method, isNot(contains("emit('register_fcm'")));
  });

  test('direct FCM registration requires confirmed socket registration', () {
    final methodStart = source.indexOf('Future<void> registerFCMToken');
    final methodEnd = source.indexOf('/// Send a message', methodStart);
    final method = source.substring(methodStart, methodEnd);
    final gate = method.indexOf('if (!isRegistered.value)');
    final emit = method.indexOf("_socket!.emit('register_fcm'");

    expect(gate, greaterThanOrEqualTo(0));
    expect(emit, greaterThan(gate));
    expect(method, isNot(contains('FCM Token:')));
  });
}
