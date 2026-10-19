/// Pure decision logic for the full-screen-intent (FSI) permission prompt.
/// Extracted from CallController so the policy is unit-testable without
/// platform channels or SharedPreferences.
enum FsiPromptDecision {
  /// Permission already granted — nothing to do.
  granted,

  /// Permission denied — show the settings dialog now.
  showDialog,

  /// Permission denied but the user explicitly chose "Don't ask again".
  skipDontAskAgain,
}

/// [missedCallPromptPending] is set (one-shot) by native code when a call is
/// missed — the clearest sign the suppressed full-screen UI cost the user a
/// call. It re-arms the dialog once even after "Don't ask again", because the
/// user just experienced the consequence; they can opt out again.
FsiPromptDecision decideFsiPrompt({
  required bool canUseFullScreenIntent,
  required bool dontAskAgain,
  bool missedCallPromptPending = false,
}) {
  if (canUseFullScreenIntent) return FsiPromptDecision.granted;
  if (missedCallPromptPending) return FsiPromptDecision.showDialog;
  if (dontAskAgain) return FsiPromptDecision.skipDontAskAgain;
  return FsiPromptDecision.showDialog;
}
