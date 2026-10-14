import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/utils/string_utils.dart';
import '../../storage/models/call_history_entry.dart';
import '../call/call_controller.dart';
import 'call_history_controller.dart';

/// Call History Screen - Shows all call logs like WhatsApp
/// Grouped by date with color-coded icons
class CallHistoryScreen extends GetView<CallHistoryController> {
  const CallHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        toolbarHeight: 70,
        elevation: 0,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(height: 8),
            Text(
              'Calls',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'Voice and video calls with end-to-end encryption when both contacts have verified keys.',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 10,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          // Clear all
          IconButton(
            icon: const Icon(
              Icons.delete_outline,
              color: AppColors.textPrimary,
            ),
            onPressed: controller.clearAll,
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          _buildSearchBar(),

          // Call history list
          Expanded(
            child: Obx(() {
              if (controller.filteredEntries.isEmpty) {
                return _buildEmptyState();
              }

              return _buildGroupedList();
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.all(AppSizes.paddingM),
      color: AppColors.primary,
      child: TextField(
        controller: controller.searchController,
        decoration: InputDecoration(
          hintText: 'Search calls...',
          prefixIcon: const Icon(Icons.search, color: AppColors.textPrimary),
          filled: true,
          fillColor: AppColors.background,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppSizes.radiusM),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.phone_missed_outlined,
            size: 64,
            color: AppColors.textPrimary.withOpacity(0.3),
          ),
          const SizedBox(height: 16),
          Text(
            'No call history yet',
            style: TextStyle(
              fontSize: 18,
              color: AppColors.textPrimary.withOpacity(0.5),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Your calls will appear here',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textPrimary.withOpacity(0.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupedList() {
    final grouped = controller.groupedEntries;
    final keys = grouped.keys.toList();

    return ListView.builder(
      itemCount: keys.length,
      itemBuilder: (context, index) {
        final dateKey = keys[index];
        final entries = grouped[dateKey]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Date header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                dateKey,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
            ),

            // Entries for this date
            ...entries.map((entry) => _buildCallItem(entry)),
          ],
        );
      },
    );
  }

  Widget _buildCallItem(CallHistoryEntry entry) {
    final contact = controller.getContactInfo(entry.remoteDeviceId);
    final displayName = contact?.userName.isNotEmpty == true
        ? contact!.userName
        : StringUtils.generateFriendlyName(entry.remoteDeviceId);
    final avatarUrl = "";

    final isMissed = entry.status == CallStatus.missed ||
        entry.status == CallStatus.declined;
    final isIncoming = entry.direction == CallDirection.incoming;
    final isVideo = entry.callType == 'video';

    // Icon and color based on direction/status
    IconData directionIcon;
    Color iconColor;
    String statusText;

    if (isMissed) {
      directionIcon = isVideo
          ? Icons.videocam_off
          : isIncoming
              ? Icons.call_missed
              : Icons.call_missed_outgoing;
      iconColor = Colors.red;
      statusText = isIncoming ? 'Missed' : 'Cancelled';
    } else if (entry.status == CallStatus.completed) {
      directionIcon = isVideo
          ? Icons.videocam
          : isIncoming
              ? Icons.call_received
              : Icons.call_made;
      iconColor = isIncoming ? Colors.green : Colors.blue;
      statusText = entry.formattedDuration.isNotEmpty
          ? entry.formattedDuration
          : 'Connected';
    } else {
      directionIcon = isVideo
          ? Icons.videocam_off
          : isIncoming
              ? Icons.call_received
              : Icons.call_made;
      iconColor = Colors.grey;
      statusText = 'Failed';
    }

    return SizedBox(
      height: 65,
      width: double.infinity,
      child: Column(
        children: [
          SizedBox(
            height: 64,
            child: Dismissible(
              key: Key(entry.id),
              direction: DismissDirection.endToStart,
              background: Container(
                color: AppColors.error,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 16),
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              onDismissed: (_) => controller.deleteEntry(entry.id),
              child: InkWell(
                onTap: () => _initiateCall(entry.remoteDeviceId, displayName),
                child: Container(
                  height: AppSizes.chatItemHeight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSizes.paddingM,
                    vertical: AppSizes.paddingS,
                  ),
                  child: Row(
                    children: [
                      _buildAvatar(displayName, avatarUrl, isMissed),
                      const SizedBox(width: AppSizes.paddingM),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    displayName,
                                    style: const TextStyle(
                                      fontSize: AppSizes.fontL,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.textPrimary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  _formatTime(entry.timestamp),
                                  style: const TextStyle(
                                    fontSize: AppSizes.fontS,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(directionIcon, size: 14, color: iconColor),
                                const SizedBox(width: 4),
                                Text(
                                  statusText,
                                  style: TextStyle(
                                    color: isMissed
                                        ? AppColors.error
                                        : AppColors.textPrimary
                                            .withOpacity(0.7),
                                    fontSize: AppSizes.fontM,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.phone,
                            color: AppColors.messageText),
                        onPressed: () =>
                            _initiateCall(entry.remoteDeviceId, displayName),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Divider(
            height: 1,
            indent: AppSizes.paddingM + AppSizes.avatarSize + AppSizes.paddingM,
            color: AppColors.divider,
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(String name, String? avatarUrl, bool isMissed) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return Stack(
      children: [
        Container(
          width: AppSizes.avatarSize,
          height: AppSizes.avatarSize,
          decoration: BoxDecoration(
            color: isMissed
                ? AppColors.error.withOpacity(0.1)
                : AppColors.senderBubble,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              initial,
              style: TextStyle(
                fontSize: AppSizes.fontXL,
                fontWeight: FontWeight.bold,
                color: isMissed ? AppColors.error : AppColors.textPrimary,
              ),
            ),
          ),
        ),
        if (isMissed)
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              width: 14,
              height: 14,
              decoration: const BoxDecoration(
                color: AppColors.error,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 10, color: Colors.white),
            ),
          ),
      ],
    );
  }

  String _formatTime(DateTime timestamp) {
    final hour = timestamp.hour;
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    return '$displayHour:$minute $period';
  }

  void _initiateCall(String deviceId, String name) async {
    if (deviceId.isEmpty) return;
    try {
      final callController = Get.find<CallController>();
      // Actually start the WebRTC call session first (this is what
      // OutgoingCallScreen reads its state from) — the outgoing call
      // screen does not read Get.arguments, so navigating without
      // starting the call first left it stuck/non-functional.
      final success = await callController.startCall(deviceId);
      if (success) {
        Get.toNamed('/call/outgoing');
      }
    } catch (e) {
      debugPrint('❌ Failed to start call from history: $e');
      Get.snackbar(
        'Error',
        'Could not start call',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }
}
