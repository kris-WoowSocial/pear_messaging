import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:pear_messaging/core/services/media_service.dart';
import 'secure_image_picker.dart';

/// Image message bubble with secure loading and display
///
/// SECURITY FEATURES:
/// - No persistent caching of images
/// - Images loaded only when viewed
/// - Automatic cleanup of decrypted data
/// - Clear indication of expired media
class ImageMessageBubble extends StatefulWidget {
  final String mediaToken;
  final DateTime? expiryTimestamp;
  final bool isMe;
  final VoidCallback? onTap;

  const ImageMessageBubble({
    super.key,
    required this.mediaToken,
    this.expiryTimestamp,
    required this.isMe,
    this.onTap,
  });

  @override
  State<ImageMessageBubble> createState() => _ImageMessageBubbleState();
}

class _ImageMessageBubbleState extends State<ImageMessageBubble> {
  MediaStatus _status = MediaStatus.loading;
  Uint8List? _imageData;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _checkMediaStatus();
  }

  @override
  void dispose() {
    // Secure cleanup of image data from memory
    if (_imageData != null) {
      _imageData!.fillRange(0, _imageData!.length, 0);
    }
    super.dispose();
  }

  Future<void> _checkMediaStatus() async {
    // Check if media has expired locally
    if (widget.expiryTimestamp != null &&
        DateTime.now().isAfter(widget.expiryTimestamp!)) {
      setState(() {
        _status = MediaStatus.expired;
      });
      return;
    }

    // Check if token is still valid on server
    final isValid = await MediaService.isMediaTokenValid(widget.mediaToken);
    if (!isValid) {
      setState(() {
        _status = MediaStatus.expired;
      });
      return;
    }

    setState(() {
      _status = MediaStatus.available;
    });
  }

  Future<void> _loadImage() async {
    if (_status == MediaStatus.loading) return;

    setState(() {
      _status = MediaStatus.loading;
    });

    try {
      final imageData =
          await MediaService.downloadAndDecryptImage(widget.mediaToken);

      setState(() {
        _imageData = imageData;
        _status = MediaStatus.available;
      });
    } catch (e) {
      setState(() {
        _status = e.toString().contains('expired')
            ? MediaStatus.expired
            : MediaStatus.error;
        _errorMessage = e.toString().contains('expired')
            ? 'This photo has expired'
            : 'Failed to load photo';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.7,
        minWidth: 200,
        maxHeight: 300,
      ),
      decoration: BoxDecoration(
        color: widget.isMe ? Theme.of(context).primaryColor : Colors.grey[300],
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    switch (_status) {
      case MediaStatus.loading:
        return _buildLoadingState();
      case MediaStatus.available:
        return _buildImageState();
      case MediaStatus.expired:
        return _buildExpiredState();
      case MediaStatus.error:
        return _buildErrorState();
    }
  }

  Widget _buildLoadingState() {
    return SizedBox(
      height: 200,
      child: Stack(
        children: [
          // Placeholder background
          Container(
            color: widget.isMe
                ? Theme.of(context).primaryColor.withOpacity(0.1)
                : Colors.grey[200],
          ),
          // Loading indicator
          Center(
            child: LoadingAnimationWidget.staggeredDotsWave(
              color: widget.isMe ? Colors.white : Colors.grey[600]!,
              size: 40,
            ),
          ),
          // Tap to load
          if (_imageData == null)
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _loadImage,
                  child: Center(
                    child: Text(
                      'Tap to load',
                      style: TextStyle(
                        color: widget.isMe ? Colors.white70 : Colors.grey[600],
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildImageState() {
    if (_imageData == null) {
      return _buildLoadingState();
    }

    return Stack(
      children: [
        // Image
        Image.memory(
          _imageData!,
          width: double.infinity,
          height: 200,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return _buildErrorState();
          },
        ),
        // Overlay for tap interaction
        Positioned.fill(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _openFullScreenViewer(),
              child: Container(),
            ),
          ),
        ),
        // Expiry indicator
        if (widget.expiryTimestamp != null)
          Positioned(
            bottom: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _formatExpiryTime(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildExpiredState() {
    return SizedBox(
      height: 150,
      child: Stack(
        children: [
          // Background
          Container(
            color: widget.isMe
                ? Theme.of(context).primaryColor.withOpacity(0.2)
                : Colors.grey[300],
          ),
          // Expired content
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.timer_off,
                  color: widget.isMe ? Colors.white70 : Colors.grey[600],
                  size: 32,
                ),
                const SizedBox(height: 8),
                Text(
                  'Photo expired',
                  style: TextStyle(
                    color: widget.isMe ? Colors.white70 : Colors.grey[600],
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return SizedBox(
      height: 150,
      child: Stack(
        children: [
          // Background
          Container(
            color: widget.isMe
                ? Theme.of(context).primaryColor.withOpacity(0.2)
                : Colors.grey[300],
          ),
          // Error content
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline,
                  color: widget.isMe ? Colors.white70 : Colors.grey[600],
                  size: 32,
                ),
                const SizedBox(height: 8),
                Text(
                  _errorMessage ?? 'Failed to load',
                  style: TextStyle(
                    color: widget.isMe ? Colors.white70 : Colors.grey[600],
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _loadImage,
                  child: Text(
                    'Retry',
                    style: TextStyle(
                      color: widget.isMe ? Colors.white : Colors.grey[700],
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openFullScreenViewer() {
    if (_status != MediaStatus.available || _imageData == null) return;

    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) {
          return SecureImageViewer(
            mediaToken: widget.mediaToken,
            expiryTimestamp: widget.expiryTimestamp,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }

  String _formatExpiryTime() {
    if (widget.expiryTimestamp == null) return '';

    final remaining = widget.expiryTimestamp!.difference(DateTime.now());
    if (remaining.isNegative) return 'Expired';

    if (remaining.inDays > 0) {
      return '${remaining.inDays}d';
    } else if (remaining.inHours > 0) {
      return '${remaining.inHours}h';
    } else if (remaining.inMinutes > 0) {
      return '${remaining.inMinutes}m';
    } else {
      return 'Soon';
    }
  }
}

/// Compact image preview for chat input area
class CompactImagePreview extends StatelessWidget {
  final String mediaToken;
  final DateTime? expiryTimestamp;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;

  const CompactImagePreview({
    super.key,
    required this.mediaToken,
    this.expiryTimestamp,
    this.onRemove,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 100,
      height: 100,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Stack(
        children: [
          // Image preview (placeholder for now)
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Colors.grey[200],
            ),
            child: const Center(
              child: Icon(Icons.image, color: Colors.grey, size: 32),
            ),
          ),
          // Remove button
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.close,
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
          ),
          // Tap overlay
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
