import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Full-screen remote video for an active video call.
///
/// The remote feed MUST NEVER be mirrored: mirroring belongs only to the
/// local selfie preview (WhatsApp behavior). Keeping the flag explicit here
/// guards against future plugin default changes and accidental reuse of the
/// local mirror state.
class RemoteCallVideoView extends StatelessWidget {
  const RemoteCallVideoView(
    this.renderer, {
    super.key,
    this.objectFit = RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
  });

  final RTCVideoRenderer renderer;
  final RTCVideoViewObjectFit objectFit;

  @override
  Widget build(BuildContext context) {
    return RTCVideoView(
      renderer,
      objectFit: objectFit,
      mirror: false,
    );
  }
}

/// Local self-view (small tile or full-screen fallback while no remote video).
/// Mirrored ONLY for the front camera — the selfie preview the user expects —
/// and never for the rear camera.
class LocalCallVideoView extends StatelessWidget {
  const LocalCallVideoView(
    this.renderer, {
    super.key,
    required this.isFrontCamera,
    this.objectFit = RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
  });

  final RTCVideoRenderer renderer;
  final bool isFrontCamera;
  final RTCVideoViewObjectFit objectFit;

  @override
  Widget build(BuildContext context) {
    return RTCVideoView(
      renderer,
      objectFit: objectFit,
      mirror: isFrontCamera,
    );
  }
}
