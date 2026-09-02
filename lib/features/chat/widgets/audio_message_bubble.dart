import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/services/encryption_service.dart';
import '../../../core/services/image_cache_service.dart';
import '../../../core/services/media_upload_service.dart';
import '../../../core/services/socket_service.dart';
import '../../../storage/models/message_entity.dart';
import '../chat_message_model.dart';

/// WhatsApp-style voice-message bubble.
///
/// Decrypts the audio blob, writes it to a temporary file with the correct
/// extension (AAC or M4A), and plays it with just_audio. Shows a waveform,
/// duration and playback-speed toggle.
class AudioMessageBubble extends StatefulWidget {
  final ChatMessageModel message;

  const AudioMessageBubble({
    super.key,
    required this.message,
  });

  @override
  State<AudioMessageBubble> createState() => _AudioMessageBubbleState();
}

class _AudioMessageBubbleState extends State<AudioMessageBubble> {
  final AudioPlayer _audioPlayer = AudioPlayer();

  StreamSubscription? _durationSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _playerStateSub;
  StreamSubscription? _processingStateSub;

  final RxBool _isDownloading = false.obs;
  final RxDouble _downloadProgress = 0.0.obs;
  final RxString _statusText = ''.obs;
  final RxBool _isReady = false.obs;
  final RxBool _hasError = false.obs;
  final Rx<Duration> _position = Duration.zero.obs;
  final Rx<Duration> _duration = Duration.zero.obs;
  final RxBool _isPlaying = false.obs;
  final RxDouble _playbackRate = 1.0.obs;

  Uint8List? _audioBytes;
  String? _lastToken;
  String? _tempFilePath;

  int get _durationMs => widget.message.audioDuration ?? 0;

  bool get _isPending =>
      widget.message.content == 'AUDIO:pending' ||
      widget.message.content == 'AUDIO:';

