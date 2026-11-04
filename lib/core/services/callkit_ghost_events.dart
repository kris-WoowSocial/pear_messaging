class CallKitGhostEvents {
  final Set<String> _uuids = {};

  void arm(String uuid) => _uuids.add(uuid.toLowerCase());

  void disarm(String uuid) => _uuids.remove(uuid.toLowerCase());

  bool suppress(String? uuid) =>
      uuid != null && _uuids.contains(uuid.toLowerCase());
}
