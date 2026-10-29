import 'dart:async';

/// Sequencing gate for the iOS first-launch invite flow.
///
/// On a fresh iOS install, three system-level events must not fire at once:
/// the Branch pasteboard read ("Vant Chat would like to paste"), the
/// notification permission prompt, and the in-app name sheet. The splash
/// controller drives the order:
///
///  1. name sheet completes
///  2. in-app paste explanation is shown
///  3. [allowPasteCheck] — releases the deferred `FlutterBranchSdk.init`
///     (which is what triggers the system paste prompt)
///  4. the invite is resolved (matched → connection request, unmatched →
///     "Have an invite?" sheet)
///  5. [inviteStepDone] — releases the deferred notification permission
///     request so it never overlaps the paste prompt.
///
/// Every path that doesn't need gating completes both futures immediately,
/// so Android and non-first-launch iOS are unaffected.
class InvitePromptGate {
  InvitePromptGate._();

  static final Completer<void> _pasteCheckReady = Completer<void>();
  static final Completer<void> _inviteDone = Completer<void>();

  /// Waits for the paste-explainer step. BranchService.init awaits this on
  /// iOS before calling FlutterBranchSdk.init.
  static Future<void> get pasteCheckReady => _pasteCheckReady.future;

  /// Waits for the whole invite step (match or fallback shown/dismissed).
  /// FCMService awaits this on iOS before requesting notification permission.
  static Future<void> get inviteDone => _inviteDone.future;

  static bool get pasteCheckAllowed => _pasteCheckReady.isCompleted;
  static bool get isInviteStepDone => _inviteDone.isCompleted;

  static void allowPasteCheck() {
    if (!_pasteCheckReady.isCompleted) _pasteCheckReady.complete();
  }

  static void inviteStepDone() {
    allowPasteCheck();
    if (!_inviteDone.isCompleted) _inviteDone.complete();
  }
}
