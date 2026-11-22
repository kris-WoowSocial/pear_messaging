/// Parses an invite that a user pasted manually into the app.
///
/// Accepted shapes:
///  - `https://vant.chat/chat?device_id=X&user_name=Y[&avatar_url=Z]`
///    (share link / profile QR payload)
///  - `https://vant.chat/referral?code=C&device_id=X` (influencer link)
///  - `vantchat://chat?device_id=X&user_name=Y` (custom-scheme fallback)
///  - any URL carrying a `device_id` or `chat_device_id` query param
///
/// Retired `*.app.link` URLs (the old Branch domain) carry no readable
/// device id — they're flagged [ParsedInvite.isLegacyLink] so the caller can
/// show an "expired" message instead of silently failing.
library;

class ParsedInvite {
  const ParsedInvite.deviceId(
    this.deviceId, {
    this.userName,
    this.avatarUrl,
    this.referralCode,
  }) : isLegacyLink = false;
  const ParsedInvite.legacyLink(this.deviceId)
      : userName = null,
        avatarUrl = null,
        referralCode = null,
        isLegacyLink = true;

  /// For [isLegacyLink] this holds the pasted URL instead of a device id.
  final String? deviceId;
  final String? userName;
  final String? avatarUrl;
  final String? referralCode;
  final bool isLegacyLink;
}

/// Returns null for input that cannot be an invite (empty, non-URL, no
/// device_id and not a recognised legacy domain).
ParsedInvite? parseInviteLink(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;

  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme.isEmpty) return null;

  final deviceId = uri.queryParameters['device_id']?.trim() ??
      uri.queryParameters['chat_device_id']?.trim();
  if (deviceId != null && deviceId.isNotEmpty) {
    String? clean(String? v) => (v == null || v.trim().isEmpty) ? null : v.trim();
    return ParsedInvite.deviceId(
      deviceId,
      userName: clean(uri.queryParameters['user_name']),
      avatarUrl: clean(uri.queryParameters['avatar_url']),
      referralCode: clean(uri.queryParameters['referral_code'] ??
          uri.queryParameters['code']),
    );
  }

  final host = uri.host.toLowerCase();
  final isLegacyDomain =
      host == 'vantchatting.app.link' ||
      host == 'vantchatting-alternate.app.link' ||
      host.endsWith('.app.link');
  if (isLegacyDomain && (uri.scheme == 'https' || uri.scheme == 'http')) {
    return ParsedInvite.legacyLink(text);
  }

  return null;
}
