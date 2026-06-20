import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/services/call_history_service.dart';
import '../../core/services/local_storage_service.dart';
import '../../storage/models/call_history_entry.dart';
import '../../storage/models/chat_entity.dart';

/// Controller for Call History screen
class CallHistoryController extends GetxController {
  final CallHistoryService _callHistoryService = Get.find();
  final LocalStorageService _storageService = Get.find();

  /// Reactive filtered entries
  final RxList<CallHistoryEntry> filteredEntries = <CallHistoryEntry>[].obs;

  /// Search query
  final TextEditingController searchController = TextEditingController();

  @override
  void onInit() {
    super.onInit();
    _loadEntries();

    // Listen to search changes
    searchController.addListener(_onSearchChanged);

    // Listen to history updates
    ever(_callHistoryService.entries, (_) => _loadEntries());
  }

  @override
  void onClose() {
    searchController.removeListener(_onSearchChanged);
    searchController.dispose();
    super.onClose();
  }

  /// Load and group entries
  void _loadEntries() {
    final all = _callHistoryService.getAllEntries();
    filteredEntries.value = all;
  }

  /// Search handler
  void _onSearchChanged() {
    final query = searchController.text.toLowerCase().trim();
    if (query.isEmpty) {
      filteredEntries.value = _callHistoryService.getAllEntries();
      return;
    }

    filteredEntries.value = _callHistoryService.getAllEntries().where((entry) {
      return entry.remoteName.toLowerCase().contains(query) ||
          entry.remoteDeviceId.toLowerCase().contains(query);
    }).toList();
  }

  /// Delete a single entry
  Future<void> deleteEntry(String id) async {
    await _callHistoryService.deleteEntry(id);
    Get.snackbar(
      'Deleted',
      'Call removed from history',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  /// Delete all history
  Future<void> clearAll() async {
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('Clear Call History?'),
        content: const Text('This will delete all call history entries. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _callHistoryService.clearAll();
      Get.snackbar(
        'Cleared',
        'All call history deleted',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    }
  }

  /// Get contact name/avatar from storage (for latest info)
  ChatEntity? getContactInfo(String deviceId) {
    return _storageService.getChat(deviceId);
  }

  /// Group entries by date for list display
  Map<String, List<CallHistoryEntry>> get groupedEntries {
    final Map<String, List<CallHistoryEntry>> groups = {};
    final now = DateTime.now();

    for (final entry in filteredEntries) {
      final date = entry.timestamp;
      String key;

      if (_isSameDay(date, now)) {
        key = 'Today';
      } else if (_isSameDay(date, now.subtract(const Duration(days: 1)))) {
        key = 'Yesterday';
      } else if (now.difference(date).inDays < 7) {
        key = _getWeekdayName(date);
      } else {
        key = '${date.day}/${date.month}/${date.year}';
      }

      groups.putIfAbsent(key, () => []).add(entry);
    }

    return groups;
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _getWeekdayName(DateTime date) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[date.weekday - 1];
  }

  /// Count missed calls for badge
  int get missedCallCount => _callHistoryService.getMissedCallCount();

  /// Refresh from storage
  void refresh() {
    _callHistoryService.refresh();
    _loadEntries();
  }
}
