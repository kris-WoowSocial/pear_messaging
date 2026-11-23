import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/services/api_service.dart';
import '../../core/services/invite_link_parser.dart';
import '../../core/services/invitation_storage_service.dart';
import '../../features/chat_list/chat_list_controller.dart';
import '../../routes/app_routes.dart';

/// iOS first-launch invite recovery.
///
/// iOS has no first-party deferred deep-link mechanism: when a fresh install
/// doesn't arrive via a universal link, no invite shows up automatically.
/// This sheet offers the two remaining paths into the same connection
/// request flow the deep-link service uses:
///  1. scan the friend's in-app QR code → [initializeChatFromQR]
///  2. paste the invite link into a normal text field (a user-initiated
///     paste does NOT trigger the iOS pasteboard permission prompt) →
///     `vant.chat` / `vantchat://` links go to [initializeChatFromQR];
///     retired `*.app.link` URLs show an "expired" message.
///
/// Fully dismissible — nothing about the flow blocks on it.
class InviteFallbackSheet {
  InviteFallbackSheet._();

  /// "Have an invite?" recovery sheet. Call after the name step or from the
  /// empty chat list (iOS only — callers gate on Platform.isIOS).
  static Future<void> show() {
    final linkController = TextEditingController();
    String? errorText;
    var submitting = false;

    return Get.bottomSheet<void>(
      StatefulBuilder(
        builder: (context, setState) {
          Future<void> submit() async {
            final parsed = parseInviteLink(linkController.text);
            if (parsed == null) {
              setState(() => errorText =
                  'That does not look like a Vant Chat invite link');
              return;
            }
            if (parsed.isLegacyLink) {
              setState(() => errorText =
                  'This legacy invite link has expired. Ask your contact for a new Vant Chat link.');
              return;
            }
            setState(() {
              errorText = null;
              submitting = true;
            });
            try {
              // Opaque /chat/<code> short link — params live server-side.
              String? deviceId = parsed.deviceId;
              String? userName = parsed.userName;
              String? avatarUrl = parsed.avatarUrl;
              String? referralCode = parsed.referralCode;
              if (parsed.shortCode != null) {
                final payload = await ApiService.to
                    .resolveShortInviteLink(parsed.shortCode!);
                if (payload == null ||
                    (payload['device_id'] as String?) == null) {
                  setState(() {
                    submitting = false;
                    errorText =
                        'That invite link could not be resolved. Ask your contact for a new link.';
                  });
                  return;
                }
                deviceId = payload['device_id'] as String;
                userName = payload['user_name'] as String?;
                avatarUrl = payload['avatar_url'] as String?;
                referralCode = payload['referral_code'] as String?;
              }
              if (referralCode != null &&
                  Get.isRegistered<InvitationStorageService>()) {
                await Get.find<InvitationStorageService>()
                    .storeReferralContext(
                  inviterDeviceId: deviceId!,
                  influencerCode: referralCode,
                );
              }
              Get.back();
              await Get.find<ChatListController>().initializeChatFromQR(
                deviceId!,
                userName: userName,
                avatarUrl: avatarUrl,
              );
            } catch (e) {
              setState(() {
                submitting = false;
                errorText = 'Could not use that link. Please try again.';
              });
            }
          }

          return SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 12,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Have an invite?',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "We couldn't find your friend's invite automatically. You can still connect — pick one:",
                    style: TextStyle(fontSize: 15, color: Colors.black54),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text("Scan your friend's QR code"),
                      onPressed: () {
                        Get.back();
                        Get.toNamed(AppRoutes.qrScanner);
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Row(
                    children: [
                      Expanded(child: Divider()),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text('or', style: TextStyle(color: Colors.grey)),
                      ),
                      Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: linkController,
                    enabled: !submitting,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: 'Invite link',
                      hintText: 'Paste the link your friend sent you',
                      errorText: errorText,
                      prefixIcon: const Icon(Icons.link),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onSubmitted: submitting ? null : (_) => submit(),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: submitting ? null : submit,
                      child: const Text('Connect'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ).whenComplete(linkController.dispose);
  }
}
