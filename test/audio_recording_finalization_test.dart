import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_media_recorder/provider/sound_record_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.llfbandit.record/messages');

  test('send waits for native stop and uses the finalized recording path', () async {
    final stopped = Completer<String?>();
    final stopCalled = Completer<void>();
    final sent = <String>[];
    var recording = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isRecording') return recording;
      if (call.method == 'stop') {
        stopCalled.complete();
        final path = await stopped.future;
        recording = false;
        return path;
      }
      return null;
    });
    final notifier = SoundRecordNotifier(
      stopRecording: (_) {},
      startRecording: () {},
      sendRequestFunction: (File file, String time) => sent.add(file.path),
      buttonPressed: true,
      second: 4,
      mPath: '/unfinished.m4a',
    );
    notifier.finishRecording();
    await stopCalled.future;
    expect(sent, isEmpty);
    notifier.finishRecording();
    stopped.complete('/finalized.m4a');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sent, ['/finalized.m4a']);
    await notifier.recordMp3.dispose();
    notifier.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
