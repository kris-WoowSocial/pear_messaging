import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../constants/app_colors.dart';
import '../services/report_service.dart';
import '../services/block_service.dart';

class ReportBottomSheet extends StatefulWidget {
  final String targetType; // 'user' or 'message'
  final String targetId;

  const ReportBottomSheet({
    super.key,
    required this.targetType,
    required this.targetId,
  });

  /// Show the report bottom sheet
  static void show({
    required String targetType,
    required String targetId,
  }) {
    Get.bottomSheet(
      ReportBottomSheet(
        targetType: targetType,
        targetId: targetId,
      ),
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
    );
  }

  @override
  State<ReportBottomSheet> createState() => _ReportBottomSheetState();
}

class _ReportBottomSheetState extends State<ReportBottomSheet> {
  String? _selectedReason;
  final _descriptionController = TextEditingController();
  bool _isSubmitting = false;

  static const List<String> _reasons = [
    'Spam',
    'Harassment / Hate Speech',
    'Threats / Violence',
    'Sexual / Explicit Content',
    'Fraud / Scam',
    'Self-harm',
    'Other',
  ];

  static const Map<String, IconData> _reasonIcons = {
    'Spam': Icons.report_gmailerrorred,
    'Harassment / Hate Speech': Icons.sentiment_very_dissatisfied,
    'Threats / Violence': Icons.warning_amber_rounded,
    'Sexual / Explicit Content': Icons.no_adult_content,
    'Fraud / Scam': Icons.money_off,
    'Self-harm': Icons.healing,
    'Other': Icons.more_horiz,
  };

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submitReport() async {
    if (_selectedReason == null) {
      Get.snackbar(
        'Select a Reason',
        'Please select a reason for your report',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.orange.shade100,
        colorText: Colors.orange.shade800,
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final reportService = Get.find<ReportService>();
      final success = await reportService.submitReport(
        targetType: widget.targetType,
        targetId: widget.targetId,
        reason: _selectedReason!,
        description: _descriptionController.text.trim(),
      );

      Get.back(); // Close bottom sheet

      if (success) {
        // Show block user popup if reporting a user
        if (widget.targetType == 'user') {
          _showBlockUserPopup();
        } else {
          Get.snackbar(
            'Report Submitted',
            'Thank you. Our team will review this report.',
            snackPosition: SnackPosition.BOTTOM,
            backgroundColor: Colors.green.shade100,
            colorText: Colors.green.shade800,
            icon: Icon(Icons.check_circle, color: Colors.green.shade600),
            duration: const Duration(seconds: 3),
          );
        }
      } else {
        Get.snackbar(
          'Error',
          'Failed to submit report. Please try again.',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.shade100,
          colorText: Colors.red.shade800,
          icon: Icon(Icons.error, color: Colors.red.shade600),
        );
      }
    } catch (e) {
      Get.back();
      Get.snackbar(
        'Error',
        'Something went wrong. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  void _showBlockUserPopup() {
    Get.dialog(
      Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Success icon
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.green.shade100,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.check_circle,
                  size: 32,
                  color: Colors.green.shade600,
                ),
              ),
              const SizedBox(height: 20),

              // Success message
              Text(
                'Report Submitted!',
                style: Get.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade800,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Thank you for helping keep our community safe.',
                style: Get.textTheme.bodyMedium?.copyWith(
                  color: Colors.grey.shade600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // Block question
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.block,
                      size: 32,
                      color: Colors.orange.shade700,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Block this user?',
                      style: Get.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade800,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Would you also like to block this user? Blocked users won\'t be able to send you messages.',
                      style: Get.textTheme.bodySmall?.copyWith(
                        color: Colors.grey.shade600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Action buttons
              Row(
                children: [
                  // No button
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Get.back(); // Close dialog
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        side: BorderSide(color: Colors.grey.shade300),
                      ),
                      child: Text(
                        'No, Thanks',
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Yes, Block button
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Get.back(); // Close dialog
                        _blockUser();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Yes, Block',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      barrierDismissible: false, // Prevent accidental dismissal
    );
  }

  void _blockUser() {
    try {
      final blockService = Get.find<BlockService>();
      blockService.blockUser(widget.targetId);

      Get.snackbar(
        'User Blocked',
        'You have blocked this user. They can no longer send you messages.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.orange.shade100,
        colorText: Colors.orange.shade800,
        icon: Icon(Icons.block, color: Colors.orange.shade600),
        duration: const Duration(seconds: 3),
      );
    } catch (e) {
      Get.snackbar(
        'Error',
        'Failed to block user. Please try again.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red.shade100,
        colorText: Colors.red.shade800,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle bar
              Align(
                alignment: Alignment.center,
                child: Container(
                  width: 50,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Title
              Row(
                children: [
                  Icon(Icons.flag_outlined,
                      color: Colors.red.shade400, size: 24),
                  const SizedBox(width: 8),
                  Text(
                    widget.targetType == 'user'
                        ? 'Report User'
                        : 'Report Message',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Why are you reporting this ${widget.targetType}?',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 20),

              // Reason selector
              ..._reasons.map((reason) => _buildReasonTile(reason)),

              // Description field (shown when 'Other' is selected or always)
              if (_selectedReason != null) ...[
                const SizedBox(height: 16),
                Text(
                  'Additional details (optional)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _descriptionController,
                  maxLines: 3,
                  maxLength: 500,
                  decoration: InputDecoration(
                    hintText: 'Describe the issue...',
                    hintStyle: TextStyle(color: Colors.grey.shade400),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.primary),
                    ),
                    contentPadding: const EdgeInsets.all(14),
                  ),
                ),
              ],

              const SizedBox(height: 20),

              // Submit button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submitReport,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade600,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    disabledBackgroundColor: Colors.grey.shade300,
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Text(
                          'Submit Report',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              // Add padding for keyboard and system navigation bar
              SizedBox(
                height: MediaQuery.of(context).viewInsets.bottom +
                    20, // Extra padding for nav bar
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReasonTile(String reason) {
    final isSelected = _selectedReason == reason;
    return GestureDetector(
      onTap: () => setState(() => _selectedReason = reason),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? Colors.red.shade50 : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? Colors.red.shade300 : Colors.grey.shade200,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              _reasonIcons[reason] ?? Icons.flag,
              size: 20,
              color: isSelected ? Colors.red.shade600 : Colors.grey.shade500,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                reason,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color:
                      isSelected ? Colors.red.shade700 : Colors.grey.shade700,
                ),
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, color: Colors.red.shade500, size: 20),
          ],
        ),
      ),
    );
  }
}
