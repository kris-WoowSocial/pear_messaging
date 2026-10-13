import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/callkit_service.dart';

void main() {
  group('CallKit audio session params', () {
    const callId = 'call_123';
    const uuid = '550e8400-e29b-41d4-a716-446655440000';
    const callerId = 'device_abc';
    const callerName = 'Test Caller';

    test('voice call configures CallKit for voiceChat before showing UI', () {
      final params = CallKitService.buildIncomingCallParams(
        callId: callId,
        callKitUuid: uuid,
        callerId: callerId,
        callerName: callerName,
        isVideo: false,
      );

      expect(params.type, 0);
      expect(params.ios?.supportsVideo, false);
      expect(params.ios?.audioSessionMode, 'voiceChat');
      expect(params.ios?.audioSessionActive, true);
      expect(params.ios?.audioSessionPreferredSampleRate, 44100.0);
    });

    test('video call configures CallKit for videoChat before showing UI', () {
      final params = CallKitService.buildIncomingCallParams(
        callId: callId,
        callKitUuid: uuid,
        callerId: callerId,
        callerName: callerName,
        isVideo: true,
      );

      expect(params.type, 1);
      expect(params.ios?.supportsVideo, true);
      expect(params.ios?.audioSessionMode, 'videoChat');
      expect(params.ios?.audioSessionActive, true);
      expect(params.ios?.audioSessionPreferredSampleRate, 44100.0);
    });
  });
}
