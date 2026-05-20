import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'secure_image_storage_service.dart';

/// Chat Media Service
/// 
/// Integrates secure image storage with chat functionality.
/// Handles saving, loading, and displaying images in chats.
class ChatMediaService extends GetxService {
  late final SecureImageStorageService _secureStorage;
  
  // Cache for decrypted image data (messageId -> imageData)
  final Map<String, Uint8List> _memoryCache = {};
  
  Future<ChatMediaService> init() async {
    _secureStorage = Get.find<SecureImageStorageService>();
    debugPrint('🔐 ChatMediaService initialized');
    return this;
  }
  
  /// Save image securely for a chat message
  /// 
  /// Returns the secure file path to store in the message
  Future<String> saveChatImage(String messageId, Uint8List imageData) async {
    try {
      final securePath = await _secureStorage.saveImage(imageData);
      
      // Also cache in memory for quick access
      _memoryCache[messageId] = imageData;
      
      debugPrint('💾 Chat image saved securely: $messageId');
      return securePath;
    } catch (e) {
      debugPrint('❌ Failed to save chat image: $e');
      throw Exception('Failed to save chat image: $e');
    }
  }
  
  /// Load image for a chat message
  /// 
  /// First checks memory cache, then decrypts from secure storage
  Future<Uint8List?> loadChatImage(String messageId, String filePath) async {
    try {
      // Check memory cache first
      if (_memoryCache.containsKey(messageId)) {
        debugPrint('📷 Chat image loaded from memory cache: $messageId');
        return _memoryCache[messageId];
      }
      
      // Load from secure storage
      final imageData = await _secureStorage.loadImage(filePath);
      
      if (imageData != null) {
        // Cache for future access
        _memoryCache[messageId] = imageData;
        debugPrint('📷 Chat image loaded from secure storage: $messageId');
      }
      
      return imageData;
    } catch (e) {
      debugPrint('❌ Failed to load chat image: $e');
      return null;
    }
  }
  
  /// Delete image for a chat message
  Future<void> deleteChatImage(String messageId, String filePath) async {
    try {
      // Remove from memory cache
      _memoryCache.remove(messageId);
      
      // Delete from secure storage
      await _secureStorage.deleteImage(filePath);
      
      debugPrint('🗑️ Chat image deleted: $messageId');
    } catch (e) {
      debugPrint('❌ Failed to delete chat image: $e');
    }
  }
  
  /// Clear all chat images
  Future<void> clearAllImages() async {
    try {
      // Clear memory cache
      for (final data in _memoryCache.values) {
        data.fillRange(0, data.length, 0);
      }
      _memoryCache.clear();
      
      // Clear secure storage
      await _secureStorage.clearAllImages();
      
      debugPrint('🗑️ All chat images cleared');
    } catch (e) {
      debugPrint('❌ Failed to clear chat images: $e');
    }
  }
  
  /// Check if image exists
  Future<bool> imageExists(String filePath) async {
    return await _secureStorage.imageExists(filePath);
  }
  
  /// Get image size
  Future<int?> getImageSize(String filePath) async {
    return await _secureStorage.getImageSize(filePath);
  }
  
  /// Clear memory cache (call when app goes to background)
  void clearMemoryCache() {
    for (final data in _memoryCache.values) {
      data.fillRange(0, data.length, 0);
    }
    _memoryCache.clear();
    debugPrint('🧠 Chat image memory cache cleared');
  }
  
  /// Get storage statistics
  Future<Map<String, dynamic>> getStorageStats() async {
    return await _secureStorage.getStorageStats();
  }
  
  @override
  void onClose() {
    clearMemoryCache();
    super.onClose();
  }
}