  List<double> get _waveformAmplitudes {
    if (widget.message.waveformData != null &&
        widget.message.waveformData!.isNotEmpty) {
      try {
        final values = widget.message.waveformData!
            .split(',')
            .map((v) => double.tryParse(v) ?? 0.3)
            .toList();
        if (values.isNotEmpty) return values;
      } catch (_) {}
    }
    return List.filled(30, 0.3);
  }

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  @override
  void didUpdateWidget(AudioMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.content != widget.message.content ||
        oldWidget.message.status != widget.message.status) {
      _initAudio();
    }
  }

  Future<void> _initAudio() async {
    if (!mounted) return;

    // Reset transient state but keep already-loaded bytes.
    _hasError.value = false;
    _statusText.value = '';

    // 1. Sender: use locally cached recording if available.
    if (widget.message.isMe) {
      final cached = await _getCachedBytes();
      if (cached != null && cached.isNotEmpty) {
        await _loadBytes(cached);
        return;
      }
    }

    final token = _extractToken();

    // Pending upload - show uploading state and wait for finalize.
    if (token == null || token == 'pending') {
      _isReady.value = false;
      _statusText.value = 'Sending voice message...';
      return;
    }

    // If we already have the bytes for this token, just load them.
    if (_audioBytes != null && _lastToken == token) {
      await _loadBytes(_audioBytes!);
      return;
    }

    // 2. Try cache.
    final cached = await _getCachedBytes();
    if (cached != null && cached.isNotEmpty) {
      _audioBytes = cached;
      _lastToken = token;
      await _loadBytes(cached);
      _sendDownloadAck(token);
      return;
    }

    // 3. Download from server.
    await _downloadAndLoad(token);
  }

  Future<Uint8List?> _getCachedBytes() async {
    try {
      final cacheService = Get.find<ImageCacheService>();
      return await cacheService.getCachedImageById(widget.message.id);
    } catch (e) {
      debugPrint('⚠️ AudioMessageBubble: cache lookup failed: $e');
      return null;
    }
  }

  Future<void> _cacheBytes(Uint8List bytes) async {
    try {
      final cacheService = Get.find<ImageCacheService>();
      await cacheService.cacheImageById(widget.message.id, bytes);
    } catch (e) {
      debugPrint('⚠️ AudioMessageBubble: cache write failed: $e');
    }
  }

  Future<void> _downloadAndLoad(String token) async {
    _isDownloading.value = true;
    _downloadProgress.value = 0.0;
    _hasError.value = false;

    try {
      final encryptedBlob = await MediaUploadService.downloadAudio(
        token,
        onProgress: (progress) => _downloadProgress.value = progress,
      );

      if (encryptedBlob == null) {
        _isDownloading.value = false;
        _hasError.value = true;
        _statusText.value = 'Voice message unavailable';
        return;
      }

      final base64Data = EncryptionService.decryptMessage(encryptedBlob);
      final decodedBytes = base64Decode(base64Data);

      _audioBytes = decodedBytes;
      _lastToken = token;

      await _cacheBytes(decodedBytes);
      await _loadBytes(decodedBytes);
      _sendDownloadAck(token);
    } catch (e) {
      debugPrint('❌ AudioMessageBubble: download/decode failed: $e');
      _hasError.value = true;
      _statusText.value = 'Voice message unavailable';
    } finally {
      _isDownloading.value = false;
    }
  }

  void _sendDownloadAck(String token) {
    try {
      final socketService = Get.find<SocketService>();
      socketService.sendMediaDownloadAck(
        messageId: widget.message.id,
        mediaToken: token,
      );
    } catch (e) {
      debugPrint('⚠️ AudioMessageBubble: could not send download ack: $e');
    }
  }

  Future<void> _loadBytes(Uint8List bytes) async {
    _audioBytes = bytes;

    // Determine the real format from the file header and write to a temp
    // file with the matching extension. just_audio (via ExoPlayer on Android
    // and AVPlayer on iOS) is much more reliable with a real file path than
    // with in-memory bytes for MP4/M4A containers.
    final mimeType = _detectMimeType(bytes);
    final extension = mimeType == 'audio/mp4' ? '.m4a' : '.aac';

    final tempDir = await getTemporaryDirectory();
    _tempFilePath = '${tempDir.path}/${widget.message.id}_audio$extension';
    final file = File(_tempFilePath!);
    await file.writeAsBytes(bytes, flush: true);
    // Give the filesystem a moment to flush the file metadata.
    await Future.delayed(const Duration(milliseconds: 100));

    debugPrint(
      '🔊 AudioMessageBubble: file=${file.path}, exists=${await file.exists()}, '
      'size=${await file.length()}, mime=$mimeType, header=${bytes.take(8).toList()}',
    );

    try {
      await _audioPlayer.setAudioSource(
        AudioSource.uri(Uri.file(_tempFilePath!)),
      );
      await _audioPlayer.setSpeed(_playbackRate.value);

      _durationSub?.cancel();
      _positionSub?.cancel();
      _playerStateSub?.cancel();
      _processingStateSub?.cancel();

      _durationSub = _audioPlayer.durationStream.listen((d) {
        _duration.value = d ?? Duration(milliseconds: _durationMs);
      });
      _positionSub = _audioPlayer.positionStream.listen((p) {
        _position.value = p;
      });
      _playerStateSub = _audioPlayer.playerStateStream.listen((state) {
        _isPlaying.value = state.playing;
      });
      _processingStateSub = _audioPlayer.processingStateStream.listen((state) {
        if (state == ProcessingState.completed) {
          _isPlaying.value = false;
          _position.value = Duration.zero;
          _audioPlayer.seek(Duration.zero);
        }
      });

      final detectedDuration = await _audioPlayer.durationFuture;
      _duration.value = detectedDuration ?? Duration(milliseconds: _durationMs);
      _isReady.value = true;
      _hasError.value = false;
    } catch (e) {
      debugPrint('❌ AudioMessageBubble: failed to load audio: $e');
      _isReady.value = false;
      _hasError.value = true;
      _statusText.value = 'Voice message unavailable';
    }
  }

  String? _detectMimeType(Uint8List bytes) {
    if (bytes.length < 2) return null;

    // AAC ADTS: syncword 0xFFF, first byte 0xFF and second byte 0xF*
    if (bytes[0] == 0xFF && (bytes[1] & 0xF0) == 0xF0) {
      return 'audio/aac';
    }

    // MP4/M4A container: first 4 bytes are the box size, bytes 4-7 are the
    // box type ('ftyp', 'moov', 'mdat', 'free').
    bool boxAt(int offset, String type) {
      if (bytes.length < offset + 4) return false;
      return bytes[offset] == type.codeUnitAt(0) &&
          bytes[offset + 1] == type.codeUnitAt(1) &&
          bytes[offset + 2] == type.codeUnitAt(2) &&
          bytes[offset + 3] == type.codeUnitAt(3);
    }

    if (boxAt(4, 'ftyp') ||
        boxAt(4, 'moov') ||
        boxAt(4, 'mdat') ||
        boxAt(4, 'free') ||
        boxAt(0, 'ftyp')) {
      return 'audio/mp4';
    }

    return 'audio/aac';
  }

  String? _extractToken() {
    final content = widget.message.content;
    if (content.startsWith('AUDIO:')) {
      return content.substring(6);
    }
    return null;
  }

  Future<void> _togglePlay() async {
    if (!_isReady.value || _audioBytes == null) return;

    try {
      if (_isPlaying.value) {
        await _audioPlayer.pause();
        return;
      }

      // Make sure the audio session is active before playback.
      try {
        final session = await AudioSession.instance;
        await session.setActive(true);
      } catch (e) {
        debugPrint('⚠️ AudioMessageBubble: could not activate session: $e');
      }

      if (_position.value >= _duration.value &&
          _duration.value > Duration.zero) {
        await _audioPlayer.seek(Duration.zero);
      }
      await _audioPlayer.play();
    } catch (e) {
      debugPrint('❌ AudioMessageBubble: play/pause failed: $e');
    }
  }

  Future<void> _cyclePlaybackSpeed() async {
    final next = _playbackRate.value == 1.0
        ? 1.5
        : _playbackRate.value == 1.5
            ? 2.0
            : 1.0;
    _playbackRate.value = next;
    try {
      await _audioPlayer.setSpeed(next);
    } catch (e) {
      debugPrint('⚠️ AudioMessageBubble: setSpeed failed: $e');
    }
  }

  Future<void> _seekTo(double fraction) async {
    if (!_isReady.value || _duration.value <= Duration.zero) return;
    final clamped = fraction.clamp(0.0, 1.0);
    final newPosition = Duration(
      milliseconds: (_duration.value.inMilliseconds * clamped).toInt(),
    );
    await _audioPlayer.seek(newPosition);
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _processingStateSub?.cancel();
    _audioPlayer.dispose();

    // Clean up the temporary audio file when the bubble is removed.
    try {
      final path = _tempFilePath;
      if (path != null && path.isNotEmpty) {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      }
    } catch (e) {
      debugPrint('⚠️ AudioMessageBubble: failed to delete temp file: $e');
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.message.status == MessageStatus.sending || _isPending) {
      return _buildUploadingState();
    }

    return Obx(() {
      if (_isDownloading.value) {
        return _buildDownloadingState();
      }

      if (_hasError.value || !_isReady.value) {
        return _buildUnavailableState();
      }

      return _buildPlayer();
    });
  }

  Widget _buildUploadingState() {
    return _buildBubble(
      child: Row(
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Sending voice message...',
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.6),
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadingState() {
    return _buildBubble(
      child: Row(
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              value: _downloadProgress.value > 0 ? _downloadProgress.value : null,
              strokeWidth: 2.5,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Downloading voice message...',
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.6),
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnavailableState() {
    final token = _extractToken();
    final canRetry = token != null && token != 'pending';

    return _buildBubble(
      child: Row(
        children: [
          Icon(Icons.mic_off, color: Colors.grey[600]),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _statusText.value.isEmpty
                  ? 'Voice message unavailable'
                  : _statusText.value,
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 13,
              ),
            ),
          ),
          if (canRetry)
            GestureDetector(
              onTap: _initAudio,
              child: Icon(Icons.refresh, color: AppColors.primary, size: 20),
            ),
        ],
      ),
    );
  }

  Widget _buildPlayer() {
    return _buildBubble(
      child: Row(
        children: [
          // Play / pause button.
          GestureDetector(
            onTap: _togglePlay,
            child: Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPlaying.value ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Waveform + duration.
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 32,
                  child: _buildWaveform(),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatDuration(_position.value),
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Playback speed toggle.
          GestureDetector(
            onTap: _cyclePlaybackSpeed,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${_playbackRate.value.toStringAsFixed(_playbackRate.value == 2.0 ? 0 : 1)}x',
                style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBubble({required Widget child}) {
    return Container(
      width: 260,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: widget.message.isMe
            ? AppColors.senderBubble
            : AppColors.receiverBubble,
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  Widget _buildWaveform() {
    final amplitudes = _waveformAmplitudes;

    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onTapDown: (details) {
            final fraction = details.localPosition.dx / constraints.maxWidth;
            _seekTo(fraction);
          },
          onHorizontalDragUpdate: (details) {
            final fraction = details.localPosition.dx / constraints.maxWidth;
            _seekTo(fraction);
          },
          behavior: HitTestBehavior.translucent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(amplitudes.length, (index) {
              final height = 4 + (amplitudes[index] * 24).clamp(0, 24);
              final bool isPlayed;
              if (_duration.value.inMilliseconds == 0) {
                isPlayed = false;
              } else {
                final progress = _position.value.inMilliseconds /
                    _duration.value.inMilliseconds;
                isPlayed = index <= (amplitudes.length * progress);
              }
              return Container(
                width: 3,
                height: height.toDouble(),
                decoration: BoxDecoration(
                  color: isPlayed ? AppColors.primary : Colors.grey[400],
                  borderRadius: BorderRadius.circular(1.5),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}
