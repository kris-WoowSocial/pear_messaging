import 'package:flutter/material.dart';

enum CallEncryptionState {
  encryptedVerified,
  encryptedUnverified,
  legacyUnencrypted,
}

class CallEncryptionIndicator extends StatelessWidget {
  const CallEncryptionIndicator({required this.state, super.key});

  final CallEncryptionState state;

  @override
  Widget build(BuildContext context) {
    final (icon, text, color) = switch (state) {
      CallEncryptionState.encryptedVerified => (
          Icons.verified_user,
          'Encrypted and verified',
          const Color(0xFF4CD964),
        ),
      CallEncryptionState.encryptedUnverified => (
          Icons.lock,
          'Encrypted — not verified',
          const Color(0xFFFFCC00),
        ),
      CallEncryptionState.legacyUnencrypted => (
          Icons.lock_open,
          'Not end-to-end encrypted',
          const Color(0xFFFF8A80),
        ),
    };

    return Container(
      key: const ValueKey('call_encryption_indicator'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.65)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
