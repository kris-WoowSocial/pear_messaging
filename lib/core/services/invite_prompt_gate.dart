import 'dart:async';

/// Sequencing gate for the iOS first-launch invite flow.
///
/// On a fresh iOS install, the notification permission prompt must not fire
/// while the name sheet or the invite fallback sheet is up. The splash
/// controller drives the order:
///
///  1. name sheet completes
///  2. the invite is resolved (match → connection request, no match →
///     "Have an invite?" sheet)
///  3. [inviteStepDone] — releases the deferred notification permission
///     request so it never overlaps the invite UI.
///
/// Every path that doesn't need gating completes the future immediately,
/// so Android and non-first-launch iOS are unaffected.
class InvitePromptGate {
  InvitePromptGate._();

  static final Completer<void> _inviteDone = Completer<void>();

  /// Waits for the whole invite step (match or fallback shown/dismissed).
  /// FCMService awaits this on iOS before requesting notification permission.
  static Future<void> get inviteDone => _inviteDone.future;

  static bool get isInviteStepDone => _inviteDone.isCompleted;

  static void inviteStepDone() {
    if (!_inviteDone.isCompleted) _inviteDone.complete();
  }
}
