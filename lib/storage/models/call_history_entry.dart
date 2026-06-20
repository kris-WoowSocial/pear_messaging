/// Call History Entry - Stores call log locally (client-side only, no server storage)
/// Mirrors WhatsApp call log: incoming/outgoing/missed with duration
class CallHistoryEntry {
  final String id; // callId
  final String remoteDeviceId; // Other party's device ID
  final String remoteName; // Denormalized at write time
  final String? remoteAvatarUrl; // Denormalized at write time
  final CallDirection direction; // incoming | outgoing
  final CallStatus status; // completed | missed | declined | cancelled | failed
  final DateTime timestamp; // When call was initiated/received
  final int durationSeconds; // 0 if not connected
  final String? callType; // 'audio' (future: 'video')

  CallHistoryEntry({
    required this.id,
    required this.remoteDeviceId,
    required this.remoteName,
    this.remoteAvatarUrl,
    required this.direction,
    required this.status,
    required this.timestamp,
    this.durationSeconds = 0,
    this.callType = 'audio',
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'remoteDeviceId': remoteDeviceId,
      'remoteName': remoteName,
      'remoteAvatarUrl': remoteAvatarUrl,
      'direction': direction.toString().split('.').last,
      'status': status.toString().split('.').last,
      'timestamp': timestamp.toIso8601String(),
      'durationSeconds': durationSeconds,
      'callType': callType,
    };
  }

  factory CallHistoryEntry.fromJson(Map<String, dynamic> json) {
    return CallHistoryEntry(
      id: json['id'] as String,
      remoteDeviceId: json['remoteDeviceId'] as String,
      remoteName: json['remoteName'] as String,
      remoteAvatarUrl: json['remoteAvatarUrl'] as String?,
      direction: CallDirection.values.firstWhere(
        (e) => e.toString().split('.').last == json['direction'],
        orElse: () => CallDirection.incoming,
      ),
      status: CallStatus.values.firstWhere(
        (e) => e.toString().split('.').last == json['status'],
        orElse: () => CallStatus.failed,
      ),
      timestamp: DateTime.parse(json['timestamp'] as String),
      durationSeconds: json['durationSeconds'] as int? ?? 0,
      callType: json['callType'] as String? ?? 'audio',
    );
  }

  /// Create a copy with updated fields
  CallHistoryEntry copyWith({
    String? id,
    String? remoteDeviceId,
    String? remoteName,
    String? remoteAvatarUrl,
    CallDirection? direction,
    CallStatus? status,
    DateTime? timestamp,
    int? durationSeconds,
    String? callType,
  }) {
    return CallHistoryEntry(
      id: id ?? this.id,
      remoteDeviceId: remoteDeviceId ?? this.remoteDeviceId,
      remoteName: remoteName ?? this.remoteName,
      remoteAvatarUrl: remoteAvatarUrl ?? this.remoteAvatarUrl,
      direction: direction ?? this.direction,
      status: status ?? this.status,
      timestamp: timestamp ?? this.timestamp,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      callType: callType ?? this.callType,
    );
  }

  /// Format duration as mm:ss
  String get formattedDuration {
    if (durationSeconds <= 0) return '';
    final minutes = durationSeconds ~/ 60;
    final seconds = durationSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Check if this is a missed call (for badge counting)
  bool get isMissed => status == CallStatus.missed || status == CallStatus.declined;

  /// Check if call was connected
  bool get wasConnected => durationSeconds > 0 || status == CallStatus.completed;
}

/// Call direction: who initiated the call
enum CallDirection {
  incoming, // Other party called me
  outgoing, // I called other party
}

/// Call status: outcome of the call
enum CallStatus {
  completed, // Call connected and ended normally
  missed, // Incoming, never answered (no_answer timeout)
  declined, // Incoming, explicitly rejected
  cancelled, // Outgoing, caller hung up before answer
  failed, // Error/technical failure
}
