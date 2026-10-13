import 'package:flutter/material.dart';

enum CallEncryptionState {
  securing,
  encryptedVerified,
  encryptedUnverified,
  legacyUnencrypted,
}

class CallEncryptionIndicator extends StatelessWidget {
  const CallEncryptionIndicator({required this.state, super.key});

  static const directEncryptionMessage =
      'Encrypted, direct device-to-device link.\n'
      'Because Vant works without servers, nobody—not even an AI—can intercept, save, or spy on what you say.';

  final CallEncryptionState state;

  @override
  Widget build(BuildContext context) {
    final (icon, text, color) = switch (state) {
      CallEncryptionState.securing => (
          Icons.lock_outline,
          'Securing call…',
          const Color(0xFF64B5F6),
        ),
      CallEncryptionState.encryptedVerified => (
          Icons.lock,
          'End-to-end encrypted',
          const Color(0xFF4CD964),
        ),
      CallEncryptionState.encryptedUnverified => (
          Icons.lock_outline,
          'Encrypted, contact not verified',
          const Color(0xFF64B5F6),
        ),
      CallEncryptionState.legacyUnencrypted => (
          Icons.lock_open,
          'Not end-to-end encrypted',
          const Color(0xFFFF8A80),
        ),
    };

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width - 64,
      ),
      child: Container(
        key: const ValueKey('call_encryption_indicator'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.65)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(height: 4),
            Text(
              text,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: color,
                fontSize: 11.5,
                height: 1.3,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
