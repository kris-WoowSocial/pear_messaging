import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'secure_encryption_service.dart';

/// Secure Image Storage Service
/// 
/// Stores images encrypted on disk using AES-256-GCM.
/// Images are decrypted on-demand for display only.
class SecureImageStorageService extends GetxService {
  static const String _imageDirectory = 'secure_images';
  static const String _fileExtension = '.enc';
  
  late final SecureEncryptionService _encryptionService;
  late Directory _storageDir;
  final _uuid = const Uuid();
  
  Future<SecureImageStorageService> init() async {
    _encryptionService = Get.find<SecureEncryptionService>();
    
    // Create secure image directory
    final appDir = await getApplicationDocumentsDirectory();
    _storageDir = Directory('${appDir.path}/$_imageDirectory');
    
    if (!await _storageDir.exists()) {
      await _storageDir.create(recursive: true);
      debugPrint('📁 Created secure image directory: ${_storageDir.path}');
    }
    
    debugPrint('🔐 SecureImageStorageService initialized');
    return this;
  }
  
  /// Save image with encryption
  /// 
  /// Returns the encrypted file path for storage in database
  Future<String> saveImage(Uint8List imageData, {String? originalFileName}) async {
    try {
      // Generate unique filename
      final fileName = '${_uuid.v4()}$_fileExtension';
      final filePath = '${_storageDir.path}/$fileName';
      
      // Encrypt image data
      final encryptedData = await _encryptionService.encryptData(imageData);
      
      // Write encrypted data to file
      final file = File(filePath);
      await file.writeAsBytes(encryptedData);
      
      debugPrint('🔒 Image saved securely: $fileName (${imageData.length} -> ${encryptedData.length} bytes)');
      
      return filePath;
    } catch (e) {
      debugPrint('❌ Failed to save encrypted image: $e');
      throw Exception('Failed to save image: $e');
    }
  }
  
  /// Save image from file path
  Future<String> saveImageFromFile(String sourcePath) async {
    try {
      final file = File(sourcePath);
      if (!await file.exists()) {
        throw FileSystemException('Source file not found', sourcePath);
      }
      
      final imageData = await file.readAsBytes();
      return await saveImage(imageData);
    } catch (e) {
      debugPrint('❌ Failed to save image from file: $e');
      rethrow;
    }
  }
  
  /// Load and decrypt image
  /// 
  /// Returns decrypted image data in memory
  Future<Uint8List?> loadImage(String filePath) async {
    try {
      // Check if this is an encrypted path or legacy unencrypted path
      if (!_isEncryptedPath(filePath)) {
        // Legacy path - try to read directly (backward compatibility)
        return await _loadLegacyImage(filePath);
      }
      
      final file = File(filePath);
      if (!await file.exists()) {
        debugPrint('⚠️ Encrypted image file not found: $filePath');
        return null;
      }
      
      // Read encrypted data
      final encryptedData = await file.readAsBytes();
      
      // Decrypt
      final decryptedData = await _encryptionService.decryptData(encryptedData);
      
      debugPrint('🔓 Image loaded and decrypted: ${decryptedData.length} bytes');
      return decryptedData;
    } catch (e) {
      debugPrint('❌ Failed to load encrypted image: $e');
      return null;
    }
  }
  
  /// Delete encrypted image
  Future<void> deleteImage(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('🗑️ Deleted encrypted image: $filePath');
      }
    } catch (e) {
      debugPrint('❌ Failed to delete image: $e');
    }
  }
  
  /// Check if a file exists
  Future<bool> imageExists(String filePath) async {
    try {
      // Handle both encrypted and legacy paths
      if (_isEncryptedPath(filePath)) {
        return await File(filePath).exists();
      } else {
        // For legacy paths, check if file exists (it might have been deleted)
        return await File(filePath).exists();
      }
    } catch (e) {
      return false;
    }
  }
  
  /// Get file size of encrypted image
  Future<int?> getImageSize(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        return await file.length();
      }
      return null;
    } catch (e) {
      return null;
    }
  }
  
  /// Clear all stored images
  Future<void> clearAllImages() async {
    try {
      if (await _storageDir.exists()) {
        final files = await _storageDir.list().toList();
        for (final file in files) {
          if (file is File) {
            await file.delete();
          }
        }
        debugPrint('🗑️ Cleared all ${files.length} encrypted images');
      }
    } catch (e) {
      debugPrint('❌ Failed to clear images: $e');
    }
  }
  
  /// Get storage statistics
  Future<Map<String, dynamic>> getStorageStats() async {
    try {
      int totalSize = 0;
      int fileCount = 0;
      
      if (await _storageDir.exists()) {
        await for (final file in _storageDir.list()) {
          if (file is File && file.path.endsWith(_fileExtension)) {
            final size = await file.length();
            totalSize += size;
            fileCount++;
          }
        }
      }
      
      return {
        'fileCount': fileCount,
        'totalSizeBytes': totalSize,
        'totalSizeMB': (totalSize / 1024 / 1024).toStringAsFixed(2),
        'storagePath': _storageDir.path,
      };
    } catch (e) {
      return {
        'fileCount': 0,
        'totalSizeBytes': 0,
        'totalSizeMB': '0.00',
        'error': e.toString(),
      };
    }
  }
  
  /// Check if path is an encrypted image file
  bool _isEncryptedPath(String filePath) {
    return filePath.endsWith(_fileExtension);
  }
  
  /// Load legacy unencrypted image (backward compatibility)
  Future<Uint8List?> _loadLegacyImage(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return null;
      }
      
      debugPrint('📜 Loading legacy (unencrypted) image: $filePath');
      return await file.readAsBytes();
    } catch (e) {
      debugPrint('❌ Failed to load legacy image: $e');
      return null;
    }
  }
  
  /// Get the secure storage directory path
  String get storageDirectory => _storageDir.path;
}
