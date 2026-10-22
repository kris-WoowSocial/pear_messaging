import 'dart:io' show Platform;

import 'package:firebase_crashlytics/firebase_crashlytics.dart';

/// Lightweight Crashlytics breadcrumbs for the iOS call path.
///
/// No-ops on Android (the Android call path is covered by verbose debug
/// logging / callDiag). Never throws — a missing Crashlytics plugin must
/// not affect call behavior. Accepts only a fixed set of [CallBreadcrumb]
/// values so no personal data (names, ids, SDP, tokens) can be logged.
enum CallBreadcrumb {
  pushkitReceived('call.pushkit_received'),
  callkitReportDone('call.callkit_report_done'),
  accept('call.accept'),
  decline('call.decline'),
  resyncRequest('call.resync_request'),
  resyncAnswer('call.resync_answer'),
  ended('call.ended');

  const CallBreadcrumb(this.key);
  final String key;
}

void logCallBreadcrumb(CallBreadcrumb event, {String reason = ''}) {
  if (!Platform.isIOS) return;
  // reason is a fixed protocol enum (ended/declined/timeout/cancelled/
  // rejected/peer_update_required/encryption_required) — never personal data.
  final safeReason = reason.replaceAll(RegExp(r'[^a-z_]'), '');
  try {
    FirebaseCrashlytics.instance.log(
      safeReason.isEmpty ? event.key : '${event.key}:$safeReason',
    );
  } catch (_) {}
}
