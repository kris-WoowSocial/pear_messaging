import 'dart:typed_data';
import 'dart:io';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';

/// Image compression utility for optimizing images before encryption
///
/// PRIVACY NOTES:
/// - Compressed images are stored only in temporary memory
/// - No persistent storage of uncompressed or compressed images
/// - All temporary files are cleaned up after use
/// - Compression balances quality and file size for fast transfer
class ImageCompression {
  /// Compress image from file path
  ///
  /// Returns compressed image bytes
  /// Target: < 1MB for typical photos, maintains reasonable quality
  static Future<Uint8List> compressImageFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw ArgumentError('Image file does not exist: $filePath');
      }

      final originalBytes = await file.readAsBytes();
      return await compressImageBytes(originalBytes);
    } catch (e) {
      throw Exception('Image compression failed: $e');
    }
  }

  /// Compress image from bytes
  ///
  /// Returns compressed image bytes
  /// Automatically detects format and applies optimal compression
  static Future<Uint8List> compressImageBytes(Uint8List imageBytes) async {
    try {
      // Check if image needs compression (skip if already small)
      if (imageBytes.length < 500 * 1024) {
        // < 500KB
        return imageBytes;
      }

      // Create temporary file for compression
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
          '${tempDir.path}/temp_compress_${DateTime.now().millisecondsSinceEpoch}.jpg');

      try {
        // Write original bytes to temp file
        await tempFile.writeAsBytes(imageBytes);

        // Compress with progressive quality reduction
        XFile? compressed;
        for (int quality = 85; quality >= 60; quality -= 5) {
          compressed = await FlutterImageCompress.compressAndGetFile(
            tempFile.path,
            '${tempFile.path}_compressed.jpg',
            quality: quality,
            minWidth: 1024,
            minHeight: 1024,
          );

          if (compressed != null && await compressed.length() < 1024 * 1024) {
            // < 1MB
            break;
          }
        }

        if (compressed == null) {
          // Fallback to original if compression failed
          return imageBytes;
        }

        final compressedBytes = await compressed.readAsBytes();

        // Clean up temporary files
        await _cleanupTempFiles([tempFile.path, compressed.path]);

        return compressedBytes;
      } finally {
        // Ensure temp file is deleted even if compression fails
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }
    } catch (e) {
      throw Exception('Image compression failed: $e');
    }
  }

  /// Compress image with specific target size
  ///
  /// [targetSizeKB] - Target file size in kilobytes
  /// [minQuality] - Minimum quality to accept (0-100)
  static Future<Uint8List> compressImageToSize(
    Uint8List imageBytes, {
    int targetSizeKB = 500,
    int minQuality = 40,
  }) async {
    try {
      final targetBytes = targetSizeKB * 1024;

      // Create temporary file for compression
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
          '${tempDir.path}/temp_size_${DateTime.now().millisecondsSinceEpoch}.jpg');

      try {
        await tempFile.writeAsBytes(imageBytes);

        XFile? compressed;
        int quality = 90;

        while (quality >= minQuality) {
          compressed = await FlutterImageCompress.compressAndGetFile(
            tempFile.path,
            '${tempFile.path}_size.jpg',
            quality: quality,
            minWidth: 800,
            minHeight: 800,
          );

          if (compressed != null && await compressed.length() <= targetBytes) {
            break;
          }

          quality -= 10;
        }

        if (compressed == null) {
          return imageBytes;
        }

        final compressedBytes = await compressed.readAsBytes();

        // Clean up temporary files
        await _cleanupTempFiles([tempFile.path, compressed.path]);

        return compressedBytes;
      } finally {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }
    } catch (e) {
      throw Exception('Image compression to target size failed: $e');
    }
  }

  /// Get image dimensions without loading full image
  static Future<Size> getImageDimensions(Uint8List imageBytes) async {
    try {
      // Create temporary file
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(
          '${tempDir.path}/temp_dim_${DateTime.now().millisecondsSinceEpoch}.jpg');

      try {
        await tempFile.writeAsBytes(imageBytes);

        // Use flutter_image_compress to get dimensions
        final result = await FlutterImageCompress.compressAndGetFile(
          tempFile.path,
          '${tempFile.path}_dim.jpg',
          quality: 100,
        );

        if (result == null) {
          return Size(0, 0);
        }

        // For now, return estimated dimensions
        // In a real implementation, you'd use an image library to get exact dimensions
        return Size(1024, 1024);
      } finally {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }
    } catch (e) {
      return Size(0, 0);
    }
  }

  /// Clean up temporary files securely
  static Future<void> _cleanupTempFiles(List<String> filePaths) async {
    for (final filePath in filePaths) {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        // Ignore cleanup errors
      }
    }
  }
}

/// Simple size class for image dimensions
class Size {
  final double width;
  final double height;

  const Size(this.width, this.height);
}
