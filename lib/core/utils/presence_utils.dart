class PresenceUtils {
  /// Convert online status and last seen timestamp to user-friendly text
  static String getPresenceText(bool isOnline, DateTime? lastSeen) {
    if (isOnline) {
      return 'online';
    }
    
    if (lastSeen == null) {
      return 'last seen some time ago';
    }
    
    final now = DateTime.now();
    final difference = now.difference(lastSeen);
    
    // If last seen today (within 24 hours)
    if (difference.inHours < 24) {
      return 'last seen today';
    }
    
    // If more than a day ago
    return 'last seen some time ago';
  }
  
  /// Get color for presence text
  static bool shouldShowGreen(bool isOnline, DateTime? lastSeen) {
    if (isOnline) return true;
    
    if (lastSeen == null) return false;
    
    final now = DateTime.now();
    final difference = now.difference(lastSeen);
    
    // Show green if seen within last 24 hours
    return difference.inHours < 24;
  }
}
