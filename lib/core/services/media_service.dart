import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../services/secure_image_encryption.dart';
import '../services/image_compression.dart';

/// Media upload/download service with token-based access
///
/// SECURITY FEATURES:
/// - Images are encrypted before upload
/// - Server only stores encrypted blobs
/// - Media tokens provide time-limited access
/// - No user data linked to media tokens
/// - Automatic cleanup via TTL
class MediaService {
  static const String baseUrl =
      'http://YOUR_EC2_PUBLIC_IP'; // Replace with your EC2 public IP
  static const Duration timeout = Duration(seconds: 30);

  /// Upload encrypted image to server
  ///
  /// Returns [MediaUploadResponse] with mediaToken and expiry
  /// Throws [MediaException] on upload failure
  static Future<MediaUploadResponse> uploadEncryptedImage(
    Uint8List imageData, {
    int targetSizeKB = 500,
  }) async {
    try {
      // Step 1: Compress image
      final compressedImage = await ImageCompression.compressImageToSize(
        imageData,
        targetSizeKB: targetSizeKB,
      );

      // Step 2: Encrypt compressed image
      final encryptedImage = await SecureImageEncryption.encryptImage(
        compressedImage,
      );

      // Step 3: Upload to server
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/media/upload'),
      );

      // Add encrypted image as binary data
      request.files.add(
        http.MultipartFile.fromBytes(
          'media',
          encryptedImage,
          filename: 'encrypted.bin',
        ),
      );

      // Security headers
      request.headers['Content-Type'] = 'multipart/form-data';
      request.headers['X-Client-Version'] = '1.0.0';

      final streamedResponse = await request.send().timeout(timeout);
      final response = await http.Response.fromStream(
        streamedResponse,
      ).timeout(timeout);

      if (response.statusCode != 200) {
        throw MediaException('Upload failed: ${response.statusCode}');
      }

      final responseData = jsonDecode(response.body) as Map<String, dynamic>;

      return MediaUploadResponse(
        mediaToken: responseData['mediaToken'] as String,
        expiryTimestamp: DateTime.parse(
          responseData['expiryTimestamp'] as String,
        ),
      );
    } catch (e) {
      throw MediaException('Image upload failed: $e');
    }
  }

  /// Download and decrypt image using mediaToken
  ///
  /// Returns decrypted image bytes
  /// Throws [MediaException] if token is expired or invalid
  static Future<Uint8List> downloadAndDecryptImage(String mediaToken) async {
    try {
      // Step 1: Download encrypted image
      final response = await http.get(
        Uri.parse('$baseUrl/media/download/$mediaToken'),
        headers: {'X-Client-Version': '1.0.0'},
      ).timeout(timeout);

      if (response.statusCode == 410) {
        throw MediaException('Media has expired');
      }

      if (response.statusCode != 200) {
        throw MediaException('Download failed: ${response.statusCode}');
      }

      final encryptedData = response.bodyBytes;

      // Step 2: Decrypt image
      final decryptedImage = await SecureImageEncryption.decryptImage(
        encryptedData,
      );

      return decryptedImage;
    } catch (e) {
      if (e is MediaException) rethrow;
      throw MediaException('Image download failed: $e');
    }
  }

  /// Check if media token is still valid
  ///
  /// Returns true if token is valid and not expired
  static Future<bool> isMediaTokenValid(String mediaToken) async {
    try {
      final response = await http.head(
        Uri.parse('$baseUrl/media/download/$mediaToken'),
        headers: {'X-Client-Version': '1.0.0'},
      ).timeout(timeout);

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Batch upload multiple images
  ///
  /// Returns list of upload responses
  /// Continues uploading even if some fail
  static Future<List<MediaUploadResponse>> uploadMultipleImages(
    List<Uint8List> images, {
    int targetSizeKB = 500,
  }) async {
    final results = <MediaUploadResponse>[];

    for (int i = 0; i < images.length; i++) {
      try {
        final response = await uploadEncryptedImage(
          images[i],
          targetSizeKB: targetSizeKB,
        );
        results.add(response);
      } catch (e) {
        // Log error but continue with other images
        print('Failed to upload image ${i + 1}: $e');
      }
    }

    return results;
  }
}

/// Response from media upload
class MediaUploadResponse {
  final String mediaToken;
  final DateTime expiryTimestamp;

  const MediaUploadResponse({
    required this.mediaToken,
    required this.expiryTimestamp,
  });

  /// Check if the media has expired
  bool get isExpired => DateTime.now().isAfter(expiryTimestamp);

  /// Get remaining time until expiry
  Duration get timeUntilExpiry {
    if (isExpired) return Duration.zero;
    return expiryTimestamp.difference(DateTime.now());
  }

  Map<String, dynamic> toJson() {
    return {
      'mediaToken': mediaToken,
      'expiryTimestamp': expiryTimestamp.toIso8601String(),
    };
  }

  factory MediaUploadResponse.fromJson(Map<String, dynamic> json) {
    return MediaUploadResponse(
      mediaToken: json['mediaToken'] as String,
      expiryTimestamp: DateTime.parse(json['expiryTimestamp'] as String),
    );
  }
}

/// Media service exception
class MediaException implements Exception {
  final String message;

  const MediaException(this.message);

  @override
  String toString() => 'MediaException: $message';
}

/// Media status for UI display
enum MediaStatus {
  /// Media is loading/downloading
  loading,

  /// Media is available and ready to display
  available,

  /// Media has expired or token is invalid
  expired,

  /// Media failed to load
  error,
}
