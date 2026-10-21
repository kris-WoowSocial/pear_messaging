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

  /// Permission denied and the install prompt was already shown once —
  /// stay silent until a missed call re-arms it.
  skipAlreadyShown,
}

/// [missedCallPromptPending] is set (one-shot) by native code when a call is
/// missed — the clearest sign the suppressed full-screen UI cost the user a
/// call. It re-arms the dialog once even after "Don't ask again", because the
/// user just experienced the consequence; they can opt out again.
/// [installPromptShown] is persisted once the dialog has been displayed —
/// the prompt is one-shot per install so it can't nag on every app start.
/// A pending missed-call prompt still re-arms it.
FsiPromptDecision decideFsiPrompt({
  required bool canUseFullScreenIntent,
  required bool dontAskAgain,
  bool missedCallPromptPending = false,
  bool installPromptShown = false,
}) {
  if (canUseFullScreenIntent) return FsiPromptDecision.granted;
  if (missedCallPromptPending) return FsiPromptDecision.showDialog;
  if (dontAskAgain) return FsiPromptDecision.skipDontAskAgain;
  if (installPromptShown) return FsiPromptDecision.skipAlreadyShown;
  return FsiPromptDecision.showDialog;
}
