import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pear_messaging/core/services/media_service.dart';
import 'package:pear_messaging/core/services/secure_image_encryption.dart';
import 'package:pear_messaging/core/services/image_download_service.dart';
import 'package:pear_messaging/core/constants/app_colors.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Image picker widget with secure handling
///
/// SECURITY FEATURES:
/// - Images are processed entirely in memory
/// - No persistent storage of original images
/// - Automatic compression and encryption
/// - Secure cleanup of temporary files
class SecureImagePicker extends StatefulWidget {
  final Function(String mediaToken, DateTime expiryTimestamp) onImageSelected;
  final Function(String error) onError;
  final bool isLoading;

  const SecureImagePicker({
    super.key,
    required this.onImageSelected,
    required this.onError,
    this.isLoading = false,
  });

  @override
  State<SecureImagePicker> createState() => _SecureImagePickerState();
}

class _SecureImagePickerState extends State<SecureImagePicker> {
  final ImagePicker _imagePicker = ImagePicker();
  bool _isProcessing = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Send Photo',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildImageSourceButton(
                icon: Icons.camera_alt,
                label: 'Camera',
                onTap: () => _pickImage(ImageSource.camera),
              ),
              _buildImageSourceButton(
                icon: Icons.photo_library,
                label: 'Gallery',
                onTap: () => _pickImage(ImageSource.gallery),
              ),
            ],
          ),
          if (_isProcessing || widget.isLoading) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).primaryColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _isProcessing ? 'Processing...' : 'Uploading...',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildImageSourceButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Column(
      children: [
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: Theme.of(context).primaryColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(30),
          ),
          child: IconButton(
            icon: Icon(icon, color: Theme.of(context).primaryColor),
            onPressed: _isProcessing || widget.isLoading ? null : onTap,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_isProcessing || widget.isLoading) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      // Step 1: Pick image
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: source,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 90,
      );

      if (pickedFile == null) {
        setState(() {
          _isProcessing = false;
        });
        return;
      }

      // Step 2: Read image bytes
      final imageBytes = await File(pickedFile.path).readAsBytes();

      // Step 3: Upload and get media token
      final response = await MediaService.uploadEncryptedImage(imageBytes);

      // Step 4: Clean up temporary file
      await SecureImageEncryption.secureDelete(pickedFile.path);

      // Step 5: Notify parent
      widget.onImageSelected(response.mediaToken, response.expiryTimestamp);
    } catch (e) {
      widget.onError('Failed to process image: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }
}

/// Full-screen image viewer with secure handling
///
/// SECURITY FEATURES:
/// - Images are loaded into memory only
/// - No caching of decrypted images
/// - Automatic cleanup when viewer is closed
class SecureImageViewer extends StatefulWidget {
  final String mediaToken;
  final DateTime? expiryTimestamp;
  final VoidCallback? onClose;

  const SecureImageViewer({
    super.key,
    required this.mediaToken,
    this.expiryTimestamp,
    this.onClose,
  });

  @override
  State<SecureImageViewer> createState() => _SecureImageViewerState();
}

class _SecureImageViewerState extends State<SecureImageViewer> {
  Uint8List? _imageData;
  MediaStatus _status = MediaStatus.loading;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void dispose() {
    // Secure cleanup of image data from memory
    if (_imageData != null) {
      _imageData!.fillRange(0, _imageData!.length, 0);
    }
    super.dispose();
  }

  Future<void> _loadImage() async {
    setState(() {
      _status = MediaStatus.loading;
    });

    try {
      // Check if media has expired
      if (widget.expiryTimestamp != null &&
          DateTime.now().isAfter(widget.expiryTimestamp!)) {
        setState(() {
          _status = MediaStatus.expired;
          _errorMessage = 'This photo has expired';
        });
        return;
      }

      // Download and decrypt image
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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          'Photo',
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          // Download button - only show when image is loaded and not expired
          if (_status == MediaStatus.available && _imageData != null)
            IconButton(
              icon: const Icon(Icons.download, color: Colors.white),
              onPressed: _downloadImage,
              tooltip: 'Download',
            ),
          if (widget.expiryTimestamp != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  _formatExpiryTime(),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Center(
        child: _buildContent(),
      ),
    );
  }

  /// Download image to device gallery
  Future<void> _downloadImage() async {
    if (_imageData == null) return;

    final prefs = await SharedPreferences.getInstance();
    final hasSeenWarning = prefs.getBool('has_seen_download_warning') ?? false;

    if (!hasSeenWarning) {
      final confirmed = await Get.dialog<bool>(
        AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
              const SizedBox(width: 12),
              const Text('Download Warning'),
            ],
          ),
          content: const Text(
            'All photos, calls, and data are securely encrypted inside Vant. You can share them within the app, and they cannot be accessed by other apps.\n\nHowever, downloaded photos are saved to your device and are no longer protected by Vant\'s encryption. Other apps on your phone (such as your photo gallery or various AI services) will be able to access them.\n\nWe strongly advise against downloading sensitive images.\n\nThis is a one-time warning.',
            style: TextStyle(fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: false),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Get.back(result: true),
              style: TextButton.styleFrom(
                foregroundColor: Colors.grey.shade600,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              child: const Text('Download Anyway'),
            ),
          ],
        ),
        barrierDismissible: true,
      );

      if (confirmed != true) return;

      await prefs.setBool('has_seen_download_warning', true);
    }

    try {
      // Show loading indicator
      Get.dialog(
        const Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        ),
        barrierDismissible: false,
      );

      // Download image
      final success = await ImageDownloadService.downloadImageToGallery(
        _imageData!,
        fileName: 'pear_${widget.mediaToken}',
      );

      // Close loading dialog
      Get.back();

      // Show result
      if (success) {
        Get.snackbar(
          'Success',
          'Image saved to gallery',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.green.withOpacity(0.8),
          colorText: Colors.white,
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 2),
        );
      } else {
        Get.snackbar(
          'Error',
          'Failed to save image. Please check permissions.',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.withOpacity(0.8),
          colorText: Colors.white,
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 3),
        );
      }
    } catch (e) {
      // Close loading dialog if still open
      if (Get.isDialogOpen ?? false) {
        Get.back();
      }

      Get.snackbar(
        'Error',
        'Failed to download image: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.withOpacity(0.8),
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      );
    }
  }

  Widget _buildContent() {
    switch (_status) {
      case MediaStatus.loading:
        return const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
            SizedBox(height: 16),
            Text(
              'Loading photo...',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        );

      case MediaStatus.available:
        if (_imageData == null) return _buildErrorState();

        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: Image.memory(
            _imageData!,
            fit: BoxFit.contain,
          ),
        );

      case MediaStatus.expired:
        return _buildExpiredState();

      case MediaStatus.error:
        return _buildErrorState();
    }
  }

  Widget _buildExpiredState() {
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.timer_off,
          color: Colors.white54,
          size: 64,
        ),
        SizedBox(height: 16),
        Text(
          'This photo has expired',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 16,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildErrorState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.error_outline,
          color: Colors.white54,
          size: 64,
        ),
        const SizedBox(height: 16),
        Text(
          _errorMessage ?? 'Failed to load photo',
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 16,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _loadImage,
          child: const Text('Retry'),
        ),
      ],
    );
  }

  String _formatExpiryTime() {
    if (widget.expiryTimestamp == null) return '';

    final remaining = widget.expiryTimestamp!.difference(DateTime.now());
    if (remaining.isNegative) return 'Expired';

    if (remaining.inDays > 0) {
      return '${remaining.inDays}d left';
    } else if (remaining.inHours > 0) {
      return '${remaining.inHours}h left';
    } else if (remaining.inMinutes > 0) {
      return '${remaining.inMinutes}m left';
    } else {
      return 'Expires soon';
    }
  }
}
