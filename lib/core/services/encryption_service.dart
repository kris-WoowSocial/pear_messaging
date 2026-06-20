import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../constants/security_constants.dart';

/// Simple XOR encryption (compatible with encrypt_decrypt_plus XOR)
class _XOR {
  final String secretKey;
  _XOR({required this.secretKey});

  List<int> _xor(List<int> bytes, List<int> keys) {
    return bytes.map((e) => e ^ keys[bytes.length % keys.length]).toList();
  }

  String xorEncode(String content) {
    return base64Encode(_xor(utf8.encode(content), utf8.encode(secretKey)));
  }

  String xorDecode(String content) {
    return utf8.decode(_xor(base64Decode(content), utf8.encode(secretKey)));
  }
}

class EncryptionService extends GetxService {
  static const String _encryptionKey = SecurityConstants.xorEncryptionKey;
  static final _XOR xor = _XOR(secretKey: _encryptionKey);

  /// Encrypt message content using encrypt_decrypt_plus
  static String encryptMessage(String plainText) {
    try {
      if (plainText.isEmpty) return plainText;

      // Use XOR encryption from encrypt_decrypt_plus
      final encrypted = xor.xorEncode(plainText);
      debugPrint('🔒 Message encrypted successfully');
      return encrypted;
    } catch (e) {
      debugPrint('❌ Encryption failed with encrypt_decrypt_plus: $e');
      // Fallback to simple base64 encoding if package fails
      try {
        final encoded = base64Encode(utf8.encode(plainText));
        debugPrint('🔒 Using fallback base64 encoding');
        return encoded;
      } catch (fallbackError) {
        debugPrint('❌ Fallback encoding also failed: $fallbackError');
        return plainText;
      }
    }
  }

  /// Decrypt message content using encrypt_decrypt_plus
  static String decryptMessage(String encryptedText) {
    try {
      if (encryptedText.isEmpty) return encryptedText;

      // Check if it's already decrypted (plain text)
      if (!_isEncrypted(encryptedText)) {
        return encryptedText;
      }

      // Try XOR decryption from encrypt_decrypt_plus
      final decrypted = xor.xorDecode(encryptedText);
      debugPrint('🔓 Message decrypted successfully');
      return decrypted;
    } catch (e) {
      debugPrint('❌ Decryption failed with encrypt_decrypt_plus: $e');
      // Fallback to base64 decoding
      try {
        final decoded = utf8.decode(base64Decode(encryptedText));
        debugPrint('🔓 Using fallback base64 decoding');
        return decoded;
      } catch (fallbackError) {
        debugPrint('❌ Fallback decoding also failed: $fallbackError');
        return encryptedText;
      }
    }
  }

  /// Check if text appears to be encrypted
  static bool _isEncrypted(String text) {
    // Basic check - encrypted text from encrypt_decrypt_plus is typically base64-like
    if (text.length < 4) return false;

    // Check for base64 pattern - XOR encrypted text is base64 encoded
    final base64Pattern = RegExp(r'^[A-Za-z0-9+/=]+$');

    // Additional check: base64 strings often end with = padding
    // and have length that's multiple of 4 (after padding)
    bool hasBase64Pattern = base64Pattern.hasMatch(text);
    bool hasValidBase64Length = text.length % 4 == 0 || text.endsWith('=');

    return hasBase64Pattern && hasValidBase64Length;
  }

  /// Encrypt data for FCM payload
  static String encryptForFCM(String plainText) {
    return encryptMessage(plainText);
  }

  /// Decrypt data from FCM payload
  static String decryptFromFCM(String encryptedText) {
    return decryptMessage(encryptedText);
  }
}
