class CallKitGhostEvents {
  final Set<String> _uuids = {};

  void arm(String uuid) => _uuids.add(uuid.toLowerCase());

  bool suppress(String? uuid) =>
      uuid != null && _uuids.contains(uuid.toLowerCase());
}
