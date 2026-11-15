/// Parses an invite that a user pasted manually into the app.
///
/// Three accepted shapes:
///  - `vantchat://chat?device_id=X&user_name=Y` (custom-scheme share link)
///  - `https://vant.chat/chat?device_id=X` or any URL carrying a device_id
///    query param (QR payload link)
///  - a Branch short link (`*.app.link/…`) that carries no visible device_id —
///  marked [isBranchLink] so the caller can hand it to
///  `FlutterBranchSdk.handleDeepLink`, which routes through the normal
///  Branch listener and produces the same connection-request flow.
library;

class ParsedInvite {
  const ParsedInvite.deviceId(this.deviceId, {this.userName, this.avatarUrl})
      : isBranchLink = false;
  const ParsedInvite.branchLink(this.deviceId)
      : userName = null,
        avatarUrl = null,
        isBranchLink = true;

  /// For [isBranchLink] this holds the pasted URL instead of a device id.
  final String? deviceId;
  final String? userName;
  final String? avatarUrl;
  final bool isBranchLink;

  String? get branchUrl => isBranchLink ? deviceId : null;
}

/// Returns null for input that cannot be an invite (empty, non-URL, no
/// device_id and not a recognised Branch domain).
ParsedInvite? parseInviteLink(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;

  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme.isEmpty) return null;

  final deviceId = uri.queryParameters['device_id']?.trim() ??
      uri.queryParameters['chat_device_id']?.trim();
  if (deviceId != null && deviceId.isNotEmpty) {
    final userName = uri.queryParameters['user_name']?.trim();
    final avatarUrl = uri.queryParameters['avatar_url']?.trim();
    return ParsedInvite.deviceId(
      deviceId,
      userName: (userName == null || userName.isEmpty) ? null : userName,
      avatarUrl: (avatarUrl == null || avatarUrl.isEmpty) ? null : avatarUrl,
    );
  }

  final host = uri.host.toLowerCase();
  final isBranchDomain =
      host == 'vantchatting.app.link' ||
      host == 'vantchatting-alternate.app.link' ||
      host.endsWith('.app.link');
  if (isBranchDomain && (uri.scheme == 'https' || uri.scheme == 'http')) {
    return ParsedInvite.branchLink(text);
  }

  return null;
}
