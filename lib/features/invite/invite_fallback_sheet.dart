import 'package:flutter/material.dart';
import 'package:flutter_branch_sdk/flutter_branch_sdk.dart';
import 'package:get/get.dart';

import '../../core/services/invite_link_parser.dart';
import '../../features/chat_list/chat_list_controller.dart';
import '../../routes/app_routes.dart';

/// iOS first-launch invite recovery.
///
/// When the Branch install match fails (paste prompt denied, "Get the App
/// without Copying", or a fingerprint miss) no invite arrives automatically.
/// This sheet offers the two remaining paths into the same connection
/// request flow the Branch path uses:
///  1. scan the friend's in-app QR code → [initializeChatFromQR]
///  2. paste the invite link into a normal text field (a user-initiated
///     paste does NOT trigger the iOS pasteboard permission prompt) →
///     device_id links go to [initializeChatFromQR]; Branch short links go
///     through [FlutterBranchSdk.handleDeepLink] → the Branch listener.
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
            setState(() {
              errorText = null;
              submitting = true;
            });
            try {
              if (parsed.isBranchLink) {
                // Hand the short link back to the Branch SDK — it resolves
                // the link data and delivers it to the Branch listener,
                // which runs the normal invite/connection-request flow.
                FlutterBranchSdk.handleDeepLink(parsed.branchUrl!);
                Get.back();
                Get.snackbar(
                  'Connecting',
                  'Checking your invite…',
                  snackPosition: SnackPosition.BOTTOM,
                  duration: const Duration(seconds: 3),
                );
              } else {
                Get.back();
                await Get.find<ChatListController>().initializeChatFromQR(
                  parsed.deviceId!,
                  userName: parsed.userName,
                );
              }
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

  /// Pre-explanation shown BEFORE the Branch SDK reads the pasteboard, so the
  /// iOS system paste prompt is not a surprise. [onContinue] releases the
  /// deferred Branch init. Dismissible only via the button — the whole point
  /// is that the user sees it.
  static Future<void> showPasteExplainer() {
    return Get.bottomSheet<void>(
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              const Icon(Icons.content_paste, size: 40, color: Colors.black54),
              const SizedBox(height: 16),
              const Text(
                'Connect with your friend',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              const Text(
                "If you installed Vant Chat from a friend's link or QR code, "
                'iOS will ask to paste it. Tap "Allow Paste" so we can '
                'connect you automatically.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: Colors.black54),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: Get.back,
                  child: const Text('Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    );
  }
}
