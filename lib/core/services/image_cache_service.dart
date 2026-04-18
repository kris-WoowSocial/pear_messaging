import 'dart:convert';
import 'dart:collection';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';

class ImageCacheService extends GetxService {
  static const String _boxName = 'image_cache';
  static const int _maxMemoryCacheSize = 50; // Max images in memory cache
  static const int _maxMemoryCacheSizeMB = 100; // Max 100MB in memory

  late Box<List<int>> _cacheBox;

  // Persistent memory cache with LRU eviction
  final LinkedHashMap<String, Uint8List> _memoryCache = LinkedHashMap();
  int _memoryCacheSizeBytes = 0;

  /// Initialize the image cache service
  Future<ImageCacheService> init() async {
    debugPrint('🖼️ Initializing Image Cache Service...');

    try {
      // Open Hive box for image cache
      _cacheBox = await Hive.openBox<List<int>>(_boxName);
      debugPrint('✅ Image Cache Service initialized');

      // Warm up memory cache with recently accessed images
      await _warmUpMemoryCache();

      return this;
    } catch (e) {
      debugPrint('❌ Error initializing Image Cache Service: $e');
      rethrow;
    }
  }

  /// Warm up memory cache with recently accessed images
  Future<void> _warmUpMemoryCache() async {
    try {
      // Load up to 10 most recent images into memory cache
      final keys = _cacheBox.keys.take(10).toList();
      for (final key in keys) {
        if (key is String && key.startsWith('id_')) {
          final data = _cacheBox.get(key);
          if (data != null) {
            final imageData = Uint8List.fromList(data);
            _addToMemoryCache(key, imageData);
          }
        }
      }
      debugPrint(
          '🔥 Memory cache warmed up with ${_memoryCache.length} images');
    } catch (e) {
      debugPrint('⚠️ Error warming up memory cache: $e');
    }
  }

  /// Add image to memory cache with LRU eviction
  void _addToMemoryCache(String key, Uint8List imageData) {
    // Remove if already exists to update LRU order
    if (_memoryCache.containsKey(key)) {
      _memoryCacheSizeBytes -= _memoryCache[key]!.length;
      _memoryCache.remove(key);
    }

    // Add to cache
    _memoryCache[key] = imageData;
    _memoryCacheSizeBytes += imageData.length;

    // Evict oldest entries if cache is too large
    while (_memoryCache.length > _maxMemoryCacheSize ||
        _memoryCacheSizeBytes > _maxMemoryCacheSizeMB * 1024 * 1024) {
      final oldestKey = _memoryCache.keys.first;
      _memoryCacheSizeBytes -= _memoryCache[oldestKey]!.length;
      _memoryCache.remove(oldestKey);
    }
  }

  /// Generate cache key from base64 string
  String _generateCacheKey(String base64String) {
    final bytes = utf8.encode(base64String);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Check if image is cached by message ID (synchronous, instant)
  bool isImageCachedById(String messageId) {
    try {
      final key = 'id_$messageId';
      // Check memory cache first (instant)
      if (_memoryCache.containsKey(key)) return true;
      // Check disk cache (still fast, no I/O)
      return _cacheBox.containsKey(key);
    } catch (e) {
      debugPrint('❌ Error checking cache by id: $e');
      return false;
    }
  }

  /// Get cached image by message ID synchronously from memory cache
  /// Returns null if not in memory cache (use async method for disk cache)
  Uint8List? getCachedImageByIdSync(String messageId) {
    try {
      final key = 'id_$messageId';
      return _memoryCache[key];
    } catch (e) {
      debugPrint('❌ Error getting cached image sync: $e');
      return null;
    }
  }

  /// Cache by message ID (fast — no SHA256 needed)
  Future<void> cacheImageById(String messageId, Uint8List imageData) async {
    try {
      final key = 'id_$messageId';
      // Add to memory cache immediately
      _addToMemoryCache(key, imageData);
      // Persist to disk
      await _cacheBox.put(key, imageData.toList());
    } catch (e) {
      debugPrint('❌ Error caching image by id: $e');
    }
  }

  /// Get cached image by message ID (fast — no hashing, async off main thread)
  Future<Uint8List?> getCachedImageById(String messageId) async {
    try {
      final key = 'id_$messageId';

      // Check memory cache first (instant)
      if (_memoryCache.containsKey(key)) {
        return _memoryCache[key];
      }

      // Check disk cache
      if (!_cacheBox.containsKey(key)) return null;
      final cachedData = _cacheBox.get(key);
      if (cachedData == null) return null;

      // Run the byte copy off the main thread
      final imageData = await compute(_listToUint8List, cachedData);

      // Add to memory cache for next time
      _addToMemoryCache(key, imageData);

      return imageData;
    } catch (e) {
      debugPrint('❌ Error getting cached image by id: $e');
      return null;
    }
  }

  static Uint8List _listToUint8List(List<int> list) => Uint8List.fromList(list);

  /// Cache processed image data (legacy hash-based)
  Future<void> cacheImage(String base64String, Uint8List imageData) async {
    try {
      final cacheKey = _generateCacheKey(base64String);
      await _cacheBox.put(cacheKey, imageData.toList());
      debugPrint('✅ Cached image with key: ${cacheKey.substring(0, 8)}...');
    } catch (e) {
      debugPrint('❌ Error caching image: $e');
    }
  }

  /// Get cached image data (legacy hash-based — avoid on hot path)
  Uint8List? getCachedImage(String base64String) {
    try {
      final cacheKey = _generateCacheKey(base64String);
      final cachedData = _cacheBox.get(cacheKey);

      if (cachedData != null) {
        debugPrint('✅ Found cached image: ${cacheKey.substring(0, 8)}...');
        return Uint8List.fromList(cachedData);
      }

      debugPrint('⚠️ No cached image found: ${cacheKey.substring(0, 8)}...');
      return null;
    } catch (e) {
      debugPrint('❌ Error getting cached image: $e');
      return null;
    }
  }

  /// Check if image is cached
  bool isImageCached(String base64String) {
    try {
      final cacheKey = _generateCacheKey(base64String);
      return _cacheBox.containsKey(cacheKey);
    } catch (e) {
      debugPrint('❌ Error checking cache: $e');
      return false;
    }
  }

  /// Clear all cached images
  Future<void> clearCache() async {
    try {
      await _cacheBox.clear();
      debugPrint('✅ Image cache cleared');
    } catch (e) {
      debugPrint('❌ Error clearing cache: $e');
    }
  }

  /// Get cache size info
  Map<String, dynamic> getCacheInfo() {
    try {
      final totalImages = _cacheBox.length;
      final totalSizeBytes = _cacheBox.values
          .map((imageData) => imageData.length)
          .fold<int>(0, (sum, size) => sum + size);

      return {
        'totalImages': totalImages,
        'totalSizeBytes': totalSizeBytes,
        'totalSizeMB': (totalSizeBytes / (1024 * 1024)).toStringAsFixed(2),
      };
    } catch (e) {
      debugPrint('❌ Error getting cache info: $e');
      return {'totalImages': 0, 'totalSizeBytes': 0, 'totalSizeMB': '0.00'};
    }
  }

  @override
  void onClose() {
    _cacheBox.close();
    super.onClose();
  }
}
