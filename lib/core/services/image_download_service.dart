import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saver_gallery/saver_gallery.dart';

/// Service for downloading images to device gallery
class ImageDownloadService {
  /// Download image to gallery
  /// Returns true if successful, false otherwise
  static Future<bool> downloadImageToGallery(
    Uint8List imageData, {
    String? fileName,
  }) async {
    try {
      final hasPermission = await _requestStoragePermission();
      if (!hasPermission) {
        debugPrint('❌ Storage permission denied');
        return false;
      }

      final name =
          fileName ?? 'vant_chat_${DateTime.now().millisecondsSinceEpoch}';
      final result = await SaverGallery.saveImage(
        imageData,
        quality: 100,
        fileName: name,
        androidRelativePath: 'Pictures/Vant Chat',
        skipIfExists: false,
      );
      if (!result.isSuccess) {
        debugPrint('❌ Error downloading image: ${result.errorMessage}');
      }
      return result.isSuccess;
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
        if (androidInfo >= 29) return true;
        final status = await Permission.storage.request();
        return status.isGranted;
      } else if (Platform.isIOS) {
        final status = await Permission.photosAddOnly.request();
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
        return (await DeviceInfoPlugin().androidInfo).version.sdkInt;
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
        if (androidInfo >= 29) {
          return true; // No permission needed for Android 10+
        }
        return await Permission.storage.isGranted;
      } else if (Platform.isIOS) {
        final status = await Permission.photosAddOnly.status;
        return status.isGranted || status.isLimited;
      }
      return false;
    } catch (e) {
      debugPrint('❌ Error checking storage permission: $e');
      return false;
    }
  }
}
