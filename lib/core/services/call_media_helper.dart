import 'package:connectivity_plus/connectivity_plus.dart';

class CallMediaHelper {
  static const String videoCapability = 'video_call';
  static const int videoBitrateCapBps = 1200000;

  static Map<String, dynamic> mediaConstraints({required bool video}) => {
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': video
            ? {
                'facingMode': 'user',
                'width': {'ideal': 1280},
                'height': {'ideal': 720},
                'frameRate': {'ideal': 30},
              }
            : false,
      };

  static bool peerSupportsVideo({
    required String? clientVersion,
    required Iterable<String>? capabilities,
  }) {
    if (capabilities == null || !capabilities.contains(videoCapability)) {
      return false;
    }
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(
      clientVersion ?? '',
    );
    if (match == null) return false;
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    return major > 1 || (major == 1 && minor >= 8);
  }

  /// A peer that pinned an identity, signed encrypted-call support, or has
  /// already completed an encrypted call must never silently downgrade to
  /// plaintext signaling.
  static bool peerRequiresEncryptedCall({
    required bool hasPinnedIdentity,
    required bool signedEncryptedCapability,
    required bool encryptedCallSeen,
  }) {
    return hasPinnedIdentity || signedEncryptedCapability || encryptedCallSeen;
  }

  /// Perfect-negotiation glare rule: the original caller is impolite and keeps
  /// its restart offer; the callee is polite and accepts the caller's offer.
  static bool acceptRemoteIceRestartOffer({
    required bool localRestartInProgress,
    required bool isCaller,
  }) {
    return !localRestartInProgress || !isCaller;
  }

  static bool wifiMobileSwitch({
    required Iterable<ConnectivityResult>? before,
    required Iterable<ConnectivityResult> after,
  }) {
    if (before == null) return false;
    final hadWifi = before.contains(ConnectivityResult.wifi);
    final hasWifi = after.contains(ConnectivityResult.wifi);
    final hadMobile = before.contains(ConnectivityResult.mobile);
    final hasMobile = after.contains(ConnectivityResult.mobile);
    return (hadWifi && !hasWifi && hasMobile) ||
        (hadMobile && !hasMobile && hasWifi);
  }

  static Map<String, dynamic> mediaUpdatePayload({
    required String callId,
    required bool video,
  }) =>
      {
        'callId': callId,
        'video': video ? 'on' : 'off',
      };

  static bool hasVideoMediaSection(String sdp) =>
      RegExp(r'^m=video\s', multiLine: true).hasMatch(sdp);

  /// Whether the remote answer advertises video it can send. A missing
  /// direction attribute means sendrecv per RFC 3264/8829.
  static bool remoteVideoCanSend(String sdp) {
    final videoStart = RegExp(r'^m=video\s', multiLine: true).firstMatch(sdp);
    if (videoStart == null) return false;
    RegExpMatch? nextSection;
    for (final match in RegExp(r'^m=', multiLine: true).allMatches(sdp)) {
      if (match.start > videoStart.start) {
        nextSection = match;
        break;
      }
    }
    final section = sdp.substring(
      videoStart.start,
      nextSection?.start ?? sdp.length,
    );
    if (RegExp(r'^a=(sendrecv|sendonly)\s*$', multiLine: true)
        .hasMatch(section)) {
      return true;
    }
    if (RegExp(r'^a=(recvonly|inactive)\s*$', multiLine: true)
        .hasMatch(section)) {
      return false;
    }
    return true;
  }

  static Set<String> dtlsFingerprints(String sdp) {
    final matches = RegExp(
      r'^a=fingerprint:([^\s]+)\s+([0-9A-Fa-f:]+)\s*$',
      multiLine: true,
    ).allMatches(sdp);
    return matches
        .map(
          (match) =>
              '${match.group(1)!.toLowerCase()}|${match.group(2)!.toUpperCase()}',
        )
        .toSet();
  }

  static bool sameDtlsFingerprints(String first, String second) {
    final firstFingerprints = dtlsFingerprints(first);
    final secondFingerprints = dtlsFingerprints(second);
    return firstFingerprints.isNotEmpty &&
        firstFingerprints.length == secondFingerprints.length &&
        firstFingerprints.containsAll(secondFingerprints);
  }
}
