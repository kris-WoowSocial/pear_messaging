import 'package:flutter/foundation.dart';

/// Timing/stage diagnostics for the call pipeline (⏱️/⚡/🎛️ markers).
/// Compiled to a no-op in release builds so production logs stay quiet.
void callDiag(String message) {
  if (kDebugMode) debugPrint(message);
}
