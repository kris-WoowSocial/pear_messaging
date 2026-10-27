import 'package:flutter/material.dart';

enum CallEncryptionState {
  connecting,
  securing,
  encryptedVerified,
  encryptedUnverified,
  legacyUnencrypted,
}

class CallEncryptionIndicator extends StatelessWidget {
  const CallEncryptionIndicator({required this.state, super.key});



  final CallEncryptionState state;

  /// Only the final encryption outcome is shown. Intermediate
  /// connecting/securing states render nothing so users never see a
  /// "not encrypted" flicker while the call is still being set up.
  bool get _isFinal =>
      state == CallEncryptionState.encryptedVerified ||
      state == CallEncryptionState.encryptedUnverified ||
      state == CallEncryptionState.legacyUnencrypted;

  @override
  Widget build(BuildContext context) {
    final (icon, text, color) = switch (state) {
      CallEncryptionState.connecting => (
          Icons.more_horiz,
          'Connecting…',
          Colors.white70,
        ),
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
          Icons.lock,
          'Encrypted, direct device-to-device link.\n'
          'Because Vant works without servers, nobody—not even an AI—can intercept, save, or spy on what you say.',
          const Color(0xFF4CD964),
        ),
      CallEncryptionState.legacyUnencrypted => (
          Icons.lock,
          'End-to-end encrypted',
          const Color(0xFF4CD964),
        ),
    };

    final media = MediaQuery.of(context);
    // The full copy must always be readable: clamp the user's text scale so
    // large-font devices can't blow the banner up, never truncate, keep the
    // width inside safe-area padding, and let short/landscape screens scroll
    // instead of clipping into the control bar or self-view tile.
    final scaler = media.textScaler.clamp(
      minScaleFactor: 0.85,
      maxScaleFactor: 1.3,
    );
    return Visibility(
      visible: _isFinal,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: media.size.width - media.padding.horizontal - 32,
          maxHeight: media.size.height * 0.5,
        ),
        child: Container(
          key: const ValueKey('call_encryption_indicator'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withValues(alpha: 0.65)),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(height: 4),
                Text(
                  text,
                  textScaler: scaler,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: color,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
