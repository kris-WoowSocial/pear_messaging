import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:photo_view/photo_view.dart';
import '../../../core/services/secure_image_storage_service.dart';

/// Secure Image Viewer
///
/// Displays images that are stored encrypted on disk.
/// Images are decrypted in memory only when displayed.
/// Memory is cleared after widget disposal.
class SecureImageViewer extends StatefulWidget {
  final String imagePath;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final VoidCallback? onTap;
  final Widget? placeholder;
  final Widget? errorWidget;

  const SecureImageViewer({
    super.key,
    required this.imagePath,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.onTap,
    this.placeholder,
    this.errorWidget,
  });

  @override
  State<SecureImageViewer> createState() => _SecureImageViewerState();
}

class _SecureImageViewerState extends State<SecureImageViewer> {
  late final SecureImageStorageService _imageService;
  Uint8List? _decryptedData;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _imageService = Get.find<SecureImageStorageService>();
    _loadImage();
  }

  @override
  void didUpdateWidget(SecureImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _clearMemory();
      _loadImage();
    }
  }

  @override
  void dispose() {
    _clearMemory();
    super.dispose();
  }

  /// Clear decrypted data from memory
  void _clearMemory() {
    if (_decryptedData != null) {
      // Overwrite with zeros before releasing
      _decryptedData!.fillRange(0, _decryptedData!.length, 0);
      _decryptedData = null;
    }
  }

  Future<void> _loadImage() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final data = await _imageService.loadImage(widget.imagePath);

      if (!mounted) return;

      if (data == null) {
        setState(() {
          _isLoading = false;
          _error = 'Image not found';
        });
        return;
      }

      setState(() {
        _decryptedData = data;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _error = 'Failed to load image';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return _buildPlaceholder(
        widget.placeholder ??
            Container(
              width: widget.width,
              height: widget.height,
              color: Colors.grey[200],
              child: const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
      );
    }

    if (_error != null || _decryptedData == null) {
      return _buildPlaceholder(
        widget.errorWidget ??
            Container(
              width: widget.width,
              height: widget.height,
              color: Colors.grey[300],
              child: const Icon(Icons.broken_image, color: Colors.grey),
            ),
      );
    }

    return _buildPlaceholder(
      GestureDetector(
        onTap: widget.onTap ?? () => _showFullScreen(context),
        child: Image.memory(
          _decryptedData!,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          gaplessPlayback: false, // Important: don't cache in memory
        ),
      ),
    );
  }

  Widget _buildPlaceholder(Widget child) {
    if (widget.borderRadius != null) {
      return ClipRRect(
        borderRadius: widget.borderRadius!,
        child: child,
      );
    }
    return child;
  }

  void _showFullScreen(BuildContext context) {
    if (_decryptedData == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _FullScreenImageViewer(
          imageData: _decryptedData!,
          onClose: () => Navigator.pop(context),
        ),
      ),
    );
  }
}

/// Full-screen image viewer with zoom support
class _FullScreenImageViewer extends StatelessWidget {
  final Uint8List imageData;
  final VoidCallback onClose;

  const _FullScreenImageViewer({
    required this.imageData,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Photo view with zoom
          PhotoView(
            imageProvider: MemoryImage(imageData),
            backgroundDecoration: const BoxDecoration(color: Colors.black),
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 3,
          ),

          // Close button
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: onClose,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Secure image thumbnail (small, optimized for lists)
class SecureImageThumbnail extends StatelessWidget {
  final String imagePath;
  final double size;
  final BorderRadius? borderRadius;
  final VoidCallback? onTap;

  const SecureImageThumbnail({
    super.key,
    required this.imagePath,
    this.size = 50,
    this.borderRadius,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: SecureImageViewer(
        imagePath: imagePath,
        width: size,
        height: size,
        fit: BoxFit.cover,
        borderRadius: borderRadius ?? BorderRadius.circular(8),
        onTap: onTap,
        placeholder: Container(
          width: size,
          height: size,
          color: Colors.grey[200],
          child: const Icon(Icons.image, color: Colors.grey, size: 20),
        ),
        errorWidget: Container(
          width: size,
          height: size,
          color: Colors.grey[300],
          child: const Icon(Icons.broken_image, color: Colors.grey, size: 20),
        ),
      ),
    );
  }
}
