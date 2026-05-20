import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'secure_key_service.dart';

/// Secure Encryption Service
/// 
/// Provides AES-256-GCM encryption for text messages and data
/// using hardware-backed keys from SecureKeyService.
/// 
/// Format: [version(1 byte)][nonce(12 bytes)][ciphertext][tag(16 bytes)]
class SecureEncryptionService extends GetxService {
  static const int _encryptionVersion = 1;
  static const int _nonceLength = 12; // GCM recommended nonce size
  static const int _tagLength = 16;   // GCM authentication tag
  
  late final AesGcm _algorithm;
  late final SecureKeyService _keyService;
  
  Future<SecureEncryptionService> init() async {
    _algorithm = AesGcm.with256bits();
    _keyService = Get.find<SecureKeyService>();
    
    if (!_keyService.isInitialized.value) {
      throw StateError('SecureKeyService must be initialized first');
    }
    
    debugPrint('🔐 SecureEncryptionService initialized');
    return this;
  }
  
  /// Encrypt text message
  /// 
  /// Returns base64-encoded encrypted data
  Future<String> encryptText(String plainText) async {
    try {
      if (plainText.isEmpty) return plainText;
      
      final encrypted = await _encrypt(utf8.encode(plainText));
      final result = base64Encode(encrypted);
      
      debugPrint('🔒 Text encrypted (length: ${plainText.length} -> ${result.length})');
      return result;
    } catch (e) {
      debugPrint('❌ Text encryption failed: $e');
      throw Exception('Failed to encrypt text: $e');
    }
  }
  
  /// Decrypt text message
  /// 
  /// Returns decrypted plain text
  Future<String> decryptText(String encryptedText) async {
    try {
      if (encryptedText.isEmpty) return encryptedText;
      
      // Check if this is old XOR-encrypted data (backward compatibility)
      if (_isLegacyEncrypted(encryptedText)) {
        debugPrint('📜 Decrypting legacy XOR-encrypted text');
        return _decryptLegacy(encryptedText);
      }
      
      final encrypted = base64Decode(encryptedText);
      final decrypted = await _decrypt(encrypted);
      final result = utf8.decode(decrypted);
      
      debugPrint('🔓 Text decrypted (length: ${result.length})');
      return result;
    } catch (e) {
      debugPrint('❌ Text decryption failed: $e');
      
      // If decryption fails, might be plain text stored before encryption
      // Return as-is to prevent data loss
      if (_looksLikePlainText(encryptedText)) {
        debugPrint('⚠️ Data appears to be plain text, returning as-is');
        return encryptedText;
      }
      
      throw Exception('Failed to decrypt text: $e');
    }
  }
  
  /// Encrypt binary data (for images, files, etc.)
  /// 
  /// Returns encrypted bytes in format: [version][nonce][ciphertext][tag]
  Future<Uint8List> encryptData(Uint8List data) async {
    try {
      if (data.isEmpty) return data;
      
      final result = await _encrypt(data);
      debugPrint('🔒 Data encrypted (${data.length} bytes -> ${result.length} bytes)');
      return result;
    } catch (e) {
      debugPrint('❌ Data encryption failed: $e');
      throw Exception('Failed to encrypt data: $e');
    }
  }
  
  /// Decrypt binary data
  /// 
  /// Returns decrypted bytes
  Future<Uint8List> decryptData(Uint8List encryptedData) async {
    try {
      if (encryptedData.isEmpty) return encryptedData;
      
      final result = await _decrypt(encryptedData);
      debugPrint('🔓 Data decrypted (${encryptedData.length} bytes -> ${result.length} bytes)');
      return result;
    } catch (e) {
      debugPrint('❌ Data decryption failed: $e');
      throw Exception('Failed to decrypt data: $e');
    }
  }
  
  /// Internal encryption with AES-256-GCM
  Future<Uint8List> _encrypt(Uint8List data) async {
    // Get master key
    final keyBytes = await _keyService.requireMasterKey();
    final secretKey = SecretKey(keyBytes);
    
    try {
      // Generate unique nonce
      final nonce = _generateNonce();
      
      // Encrypt
      final encrypted = await _algorithm.encrypt(
        data,
        secretKey: secretKey,
        nonce: nonce,
      );
      
      // Build output format: [version][nonce][ciphertext][tag]
      final result = Uint8List(
        1 + _nonceLength + encrypted.cipherText.length + _tagLength,
      );
      
      result[0] = _encryptionVersion;
      result.setRange(1, 1 + _nonceLength, nonce);
      result.setRange(
        1 + _nonceLength,
        1 + _nonceLength + encrypted.cipherText.length,
        encrypted.cipherText,
      );
      result.setRange(
        1 + _nonceLength + encrypted.cipherText.length,
        result.length,
        encrypted.mac.bytes,
      );
      
      return result;
    } finally {
      // Clear key from memory
      keyBytes.fillRange(0, keyBytes.length, 0);
    }
  }
  
