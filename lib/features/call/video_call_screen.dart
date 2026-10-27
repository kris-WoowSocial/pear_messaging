import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:get/get.dart';

import '../../core/services/feature_flag_service.dart';
import 'active_call_screen.dart';
import 'call_controller.dart';
import 'call_encryption_indicator.dart';

class VideoCallScreen extends StatefulWidget {
  const VideoCallScreen({super.key});

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen>
    with WidgetsBindingObserver {
  static const _previewSize = Size(112, 160);
  static const _previewMargin = 16.0;
  /// Vertical space reserved for the bottom control bar (52px buttons + bar
  /// padding + bottom margin + a visual gap). The self-view tile must never
  /// overlap it — the hang-up button sits on top otherwise.
  static const _controlsReserve = 132.0;

  late final bool _videoUiEnabled;
  Worker? _callStateWorker;
  Timer? _hideControlsTimer;
  Offset? _previewOffset;
  bool _controlsVisible = true;

  CallController get _controller => Get.find<CallController>();

  @override
  void initState() {
    super.initState();
    _videoUiEnabled = Get.isRegistered<FeatureFlagService>() &&
        Get.find<FeatureFlagService>().videoCalling.value;
    if (!_videoUiEnabled) return;
    WidgetsBinding.instance.addObserver(this);
    // Renderers live in the controller for the whole call — minimizing this
    // screen must not recreate the decoder (black frames until the next
    // keyframe). ensureVideoRenderers is idempotent.
    _controller.ensureVideoRenderers().then((_) {
      // Renderers are controller-owned (not reactive) — force one rebuild so
      // the freshly-initialized RTCVideoViews attach.
      if (mounted) setState(() {});
    });
    _scheduleHideControls();
    _callStateWorker = ever(_controller.callState, _onCallStateChanged);
    // Tell the controller the connected-video-call UI is up so Android can
    // arm PiP auto-enter/onUserLeaveHint.
    _controller.notifyVideoCallUiVisible(true);
  }

  void _onCallStateChanged(CallState state) {
    if (state == CallState.ended || state == CallState.idle) {
      _closeCallRoute();
    }
  }

  /// Pop this call route and anything that may have been pushed on top of it
  /// (snackbars, dialogs) without touching routes underneath.
  void _closeCallRoute() {
    if (!mounted) return;
    final routeName = ModalRoute.of(context)?.settings.name;
    if (routeName == null || !routeName.startsWith('/call/')) return;
    final navigator = Navigator.of(context);
    // If the call screen is the root route (CallKit/PushKit accept replaced the
    // stack, or the app cold-started for the call), popping would leave an
    // empty navigator — iOS shows a black screen. Land on the chat list instead.
    if (!navigator.canPop()) {
      Get.offAllNamed('/chat-list');
      return;
    }
    navigator.popUntil((route) => route.settings.name != routeName);
  }

  /// Re-bind srcObject on resume/unlock. A locked-screen or cold-start accept
  /// can leave the renderer detached from a live track (or holding a stale
  /// surface); srcObject assignment is idempotent and forces a re-attach.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted || !_videoUiEnabled) {
      return;
    }
    _controller.rebindVideoStreams();
  }

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHideControls();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideControlsTimer?.cancel();
    _callStateWorker?.dispose();
    // Renderers are controller-owned and outlive this screen — deliberately
    // NOT disposed or detached here; the decoder keeps its last frame for the
    // next route restore.
    _controller.notifyVideoCallUiVisible(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_videoUiEnabled) return const ActiveCallScreen();
    // If the local camera permission was denied or the call was downgraded to
    // audio, the controller drops both isVideoCall and videoRequested; fall
    // back to the audio UI.
    if (!_controller.isVideoCall.value && !_controller.videoRequested) {
      return const ActiveCallScreen();
    }

    return Obx(() {
      // The whole activity window becomes the PiP surface on Android — render
      // remote video only: no controls, no local preview, no overlays. The
      // system provides expand/close affordances on top.
      if (_controller.isInPip.value) {
        final hasRemoteVideo =
            _controller.remoteVideoStream.value != null &&
                !_controller.peerCameraOff.value;
        return VideoCallPipLayout(
          remoteRenderer: _controller.remoteRenderer,
          hasRemoteVideo: hasRemoteVideo,
          statusText: hasRemoteVideo ? null : _callStatusText(),
        );
      }
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          _controller.minimizeCallScreen(context);
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _showControls,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                final padding = MediaQuery.of(context).padding;
                _previewOffset ??= _initialPreviewOffset(size, padding);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildVideoSurface(),
                    _buildCenterStatus(),
                    _buildLocalPreview(size),
                    _buildTopOverlay(),
                    _buildControls(),
                  ],
                );
              },
            ),
          ),
        ),
      );
    });
  }

  Offset _initialPreviewOffset(Size size, EdgeInsets padding) => Offset(
        size.width - _previewSize.width - _previewMargin - padding.right,
        size.height -
            _previewSize.height -
            _previewMargin -
            padding.bottom -
            _controlsReserve,
      );

  Widget _buildVideoSurface() {
    return Obx(() {
      final remoteRenderer = _controller.remoteRenderer;
      final hasRemoteVideo = _controller.remoteVideoStream.value != null &&
          !_controller.peerCameraOff.value &&
          remoteRenderer != null;
      if (hasRemoteVideo) {
        return RTCVideoView(
          remoteRenderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        );
      }

      final localRenderer = _controller.localRenderer;
      if (_controller.isCameraOn.value &&
          _controller.localVideoStream.value != null &&
          localRenderer != null) {
        return RTCVideoView(
          localRenderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          mirror: _controller.isFrontCamera.value,
        );
      }

      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF18222D), Color(0xFF050607)],
          ),
        ),
      );
    });
  }

  Widget _buildCenterStatus() {
    return Obx(() {
      final peerCameraOff = _controller.peerCameraOff.value;
      final remoteMissing = _controller.remoteVideoStream.value == null;
      if (!peerCameraOff && !remoteMissing) return const SizedBox.shrink();
      if (_controller.isCameraOn.value &&
          _controller.localVideoStream.value != null &&
          remoteMissing) {
        return const SizedBox.shrink();
      }

      final status = peerCameraOff ? 'Camera off' : _callStatusText();
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 104,
              height: 104,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.08),
              ),
              child: const Icon(Icons.person, size: 56, color: Colors.white54),
            ),
            const SizedBox(height: 16),
            Text(
              status,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 17,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildLocalPreview(Size size) {
    return Obx(() {
      final localRenderer = _controller.localRenderer;
      final hasRemoteVideo = _controller.remoteVideoStream.value != null &&
          !_controller.peerCameraOff.value;
      if (!hasRemoteVideo ||
          !_controller.isCameraOn.value ||
          _controller.localVideoStream.value == null ||
          localRenderer == null) {
        return const SizedBox.shrink();
      }
      final padding = MediaQuery.of(context).padding;
      final offset = _previewOffset ?? _initialPreviewOffset(size, padding);
      return Positioned(
        left: offset.dx,
        top: offset.dy,
        child: GestureDetector(
          onPanUpdate: (details) {
            setState(() {
              _previewOffset = _clampedPreviewOffset(
                offset + details.delta,
                size,
                padding,
              );
            });
          },
          onPanEnd: (_) => _snapPreview(size, padding),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: _previewSize.width,
              height: _previewSize.height,
              child: Container(
                color: Colors.black,
                child: Obx(
                  () => RTCVideoView(
                    localRenderer,
                    mirror: _controller.isFrontCamera.value,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Offset _clampedPreviewOffset(
    Offset offset,
    Size size,
    EdgeInsets padding,
  ) =>
      Offset(
        offset.dx.clamp(
          _previewMargin + padding.left,
          size.width - _previewSize.width - _previewMargin - padding.right,
        ),
        offset.dy.clamp(
          _previewMargin + padding.top,
          size.height -
              _previewSize.height -
              _previewMargin -
              padding.bottom -
              _controlsReserve,
        ),
      );

  void _snapPreview(Size size, EdgeInsets padding) {
    final current = _previewOffset;
    if (current == null) return;
    final corners = [
      Offset(_previewMargin + padding.left, _previewMargin + padding.top),
      Offset(
        size.width - _previewSize.width - _previewMargin - padding.right,
        _previewMargin + padding.top,
      ),
      Offset(
        _previewMargin + padding.left,
        size.height -
            _previewSize.height -
            _previewMargin -
            padding.bottom -
            _controlsReserve,
      ),
      _initialPreviewOffset(size, padding),
    ];
    setState(() {
      _previewOffset = corners.reduce(
        (best, corner) =>
            (corner - current).distance < (best - current).distance
                ? corner
                : best,
      );
    });
  }

  Widget _buildTopOverlay() {
    return Obx(() {
      final name = _controller.remoteDisplayLabel;
      return SafeArea(
        child: AnimatedOpacity(
          opacity: _controlsVisible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(color: Colors.black, blurRadius: 8)],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _callStatusText(),
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 10),
                CallEncryptionIndicator(
                  state: _controller.callEncryptionState.value,
                ),
                if (_controller.hasPoorConnection.value) ...[
                  const SizedBox(height: 8),
                  _statusChip(
                    icon: Icons.network_check,
                    text: 'Poor connection',
                    color: const Color(0xFFFFCC00),
                  ),
                ],
                if (_controller.isReconnecting.value) ...[
                  const SizedBox(height: 8),
                  _statusChip(
                    icon: Icons.sync,
                    text: 'Reconnecting',
                    color: const Color(0xFF64B5F6),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _statusChip({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Obx(() {
      final muted = _controller.isMuted.value;
      final cameraOn = _controller.isCameraOn.value;
      final speakerOn = _controller.isSpeakerOn.value;
      return Align(
        alignment: Alignment.bottomCenter,
        child: AnimatedSlide(
          offset: _controlsVisible ? Offset.zero : const Offset(0, 0.25),
          duration: const Duration(milliseconds: 180),
          child: AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(34),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _controlButton(
                          icon: muted ? Icons.mic_off : Icons.mic,
                          tooltip: muted ? 'Unmute' : 'Mute',
                          active: muted,
                          onTap: _controller.toggleMute,
                        ),
                        _controlButton(
                          icon: cameraOn ? Icons.videocam : Icons.videocam_off,
                          tooltip: cameraOn ? 'Camera off' : 'Camera on',
                          active: !cameraOn,
                          onTap: () => _controller.setCameraEnabled(!cameraOn),
                        ),
                        _controlButton(
                          icon: Icons.cameraswitch,
                          tooltip: 'Flip camera',
                          onTap: () => _controller.switchCamera(),
                        ),
                        _controlButton(
                          icon: speakerOn ? Icons.volume_up : Icons.volume_down,
                          tooltip: 'Speaker',
                          active: speakerOn,
                          onTap: () => _controller.toggleSpeaker(),
                        ),
                        _controlButton(
                          icon: Icons.call_end,
                          tooltip: 'End call',
                          background: Colors.red,
                          iconColor: Colors.white,
                          onTap: () {
                            HapticFeedback.heavyImpact();
                            _controller.endCall();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _controlButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool active = false,
    Color? background,
    Color? iconColor,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        style: IconButton.styleFrom(
          backgroundColor:
              background ?? (active ? Colors.white : Colors.white24),
          foregroundColor: iconColor ?? (active ? Colors.black : Colors.white),
          minimumSize: const Size(52, 52),
        ),
        icon: Icon(icon),
      ),
    );
  }

  String _callStatusText() => _controller.callTimerLabel;
}

/// Android Picture-in-Picture layout for an active video call: remote video
/// fills the whole PiP window, or a compact camera-off placeholder when the
/// peer has no video. Every child scales with the window — no fixed sizes —
/// so even ~90dp-tall PiP windows can't overflow.
class VideoCallPipLayout extends StatelessWidget {
  const VideoCallPipLayout({
    super.key,
    required this.remoteRenderer,
    required this.hasRemoteVideo,
    this.statusText,
  });

  /// Nullable so headless tests can exercise the placeholder path; a null
  /// renderer is never dereferenced because it implies !hasRemoteVideo.
  final RTCVideoRenderer? remoteRenderer;
  final bool hasRemoteVideo;
  final String? statusText;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (hasRemoteVideo && remoteRenderer != null) {
            return SizedBox.expand(
              child: RTCVideoView(
                remoteRenderer!,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            );
          }
          // Camera-off / connecting placeholder sized relative to the window.
          final side = constraints.biggest.shortestSide;
          final avatar = (side * 0.38).clamp(28.0, 104.0);
          final showText = side > 120 && statusText != null;
          return Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF18222D), Color(0xFF050607)],
              ),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: avatar,
                    height: avatar,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                    child: Icon(
                      Icons.videocam_off,
                      size: avatar * 0.54,
                      color: Colors.white54,
                    ),
                  ),
                  if (showText) ...[
                    SizedBox(height: avatar * 0.15),
                    Text(
                      statusText!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
