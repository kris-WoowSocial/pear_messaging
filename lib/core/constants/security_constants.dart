/// Security Configuration Constants
/// Contains encryption keys, API keys, and other sensitive configuration
/// NOTE: In production, these should be loaded from environment variables or secure storage
class SecurityConstants {
  // Stripe Payment Configuration
  static const String stripePublishableKey =
      'pk_live_51TOkyVIC9vv7zpPxQHj0TE6JA9qRW0RlLQBR0gLsLJqxVwWSObl0uwbTIRzwemrTvgNY8y2mMPhdEB93HIERXhzg00lr6lYUqD';

  // QR Code Encryption Secret
  // Used for validating QR code authenticity
  static const String qrSecretKey = 'pear_messaging_secret_2024';

  // XOR Encryption Key
  // Used for simple XOR encryption of message content
  static const String xorEncryptionKey = 'pear_messaging_xor_key_2024';
}
