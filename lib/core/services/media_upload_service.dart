import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../constants/network_constants.dart';

/// HTTP-based media upload / download-once service.
///
/// Images are encrypted client-side before upload so the server
/// only ever stores an opaque encrypted blob.  Each token can be
/// downloaded exactly once — the server deletes the blob afterwards.
class MediaUploadService {
  static String get _baseUrl => NetworkConstants.apiBaseUrl;
  static const Duration _timeout = Duration(seconds: 120);

  /// Upload an encrypted image blob and return the one-time token.
  ///
  /// [encryptedBlob] is a base64 string (already XOR-encrypted by
  /// [EncryptionService]).
  /// [onProgress] is called with upload progress (0.0 to 1.0).
  /// Returns the token string on success, or throws on failure.
  static Future<String> uploadImage(
    String encryptedBlob, {
    void Function(double progress)? onProgress,
    int maxRetries = 3,
  }) async {
    debugPrint(
      '📤 MediaUploadService: uploading blob (${encryptedBlob.length} chars)',
    );

    // Check blob size before upload
    if (encryptedBlob.length > 1024 * 1024) {
      debugPrint(
        '⚠️ MediaUploadService: blob size > 1MB, this may cause timeouts',
      );
    }

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      if (attempt > 0) {
        debugPrint(
          '🔄 MediaUploadService: retry attempt ${attempt + 1}/$maxRetries',
        );
        // Exponential backoff: 2s, 4s, 8s
        await Future.delayed(Duration(seconds: 1 << attempt));
      }

      try {
        final token = await _attemptUpload(encryptedBlob, onProgress);
        debugPrint(
          '✅ MediaUploadService: upload succeeded on attempt ${attempt + 1}',
        );
        return token;
      } on TimeoutException {
        debugPrint('⏰ MediaUploadService: timeout on attempt ${attempt + 1}');
        if (attempt == maxRetries - 1) {
          throw Exception(
            'Upload timeout after $maxRetries attempts - please check your connection and try again',
          );
        }
      } catch (e) {
        debugPrint('❌ MediaUploadService: attempt ${attempt + 1} failed: $e');
        if (attempt == maxRetries - 1) {
          rethrow; // Re-throw the last error
        }
      }
    }

    throw Exception('Upload failed after $maxRetries attempts');
  }

  static Future<String> _attemptUpload(
    String encryptedBlob,
    void Function(double progress)? onProgress,
  ) async {
    final uri = Uri.parse('$_baseUrl/api/media/upload');
    final request = http.Request('POST', uri);
    request.headers['Content-Type'] = 'application/json';

    final bodyBytes = utf8.encode(jsonEncode({'encryptedBlob': encryptedBlob}));
    request.bodyBytes = bodyBytes;

    final client = http.Client();
    try {
      debugPrint('📤 MediaUploadService: starting upload to $_baseUrl');
      final streamedResponse = await client.send(request).timeout(_timeout);

      // For upload, we can't track real progress with standard http package
      // (would need dio or custom implementation), so just report completion
      onProgress?.call(1.0);

      final response = await http.Response.fromStream(
        streamedResponse,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final token = data['token'] as String;
        debugPrint('✅ MediaUploadService: upload succeeded, token=$token');
        return token;
      }

      throw Exception(
        'Media upload failed: HTTP ${response.statusCode} – ${response.body}',
      );
    } finally {
      client.close();
    }
  }

  /// Download the encrypted blob for [token].
  ///
  /// [onProgress] is called with download progress (0.0 to 1.0).
  /// Returns the base64 encrypted string on success.
  /// Returns `null` if the media has already been downloaded (410 Gone)
  /// or is otherwise unavailable.
  static Future<String?> downloadImage(
    String token, {
    void Function(double progress)? onProgress,
  }) async {
    debugPrint('📥 MediaUploadService: downloading token=$token');

    try {
      final request = http.Request(
        'GET',
        Uri.parse('$_baseUrl/api/media/$token'),
      );
      final client = http.Client();

      try {
        final streamedResponse = await client.send(request).timeout(_timeout);

        if (streamedResponse.statusCode == 410) {
          debugPrint(
            '⚠️ MediaUploadService: media already downloaded or expired (410)',
          );
          return null;
        }

        if (streamedResponse.statusCode != 200) {
          debugPrint(
            '❌ MediaUploadService: download failed HTTP ${streamedResponse.statusCode}',
          );
          return null;
        }

        final contentLength = streamedResponse.contentLength ?? 0;
        final chunks = <int>[];
        int downloaded = 0;

        await for (final chunk in streamedResponse.stream) {
          chunks.addAll(chunk);
          downloaded += chunk.length;

          if (contentLength > 0) {
            onProgress?.call(downloaded / contentLength);
          }
        }

        final responseBody = utf8.decode(chunks);
        final data = jsonDecode(responseBody) as Map<String, dynamic>;
        final blob = data['encryptedBlob'] as String;

        onProgress?.call(1.0);
        debugPrint(
          '✅ MediaUploadService: download succeeded (${blob.length} chars)',
        );
        return blob;
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('❌ MediaUploadService: download error: $e');
      return null;
    }
  }
}
