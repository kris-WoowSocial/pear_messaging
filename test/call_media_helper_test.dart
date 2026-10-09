import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pear_messaging/core/services/call_media_helper.dart';

void main() {
  test('video constraints preserve audio processing and request front 720p30',
      () {
    final constraints = CallMediaHelper.mediaConstraints(video: true);
    final audio = constraints['audio'] as Map;
    final video = constraints['video'] as Map;

    expect(audio['echoCancellation'], true);
    expect(audio['noiseSuppression'], true);
    expect(audio['autoGainControl'], true);
    expect(video['facingMode'], 'user');
    expect(video['width'], {'ideal': 1280});
    expect(video['height'], {'ideal': 720});
    expect(video['frameRate'], {'ideal': 30});
  });

  test('peer video capability requires flag capability and 1.8+', () {
    expect(
      CallMediaHelper.peerSupportsVideo(
        clientVersion: '1.8.0+180',
        capabilities: const ['video_call'],
      ),
      true,
    );
    expect(
      CallMediaHelper.peerSupportsVideo(
        clientVersion: '1.7.1+71',
        capabilities: const ['video_call'],
      ),
      false,
    );
    expect(
      CallMediaHelper.peerSupportsVideo(
        clientVersion: '1.8.0+180',
        capabilities: const [],
      ),
      false,
    );
  });

  test('media update uses compact callId/video wire shape', () {
    expect(
      CallMediaHelper.mediaUpdatePayload(callId: 'c1', video: true),
      {'callId': 'c1', 'video': 'on'},
    );
    expect(
      CallMediaHelper.mediaUpdatePayload(callId: 'c1', video: false),
      {'callId': 'c1', 'video': 'off'},
    );
  });

  test('wifi/mobile transitions are detected without false positives', () {
    expect(
      CallMediaHelper.wifiMobileSwitch(
        before: const [ConnectivityResult.wifi],
        after: const [ConnectivityResult.mobile],
      ),
      true,
    );
    expect(
      CallMediaHelper.wifiMobileSwitch(
        before: const [ConnectivityResult.mobile],
        after: const [ConnectivityResult.wifi],
      ),
      true,
    );
    expect(
      CallMediaHelper.wifiMobileSwitch(
        before: const [ConnectivityResult.wifi],
        after: const [ConnectivityResult.wifi, ConnectivityResult.mobile],
      ),
      false,
    );
  });

  test('ICE fingerprints normalize case and reject changed fingerprint', () {
    const first =
        'v=0\r\na=fingerprint:SHA-256 aa:bb:Cc\r\na=fingerprint:sha-384 11:22\r\n';
    const same =
        'v=0\r\na=fingerprint:sha-256 AA:BB:CC\r\na=fingerprint:SHA-384 11:22\r\n';
    const changed =
        'v=0\r\na=fingerprint:SHA-256 AA:BB:CC\r\na=fingerprint:sha-384 11:23\r\n';

    expect(CallMediaHelper.sameDtlsFingerprints(first, same), true);
    expect(CallMediaHelper.sameDtlsFingerprints(first, changed), false);
    expect(CallMediaHelper.dtlsFingerprints('v=0'), isEmpty);
  });

  test('pinned, signed, or previously encrypted peers require encrypted calls',
      () {
    bool required({
      bool pinned = false,
      bool signedEncrypted = false,
      bool encryptedSeen = false,
    }) =>
        CallMediaHelper.peerRequiresEncryptedCall(
          hasPinnedIdentity: pinned,
          signedEncryptedCapability: signedEncrypted,
          encryptedCallSeen: encryptedSeen,
        );

    expect(required(), isFalse);
    expect(required(pinned: true), isTrue);
    expect(required(signedEncrypted: true), isTrue);
    expect(required(encryptedSeen: true), isTrue);
  });

  test('ICE restart glare gives the caller deterministic precedence', () {
    // With no local offer both peers accept normally.
    expect(
      CallMediaHelper.acceptRemoteIceRestartOffer(
        localRestartInProgress: false,
        isCaller: true,
      ),
      isTrue,
    );
    expect(
      CallMediaHelper.acceptRemoteIceRestartOffer(
        localRestartInProgress: false,
        isCaller: false,
      ),
      isTrue,
    );

    // Simultaneous restarts: caller is impolite, callee politely rolls back.
    expect(
      CallMediaHelper.acceptRemoteIceRestartOffer(
        localRestartInProgress: true,
        isCaller: true,
      ),
      isFalse,
    );
    expect(
      CallMediaHelper.acceptRemoteIceRestartOffer(
        localRestartInProgress: true,
        isCaller: false,
      ),
      isTrue,
    );
  });

  test('deferred video captures camera only for the post-handshake upgrade',
      () {
    final source =
        File('lib/core/services/webrtc_call_service.dart').readAsStringSync();

    expect(source, contains('_deferredVideoRequested'));
    expect(source, contains('_isVideoCall && !deferVideoTransmission'));
    expect(source, contains('prepareDeferredVideo'));
    expect(source, contains('enableDeferredVideo'));
    expect(source, contains("'audio': false"));
    expect(source, contains("'video': constraints['video']"));
  });

  test('failed encrypted handshakes never display an encrypted call', () {
    final source =
        File('lib/features/call/call_controller.dart').readAsStringSync();
    final updater = source
        .split('void _updateCallEncryptionState')
        .last
        .split('CallSignalingCrypto? _createSignalingCrypto')
        .first;

    expect(updater, contains('!_cryptoHandshakeReady'));
    expect(
      updater.indexOf('!_cryptoHandshakeReady'),
      lessThan(updater.indexOf('encryptedUnverified')),
    );
  });

  test('video action observes Remote Config values that arrive after build',
      () {
    final source =
        File('lib/features/chat/chat_screen.dart').readAsStringSync();
    final actions = source.substring(
      source.indexOf('actions: ['),
      source.indexOf('body: Column('),
    );
    final startup = File('lib/main_prod.dart').readAsStringSync();

    expect(actions, contains('Obx(()'));
    expect(
      actions.indexOf('Obx(()'),
      lessThan(actions.indexOf('videoCalling.value')),
    );
    expect(actions, contains('Icon(Icons.videocam'));
    expect(
      startup.indexOf('Get.put(FeatureFlagService(), permanent: true)'),
      lessThan(startup.indexOf('earlySocketService.init(deviceId)')),
    );
  });

  test('debug builds bypass Remote Config fetch cache', () {
    final source = File(
      'lib/core/services/feature_flag_service.dart',
    ).readAsStringSync();

    expect(source, contains('minimumFetchInterval:'));
    expect(
      source,
      contains('kDebugMode ? Duration.zero : const Duration(hours: 1)'),
    );
  });

  test('server-offered bundles pin only after the accepted call handshakes',
      () {
    final source =
        File('lib/features/call/call_controller.dart').readAsStringSync();
    final prepare = source.substring(
      source.indexOf('Future<_EncryptedCallSetup> _prepareEncryptedCaller'),
      source.indexOf('Future<void> _requestIceRestart'),
    );

    // peer_capability only selects the ephemeral crypto bundle. It is not a
    // trust root and cannot create a contact pin by itself.
    expect(prepare, contains('pinnedBundle ?? serverBundle'));
    expect(prepare.contains('pinPeerBundle'), isFalse);

    final accepted = source.substring(
      source.indexOf('Future<void> _handleCallAccepted'),
    );
    expect(
      accepted.indexOf('completeHandshakeFirstContact'),
      lessThan(accepted.indexOf('pinPeerBundle')),
    );

    final localDescription = source.substring(
      source.indexOf('Future<void> _handleLocalDescription'),
    );
    expect(
      localDescription.indexOf('beginAnswer'),
      lessThan(localDescription.indexOf('pinPeerBundle')),
    );
    expect(source, contains('await _webrtcService.acceptCall('));

    final storageSource = File(
      'lib/core/services/local_storage_service.dart',
    ).readAsStringSync();
    expect(
      storageSource.indexOf('getChat(peerDeviceId) == null'),
      lessThan(storageSource.indexOf("'bundle': bundle")),
    );
  });
}