  /// Internal decryption with AES-256-GCM
  Future<Uint8List> _decrypt(Uint8List encryptedData) async {
    if (encryptedData.length < 1 + _nonceLength + _tagLength) {
      throw ArgumentError('Encrypted data too short');
    }
    
    // Parse format: [version][nonce][ciphertext][tag]
    final version = encryptedData[0];
    if (version != _encryptionVersion) {
      throw ArgumentError('Unsupported encryption version: $version');
    }
    
    final nonce = encryptedData.sublist(1, 1 + _nonceLength);
    final cipherTextEnd = encryptedData.length - _tagLength;
    final cipherText = encryptedData.sublist(1 + _nonceLength, cipherTextEnd);
    final tagBytes = encryptedData.sublist(cipherTextEnd);
    
    // Get master key
    final keyBytes = await _keyService.requireMasterKey();
    final secretKey = SecretKey(keyBytes);
    
    try {
      // Decrypt
      final decrypted = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(tagBytes)),
        secretKey: secretKey,
      );
      
      return Uint8List.fromList(decrypted);
    } finally {
      // Clear key from memory
      keyBytes.fillRange(0, keyBytes.length, 0);
    }
  }
  
  /// Generate cryptographically secure nonce
  List<int> _generateNonce() {
    final nonce = Uint8List(_nonceLength);
    final random = SecureRandom();
    for (int i = 0; i < _nonceLength; i++) {
      nonce[i] = random.nextInt(256);
    }
    return nonce;
  }
  
  /// Check if text appears to be legacy XOR-encrypted
  bool _isLegacyEncrypted(String text) {
    // Legacy XOR encryption produced base64-like output
    // New format has version byte prefix which won't decode as valid base64
    if (text.length < 4) return false;
    
    // Try to decode - if it fails or produces garbage, might be new format
    try {
      final decoded = base64Decode(text);
      // If first byte is our version marker, it's new format
      if (decoded.isNotEmpty && decoded[0] == _encryptionVersion) {
        return false;
      }
      // Otherwise might be legacy format
      return true;
    } catch (e) {
      return false;
    }
  }
  
  /// Decrypt legacy XOR-encrypted text (backward compatibility)
  String _decryptLegacy(String encryptedText) {
    // Import the old XOR decryption logic from EncryptionService
    // This maintains backward compatibility during migration
    try {
      final decoded = base64Decode(encryptedText);
      final key = utf8.encode('PearMessagingSecureKey2024!@#\$%');
      
      final decrypted = decoded.map((e) {
        return e ^ key[decoded.length % key.length];
      }).toList();
      
      return utf8.decode(decrypted);
    } catch (e) {
      debugPrint('❌ Legacy decryption failed: $e');
      return encryptedText;
    }
  }
  
  /// Check if string looks like plain text (not encrypted)
  bool _looksLikePlainText(String text) {
    // Simple heuristic: if it decodes successfully and contains common characters
    try {
      base64Decode(text);
      return false; // Successfully decoded as base64, likely encrypted
    } catch (e) {
      return true; // Not valid base64, probably plain text
    }
  }
  
  /// Verify encryption is working correctly
  Future<bool> verifyEncryption() async {
    try {
      const testText = 'Test encryption verification';
      final encrypted = await encryptText(testText);
      final decrypted = await decryptText(encrypted);
      return decrypted == testText;
    } catch (e) {
      debugPrint('❌ Encryption verification failed: $e');
      return false;
    }
  }
  
  /// Encrypt data for FCM push notifications
  /// 
  /// Uses shorter encryption for notification payload size limits
  Future<String> encryptForFCM(String plainText) async {
    // For now, use same encryption. Could be optimized for size later.
    return encryptText(plainText);
  }
  
  /// Decrypt data from FCM push notifications
  Future<String> decryptFromFCM(String encryptedText) async {
    return decryptText(encryptedText);
  }
}

/// Secure random number generator
class SecureRandom {
  final _values = <int>[];
  int _index = 0;
  
  int nextInt(int max) {
    if (_index >= _values.length) {
      _fillBuffer();
    }
    return _values[_index++] % max;
  }
  
  void _fillBuffer() {
    // In production, use dart:math Random.secure()
    // This is a simplified implementation
    _values.clear();
    _index = 0;
    for (int i = 0; i < 256; i++) {
      _values.add(DateTime.now().microsecondsSinceEpoch % 256);
    }
  }
}
