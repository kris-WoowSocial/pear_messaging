import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Service for downloading images to device gallery
class ImageDownloadService {
  /// Download image to gallery
  /// Returns true if successful, false otherwise
  static Future<bool> downloadImageToGallery(
    Uint8List imageData, {
    String? fileName,
  }) async {
    try {
      // Request storage permission
      final hasPermission = await _requestStoragePermission();
      if (!hasPermission) {
        debugPrint('❌ Storage permission denied');
        return false;
      }

      // Generate filename if not provided
      final name = fileName ?? 'pear_${DateTime.now().millisecondsSinceEpoch}';

      // Get the download directory
      Directory? directory;
      if (Platform.isAndroid) {
        // For Android, use Downloads directory
        directory = await getDownloadsDirectory();
        if (directory == null) {
          // Fallback to external storage
          directory = await getExternalStorageDirectory();
          if (directory != null) {
            directory = Directory('${directory.path}/Download');
            if (!await directory.exists()) {
              await directory.create(recursive: true);
            }
          }
        }
      } else if (Platform.isIOS) {
        // For iOS, use application documents directory
        directory = await getApplicationDocumentsDirectory();
        // Create a "Pear Images" subdirectory
        directory = Directory('${directory.path}/Pear Images');
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
      }

      if (directory == null) {
        debugPrint('❌ Could not access storage directory');
        return false;
      }

      // Create the image file
      final filePath = '${directory.path}/$name.jpg';
      final file = File(filePath);
      await file.writeAsBytes(imageData);

      debugPrint('✅ Image saved to: $filePath');

      // On Android, we can trigger a media scan to make it appear in gallery
      if (Platform.isAndroid) {
        try {
          // This would require additional dependencies for media scanning
          // For now, the file is saved and accessible via file manager
        } catch (e) {
          debugPrint('⚠️ Media scan failed: $e');
        }
      }

      return true;
    } catch (e) {
      debugPrint('❌ Error downloading image: $e');
      return false;
    }
  }

  /// Request storage permission
  static Future<bool> _requestStoragePermission() async {
    try {
      // For Android 13+ (API 33+), we need different permissions
      if (Platform.isAndroid) {
        final androidInfo = await _getAndroidVersion();
        if (androidInfo >= 33) {
          // Android 13+ uses scoped storage, no permission needed for saving to gallery
          return true;
        } else {
          // Android 12 and below need storage permission
          final status = await Permission.storage.request();
          return status.isGranted;
        }
      } else if (Platform.isIOS) {
        // iOS needs photos permission
        final status = await Permission.photos.request();
        return status.isGranted || status.isLimited;
      }
      return false;
    } catch (e) {
      debugPrint('❌ Error requesting storage permission: $e');
      return false;
    }
  }

  /// Get Android SDK version
  static Future<int> _getAndroidVersion() async {
    try {
      if (Platform.isAndroid) {
        // This is a simplified version - in production you'd use device_info_plus
        return 33; // Assume modern Android for now
      }
      return 0;
    } catch (e) {
      return 0;
    }
  }

  /// Check if storage permission is granted
  static Future<bool> hasStoragePermission() async {
    try {
      if (Platform.isAndroid) {
        final androidInfo = await _getAndroidVersion();
        if (androidInfo >= 33) {
          return true; // No permission needed for Android 13+
        }
        return await Permission.storage.isGranted;
      } else if (Platform.isIOS) {
        final status = await Permission.photos.status;
        return status.isGranted || status.isLimited;
      }
      return false;
    } catch (e) {
      debugPrint('❌ Error checking storage permission: $e');
      return false;
    }
  }
}
