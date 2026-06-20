import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../constants/security_constants.dart';

class QRService {
  static const String _appSignature = 'PEAR_CHAT_V1';
  static const String _secretKey = SecurityConstants.qrSecretKey;

  /// Generate a secure QR code data for the current user
  static Future<String> generateQRData(String deviceId) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final nonce = _generateNonce();

    // Create the payload
    final payload = {
      'app': _appSignature,
      'deviceId': deviceId,
      'timestamp': timestamp,
      'nonce': nonce,
    };

    // Create signature to verify authenticity
    final signature = _createSignature(payload);
    payload['signature'] = signature;

    // Encode as JSON and then base64
    final jsonString = json.encode(payload);
    final base64Data = base64.encode(utf8.encode(jsonString));

    return base64Data;
  }

  /// Validate and extract device ID from scanned QR code
  static Future<String?> validateQRData(String qrData) async {
    try {
      // Decode from base64 and JSON
      final jsonString = utf8.decode(base64.decode(qrData));
      final Map<String, dynamic> payload = json.decode(jsonString);

      // Check app signature
      if (payload['app'] != _appSignature) {
        return null; // Not from our app
      }

      // Check timestamp (valid for 24 hours)
      final timestamp = payload['timestamp'] as int;
      final now = DateTime.now().millisecondsSinceEpoch;
      final hoursDiff = (now - timestamp) / (1000 * 60 * 60);

      if (hoursDiff > 24) {
        return null; // QR code expired
      }

      // Verify signature
      final receivedSignature = payload['signature'] as String;
      payload.remove('signature');
      final expectedSignature = _createSignature(payload);

      if (receivedSignature != expectedSignature) {
        return null; // Invalid signature
      }

      // Return the device ID if valid
      return payload['deviceId'] as String;
    } catch (e) {
      return null; // Invalid QR code format
    }
  }

  /// Create HMAC signature for payload verification
  static String _createSignature(Map<String, dynamic> payload) {
    final sortedKeys = payload.keys.toList()..sort();
    final dataString =
        sortedKeys.map((key) => '$key=${payload[key]}').join('&');

    final key = utf8.encode(_secretKey);
    final bytes = utf8.encode(dataString);
    final hmac = Hmac(sha256, key);
    final digest = hmac.convert(bytes);

    return digest.toString();
  }

  /// Generate random nonce for uniqueness
  static String _generateNonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (i) => random.nextInt(256));
    return base64.encode(bytes);
  }

  /// Check if QR code is from our app (quick validation)
  static bool isValidAppQR(String qrData) {
    try {
      final jsonString = utf8.decode(base64.decode(qrData));
      final Map<String, dynamic> payload = json.decode(jsonString);
      return payload['app'] == _appSignature;
    } catch (e) {
      return false;
    }
  }
}
