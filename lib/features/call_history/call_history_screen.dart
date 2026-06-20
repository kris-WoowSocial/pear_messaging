import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_sizes.dart';
import '../../core/utils/string_utils.dart';
import '../../storage/models/call_history_entry.dart';
import 'call_history_controller.dart';

/// Call History Screen - Shows all call logs like WhatsApp
/// Grouped by date with color-coded icons
class CallHistoryScreen extends GetView<CallHistoryController> {
  const CallHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text(
          'Calls',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          // Search icon
          IconButton(
            icon: const Icon(Icons.search, color: AppColors.textPrimary),
            onPressed: () {
              // TODO: Show search field
            },
          ),
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
      color: AppColors.surface,
      child: TextField(
        controller: controller.searchController,
        decoration: InputDecoration(
          hintText: 'Search calls...',
          prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
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
          Icon(Icons.phone_missed_outlined, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            'No call history yet',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Your calls will appear here',
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
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
                  color: AppColors.primary,
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

    // Icon and color based on direction/status
    IconData directionIcon;
    Color iconColor;
    String statusText;

    if (isMissed) {
      directionIcon =
          isIncoming ? Icons.call_missed : Icons.call_missed_outgoing;
      iconColor = Colors.red;
      statusText = isIncoming ? 'Missed' : 'Cancelled';
    } else if (entry.status == CallStatus.completed) {
      directionIcon = isIncoming ? Icons.call_received : Icons.call_made;
      iconColor = isIncoming ? Colors.green : Colors.blue;
      statusText = entry.formattedDuration.isNotEmpty
          ? entry.formattedDuration
          : 'Connected';
    } else {
      directionIcon = isIncoming ? Icons.call_received : Icons.call_made;
      iconColor = Colors.grey;
      statusText = 'Failed';
    }

    return Dismissible(
      key: Key(entry.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => controller.deleteEntry(entry.id),
      child: ListTile(
        leading: _buildAvatar(displayName, avatarUrl, isMissed),
        title: Text(
          displayName,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
        subtitle: Row(
          children: [
            Icon(directionIcon, size: 14, color: iconColor),
            const SizedBox(width: 4),
            Text(
              statusText,
              style: TextStyle(
                color: isMissed ? Colors.red : Colors.grey[600],
                fontSize: 13,
              ),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Timestamp
            Text(
              _formatTime(entry.timestamp),
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
            const SizedBox(width: 12),
            // Call button
            IconButton(
              icon: const Icon(Icons.phone, color: AppColors.primary),
              onPressed: () => _initiateCall(entry.remoteDeviceId, displayName),
            ),
          ],
        ),
        onTap: () {
          // Simple approach: tap initiates call
          // For WhatsApp-parity with details screen, would show bottom sheet
          _initiateCall(entry.remoteDeviceId, displayName);
        },
      ),
    );
  }

  Widget _buildAvatar(String name, String? avatarUrl, bool isMissed) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return Stack(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: isMissed
                ? Colors.red.withOpacity(0.1)
                : AppColors.primary.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              initial,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: isMissed ? Colors.red : AppColors.primary,
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
                color: Colors.red,
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

  void _initiateCall(String deviceId, String name) {
    // Navigate to outgoing call screen
    Get.toNamed(
      '/call/outgoing',
      arguments: {'recipientDeviceId': deviceId, 'recipientName': name},
    );
  }
}
