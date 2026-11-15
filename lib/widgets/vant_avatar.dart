import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../core/constants/app_colors.dart';
import '../core/services/user_profile_cache.dart';

/// The single avatar widget used across the whole app.
///
/// Resolution order (reactive):
///   1. [UserProfileCache.avatarByDeviceId] — live socket/sync updates.
///   2. [avatarUrl] — the URL passed by the row/screen (e.g. ChatEntity).
///   3. Styled initial letter derived from [name].
///
/// Pass [userId] whenever the avatar represents a registered user so live
/// updates apply; omit it only for purely static decorations.
class VantAvatar extends StatelessWidget {
  final String? userId;
  final String name;
  final String? avatarUrl;
  final double size;
  final bool isGroup;
  final bool showEditBadge;
  final VoidCallback? onTap;
  final double borderRadius;

  const VantAvatar({
    super.key,
    this.userId,
    required this.name,
    this.avatarUrl,
    this.size = 40,
    this.isGroup = false,
    this.showEditBadge = false,
    this.onTap,
    this.borderRadius = 12,
  });

  String get _initial {
    if (name.trim().isNotEmpty) return name.trim()[0].toUpperCase();
    return 'U';
  }

  @override
  Widget build(BuildContext context) {
    Widget avatar = _buildReactive();

    if (showEditBadge) {
      avatar = Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: size * 0.45,
              height: size * 0.45,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.green, width: 1.6),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              child: Icon(
                Icons.edit,
                size: size * 0.26,
                color: Colors.green.shade700,
              ),
            ),
          ),
        ],
      );
    }

    if (onTap != null) {
      avatar = GestureDetector(onTap: onTap, child: avatar);
    }
    return avatar;
  }

  Widget _buildReactive() {
    // When a userId is available, subscribe to the profile cache so socket
    // profile_updated events re-render this widget instantly.
    if (userId != null && Get.isRegistered<UserProfileCache>()) {
      final cache = Get.find<UserProfileCache>();
      return Obx(() {
        final live = cache.avatarByDeviceId[userId];
        final url = (live != null && live.isNotEmpty) ? live : (avatarUrl ?? '');
        // Local-file hit: render synchronously from disk — no network, no
        // placeholder flash, works offline. Subscribing to the map means a
        // just-finished download swaps the image in automatically.
        final localPath = cache.localAvatarFileByDeviceId[userId];
        if (localPath != null && File(localPath).existsSync()) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(borderRadius),
                image: DecorationImage(
                  image: FileImage(File(localPath)),
                  fit: BoxFit.cover,
                ),
              ),
            ),
          );
        }
        if (url.isNotEmpty) {
          // Not on disk yet — kick off the one-time download (no-ops if a
          // file for this URL is already cached) while the network image
          // bridges this single first-render gap.
          unawaited(cache.ensureCachedLocally(userId!, url));
        } else if (localPath != null) {
          // Map holds a stale path whose file is gone and the URL is empty —
          // drop the persisted leftovers.
          unawaited(cache.ensureCachedLocally(userId!, ''));
        }
        return _buildAvatar(url);
      });
    }
    return _buildAvatar(avatarUrl ?? '');
  }

  Widget _buildAvatar(String url) {
    final radius = BorderRadius.circular(borderRadius);
    if (url.isEmpty) return _fallback(radius);

    return ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        fadeInDuration: Duration.zero,
        placeholder: (_, __) => _fallback(radius, clip: false),
        errorWidget: (_, __, ___) => _fallback(radius, clip: false),
      ),
    );
  }

  Widget _fallback(BorderRadius radius, {bool clip = true}) {
    final box = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.senderBubble,
        borderRadius: radius,
      ),
      child: Center(
        child: isGroup
            ? Icon(Icons.group, color: AppColors.textPrimary, size: size * 0.5)
            : Text(
                _initial,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: size * 0.45,
                  fontWeight: FontWeight.bold,
                ),
              ),
      ),
    );
    return clip ? ClipRRect(borderRadius: radius, child: box) : box;
  }
}
