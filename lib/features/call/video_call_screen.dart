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

class _VideoCallScreenState extends State<VideoCallScreen> {
  static const _previewSize = Size(112, 160);
  static const _previewMargin = 16.0;

  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  late final bool _videoUiEnabled;
  Worker? _localStreamWorker;
  Worker? _remoteStreamWorker;
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
    _initializeRenderers();
    _scheduleHideControls();
  }

  Future<void> _initializeRenderers() async {
    await _remoteRenderer.initialize();
    await _localRenderer.initialize();
    if (!mounted) return;
    _attachStreams(
      _controller.localVideoStream.value,
      _controller.remoteVideoStream.value,
    );
    _localStreamWorker = ever(
      _controller.localVideoStream,
      (stream) => _localRenderer.srcObject = stream,
    );
    _remoteStreamWorker = ever(
      _controller.remoteVideoStream,
      (stream) => _remoteRenderer.srcObject = stream,
    );
  }

  void _attachStreams(MediaStream? local, MediaStream? remote) {
    _localRenderer.srcObject = local;
    _remoteRenderer.srcObject = remote;
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
    _hideControlsTimer?.cancel();
    _localStreamWorker?.dispose();
    _remoteStreamWorker?.dispose();
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_videoUiEnabled) return const ActiveCallScreen();

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
              _previewOffset ??= _initialPreviewOffset(size);
              return Stack(
                fit: StackFit.expand,
                children: [
                  _buildRemoteVideo(),
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
  }

  Offset _initialPreviewOffset(Size size) => Offset(
        size.width - _previewSize.width - _previewMargin,
        size.height - _previewSize.height - _previewMargin,
      );

  Widget _buildRemoteVideo() {
    return Obx(() {
      final hasRemoteVideo = _controller.remoteVideoStream.value != null &&
          !_controller.peerCameraOff.value;
      if (hasRemoteVideo) {
        return RTCVideoView(
          _remoteRenderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
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
      if (!_controller.isCameraOn.value ||
          _controller.localVideoStream.value == null) {
        return const SizedBox.shrink();
      }
      final offset = _previewOffset ?? _initialPreviewOffset(size);
      return Positioned(
        left: offset.dx,
        top: offset.dy,
        child: GestureDetector(
          onPanUpdate: (details) {
            setState(() {
              _previewOffset = _clampedPreviewOffset(
                offset + details.delta,
                size,
              );
            });
          },
          onPanEnd: (_) => _snapPreview(size),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: _previewSize.width,
              height: _previewSize.height,
              child: Container(
                color: Colors.black,
                child: Obx(
                  () => RTCVideoView(
                    _localRenderer,
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

  Offset _clampedPreviewOffset(Offset offset, Size size) => Offset(
        offset.dx.clamp(
          _previewMargin,
          size.width - _previewSize.width - _previewMargin,
        ),
        offset.dy.clamp(
          _previewMargin,
          size.height - _previewSize.height - _previewMargin,
        ),
      );

  void _snapPreview(Size size) {
    final current = _previewOffset;
    if (current == null) return;
    final corners = [
      const Offset(_previewMargin, _previewMargin),
      Offset(size.width - _previewSize.width - _previewMargin, _previewMargin),
      Offset(
        _previewMargin,
        size.height - _previewSize.height - _previewMargin,
      ),
      _initialPreviewOffset(size),
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
      final name = _controller.remoteDisplayName.value.isNotEmpty
          ? _controller.remoteDisplayName.value
          : 'Unknown';
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
                            Get.back();
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

  String _callStatusText() {
    if (_controller.isReconnecting.value) return 'Reconnecting...';
    return switch (_controller.callState.value) {
      CallState.dialing => 'Calling...',
      CallState.ringing => 'Ringing...',
      CallState.connected => _controller.callDuration.value,
      _ => 'Connecting...',
    };
  }
}
