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

FsiPromptDecision decideFsiPrompt({
  required bool canUseFullScreenIntent,
  required bool dontAskAgain,
}) {
  if (canUseFullScreenIntent) return FsiPromptDecision.granted;
  if (dontAskAgain) return FsiPromptDecision.skipDontAskAgain;
  return FsiPromptDecision.showDialog;
}
