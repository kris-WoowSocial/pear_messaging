import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/services/identity_verification_service.dart';
import '../../core/utils/safety_code.dart';

/// Contact verification screen (Phase 1). Two tabs: show my QR / scan theirs.
/// The safety-code digits sit below in both tabs for verbal comparison.
///
/// Honest wording — messages are NOT end-to-end encrypted yet, so this is
/// "identity key verified", not a lock. No lock icon is shown.
class VerifyContactScreen extends StatefulWidget {
  const VerifyContactScreen({super.key, required this.peerId});

  final String peerId;

  @override
  State<VerifyContactScreen> createState() => _VerifyContactScreenState();
}

class _VerifyContactScreenState extends State<VerifyContactScreen> {
  final _service = Get.find<IdentityVerificationService>();
  final _scanner = MobileScannerController();
  Timer? _rotateTimer;
  bool _scanned = false;

  @override
  void initState() {
    super.initState();
    _service.openVerification(widget.peerId);
    // Keep the QR secret fresh while the screen is open.
    _rotateTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _service.maybeRotateSecret();
      if (mounted) setState(() {});
    });
    // Displayer-side "X scanned your code. Confirm?" prompt.
    ever(_service.pendingScannerId, (id) {
      if (id != null && mounted) _showScannerConfirm(id);
    });
  }

  @override
  void dispose() {
    _rotateTimer?.cancel();
    _scanner.dispose();
    _service.closeVerification();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          title: const Text('Verify identity key'),
          bottom: const TabBar(
            tabs: [Tab(text: 'My code'), Tab(text: 'Scan')],
          ),
        ),
        body: TabBarView(
          children: [_buildMyCodeTab(), _buildScanTab()],
        ),
      ),
    );
  }

  Widget _buildMyCodeTab() {
    final payload = _service.qrPayload();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSizes.paddingL),
      child: Column(
        children: [
          const Text(
            'Have your contact scan this code to verify your identity key.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          if (payload != null)
            QrImageView(data: payload, size: 240),
          const SizedBox(height: 24),
          _buildSafetyCode(),
        ],
      ),
    );
  }

  Widget _buildScanTab() {
    return Column(
      children: [
        Expanded(
          flex: 2,
          child: MobileScanner(
            controller: _scanner,
            onDetect: (capture) {
              if (_scanned) return;
              final raw = capture.barcodes.firstOrNull?.rawValue;
              if (raw == null) return;
              _scanned = true;
              _handleScan(raw);
            },
          ),
        ),
        Expanded(child: _buildSafetyCode()),
      ],
    );
  }

  Widget _buildSafetyCode() {
    return Obx(() {
      final code = _service.safetyCode.value;
      if (code == null) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'No identity key pinned for this contact yet —\nscan their QR to establish one.',
            textAlign: TextAlign.center,
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text('Compare these numbers on both phones:'),
            const SizedBox(height: 8),
            Text(
              SafetyCode.formatGroups(code),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      );
    });
  }

  void _showScannerConfirm(String scannerId) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Code scanned'),
        content: Text(
            'Contact $scannerId scanned your code. Is this the person next to you?'),
        actions: [
          TextButton(
            onPressed: () {
              _service.rejectScanner();
              Navigator.of(ctx).pop();
            },
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              final ok = await _service.confirmScanner();
              if (mounted) {
                Get.snackbar(
                  ok ? 'Verified' : 'Verification failed',
                  ok
                      ? 'Identity key verified for $scannerId'
                      : 'Could not save verification',
                  snackPosition: SnackPosition.BOTTOM,
                );
              }
            },
            child: const Text('Yes, verify'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleScan(String raw) async {
    final (result, scannedId, scannedBundle) =
        await _service.handleScannedQr(raw);
    _lastScannedBundle = scannedBundle;
    if (!mounted) return;
    switch (result) {
      case IdentityVerificationService.scanVerified:
        Get.snackbar('Verified', 'Identity key verified.',
            snackPosition: SnackPosition.BOTTOM);
        Get.back();
      case IdentityVerificationService.scanPinnedNew:
        Get.snackbar('Verified', 'Identity key pinned and verified.',
            snackPosition: SnackPosition.BOTTOM);
        Get.back();
      case IdentityVerificationService.scanMismatch:
        await _showMismatchDialog(scannedId!);
      default:
        Get.snackbar('Invalid code', 'This is not a Vant verification code.',
            snackPosition: SnackPosition.BOTTOM);
        _scanned = false;
    }
  }

  /// Key mismatch — the scanned key may be the real one and the pin the
  /// attacker's. Show both safety codes; user chooses explicitly.
  Future<void> _showMismatchDialog(String scannedId) async {
    // Rebuild the scanned bundle from what was just parsed.
    // (The service stored nothing; re-parse via scannedSafetyCode path.)
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Key changed'),
        content: const Text(
          'The scanned identity key is different from the one stored for '
          'this contact. This can mean their app was reinstalled — or that '
          'a key was swapped. Compare the numbers above on BOTH phones '
          'before deciding.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              setState(() => _scanned = false);
            },
            child: const Text('Keep existing'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.of(ctx).pop();
              // scannedBundle is the last scanned payload's bundle — the
              // service already validated it inside handleScannedQr.
              // We re-verify via the service's replace call.
              final ok = await _replacePinFromLastScan(scannedId);
              if (mounted) {
                Get.snackbar(
                  ok ? 'Key replaced' : 'Failed',
                  ok ? 'New identity key verified.' : 'Could not save',
                  snackPosition: SnackPosition.BOTTOM,
                );
                if (ok) Get.back();
              }
            },
            child: const Text('Replace key'),
          ),
        ],
      ),
    );
  }

  String? _lastScannedBundle;

  Future<bool> _replacePinFromLastScan(String scannedId) async {
    final b = _lastScannedBundle;
    if (b == null) return false;
    return _service.confirmReplacePin(scannedId, b);
  }
}
