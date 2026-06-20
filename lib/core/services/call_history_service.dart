import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../storage/models/call_history_entry.dart';

/// Call History Service - Manages local call log storage using Hive
/// Client-side only - no server storage for privacy
class CallHistoryService extends GetxService {
  static const String _callHistoryBoxName = 'call_history';
  late Box _callHistoryBox;
  bool _initialized = false;

  /// Reactive list for UI updates
  final RxList<CallHistoryEntry> entries = <CallHistoryEntry>[].obs;

  /// Initialize the service
  Future<CallHistoryService> init() async {
    if (_initialized) return this;

    try {
      _callHistoryBox = await Hive.openBox(_callHistoryBoxName);
      _initialized = true;
      _loadEntries();
      debugPrint('📞 CallHistoryService initialized with ${_callHistoryBox.length} entries');
    } catch (e) {
      debugPrint('❌ Error initializing CallHistoryService: $e');
    }

    return this;
  }

  /// Load all entries from storage into reactive list
  void _loadEntries() {
    try {
      final List<CallHistoryEntry> loaded = [];

      for (final value in _callHistoryBox.values) {
        try {
          if (value is Map) {
            final jsonMap = Map<String, dynamic>.from(value);
            loaded.add(CallHistoryEntry.fromJson(jsonMap));
          } else if (value is CallHistoryEntry) {
            loaded.add(value);
          }
        } catch (e) {
          debugPrint('⚠️ Error parsing call history entry: $e');
        }
      }

      // Sort by timestamp desc (newest first)
      loaded.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      entries.value = loaded;
      debugPrint('📞 Loaded ${entries.length} call history entries');
    } catch (e) {
      debugPrint('❌ Error loading call history: $e');
    }
  }

  /// Add a new call history entry
  Future<void> addEntry(CallHistoryEntry entry) async {
    try {
      final jsonData = entry.toJson();
      await _callHistoryBox.put(entry.id, jsonData);

      // Add to reactive list at beginning (newest first)
      entries.insert(0, entry);

      debugPrint('📞 Call history entry added: ${entry.id} - ${entry.status}');
    } catch (e) {
      debugPrint('❌ Error adding call history entry: $e');
    }
  }

  /// Get all entries sorted by timestamp desc
  List<CallHistoryEntry> getAllEntries() {
    return List<CallHistoryEntry>.from(entries);
  }

  /// Get entries for a specific contact
  List<CallHistoryEntry> getEntriesForContact(String deviceId) {
    return entries.where((e) => e.remoteDeviceId == deviceId).toList();
  }

  /// Delete a specific entry
  Future<void> deleteEntry(String id) async {
    try {
      await _callHistoryBox.delete(id);
      entries.removeWhere((e) => e.id == id);
      debugPrint('📞 Deleted call history entry: $id');
    } catch (e) {
      debugPrint('❌ Error deleting call history entry: $e');
    }
  }

  /// Delete all entries for a contact
  Future<void> deleteEntriesForContact(String deviceId) async {
    try {
      final entriesToDelete = entries.where((e) => e.remoteDeviceId == deviceId).toList();
      final keysToDelete = entriesToDelete.map((e) => e.id).toList();

      await _callHistoryBox.deleteAll(keysToDelete);
      entries.removeWhere((e) => e.remoteDeviceId == deviceId);

      debugPrint('📞 Deleted ${entriesToDelete.length} entries for $deviceId');
    } catch (e) {
      debugPrint('❌ Error deleting contact call history: $e');
    }
  }

  /// Clear all call history
  Future<void> clearAll() async {
    try {
      await _callHistoryBox.clear();
      entries.clear();
      debugPrint('📞 All call history cleared');
    } catch (e) {
      debugPrint('❌ Error clearing call history: $e');
    }
  }

  /// Count missed calls (for badge)
  int getMissedCallCount() {
    return entries.where((e) => e.isMissed).length;
  }

  /// Count missed calls for a specific contact
  int getMissedCallCountForContact(String deviceId) {
    return entries.where((e) => e.remoteDeviceId == deviceId && e.isMissed).length;
  }

  /// Refresh entries from storage (call after app resumes from background)
  void refresh() {
    _loadEntries();
  }

  /// Update an existing entry (e.g., after call ends to add duration)
  Future<void> updateEntry(CallHistoryEntry updatedEntry) async {
    try {
      final index = entries.indexWhere((e) => e.id == updatedEntry.id);
      if (index != -1) {
        final jsonData = updatedEntry.toJson();
        await _callHistoryBox.put(updatedEntry.id, jsonData);
        entries[index] = updatedEntry;
        debugPrint('📞 Updated call history entry: ${updatedEntry.id}');
      }
    } catch (e) {
      debugPrint('❌ Error updating call history entry: $e');
    }
  }

  /// Get the most recent call with a specific contact
  CallHistoryEntry? getLastCallWithContact(String deviceId) {
    final contactEntries = entries.where((e) => e.remoteDeviceId == deviceId).toList();
    if (contactEntries.isEmpty) return null;
    return contactEntries.first; // Already sorted by timestamp desc
  }
}
