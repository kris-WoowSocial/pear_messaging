import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:get/get.dart';

import '../utils/safety_code.dart';
import 'identity_announcement_service.dart';
import 'identity_service.dart';
import 'local_storage_service.dart';
import 'socket_service.dart';

/// Contact verification (Phase 1) — QR + safety-code key verification.
///
/// Model:
///  - The QR screen is the ONLY context where echoes are accepted.
///  - The displayer shows a one-time secret in the QR. The scanner echoes
///    HMAC-SHA256(secret, "vant-verify-echo"|idA|idB|bundleB) back through
///    the server — the server relays but cannot forge it (it never sees s).
///  - Scanner side verifies A's bundle against its pin immediately and does
///    NOT wait for the echo — the QR is the authentic channel.
///  - Displayer confirms WHO scanned before marking the peer verified.
///  - A key mismatch never "aborts": the scanned key outranks the TOFU pin,
///    but only after the user sees both safety codes and confirms.
class IdentityVerificationService extends GetxService {
  static const String _macDomain = 'vant-verify-echo';
  static const String _qrScheme = 'vant-verify';

  /// How long the QR secret stays fresh; the previous secret stays valid a
  /// little longer so a scan in progress isn't killed by rotation.
  static const Duration _secretLifetime = Duration(seconds: 60);
  static const Duration _secretGrace = Duration(minutes: 2);

  LocalStorageService get _storage => Get.find<LocalStorageService>();
  SocketService get _socket => Get.find<SocketService>();
  IdentityService get _identity => Get.find<IdentityService>();

  Uint8List? _currentSecret;
  DateTime? _currentSecretAt;
  Uint8List? _previousSecret;
  DateTime? _previousSecretAt;

  /// True while the verify screen is open — echoes are ignored otherwise.
  bool qrScreenActive = false;

  /// The contact the open QR screen is verifying (expected echo `from`).
  String? expectedPeerId;

  /// A validated echo awaiting the displayer's "confirm who scanned".
  /// Null until a valid echo arrives while the screen is open.
  final Rxn<String> pendingScannerId = Rxn<String>();

  /// Safety code for the currently open screen (for the display + scanner).
  final Rxn<String> safetyCode = Rxn<String>();

  /// Whether the pending echo's secret was already spent — a second valid
  /// echo in one session is suspicious, not convenient.
  bool _secretSpent = false;

  @override
  void onInit() {
    super.onInit();
    _socket.onVerifyEcho = _handleVerifyEcho;
  }

  // ---------------------------------------------------------------------------
  // Displayer side
  // ---------------------------------------------------------------------------

  /// Open the verify screen for [peerId]: mint a fresh secret and compute
  /// the safety code shown on both phones.
  Future<String?> openVerification(String peerId) async {
    final myId = _storage.deviceId;
    final myBundle = _identity.identityBundleBase64;
    final peerBundle = _storage.getPeerBundle(peerId);
    if (myId == null || myBundle == null) return null;

    _rotateSecret();
    qrScreenActive = true;
    expectedPeerId = peerId;
    pendingScannerId.value = null;
    _secretSpent = false;

    if (peerBundle != null) {
      safetyCode.value = await SafetyCode.compute(
        idA: myId,
        bundleA: myBundle,
        idB: peerId,
        bundleB: peerBundle,
      );
    } else {
      safetyCode.value = null; // no pin yet — QR scan will pin it
    }
    return myBundle;
  }

  /// QR text to display: `vant-verify?v=1&id=ID&b=BUNDLE&s=SECRET`
  String? qrPayload() {
    final myId = _storage.deviceId;
    final bundle = _identity.identityBundleBase64;
    final s = _currentSecret;
    if (myId == null || bundle == null || s == null) return null;
    return '$_qrScheme?v=1&id=$myId&b=${Uri.encodeComponent(bundle)}'
        '&s=${Uri.encodeComponent(base64Encode(s))}';
  }

  void _rotateSecret() {
    if (_currentSecret != null) {
      _previousSecret = _currentSecret;
      _previousSecretAt = _currentSecretAt;
    }
    _currentSecret = _random32();
    _currentSecretAt = DateTime.now();
  }

  /// Called by the QR screen periodically to keep the code fresh.
  void maybeRotateSecret() {
    if (!qrScreenActive || _currentSecret == null) return;
    if (DateTime.now().difference(_currentSecretAt!) > _secretLifetime) {
      _rotateSecret();
    }
  }

  /// Close the screen — secrets drop, echoes stop being accepted.
  void closeVerification() {
    qrScreenActive = false;
    expectedPeerId = null;
    pendingScannerId.value = null;
    safetyCode.value = null;
    _currentSecret = null;
    _previousSecret = null;
    _secretSpent = false;
  }

  /// Displayer confirms the pending scanner is really the contact in front
  /// of them — marks the peer verified and spends the secret.
  Future<bool> confirmScanner() async {
    final peerId = pendingScannerId.value;
    if (peerId == null || _secretSpent) return false;
    _secretSpent = true;
    final ok = await _storage.markPeerVerified(peerId);
    if (ok && Get.isRegistered<IdentityAnnouncementService>()) {
      Get.find<IdentityAnnouncementService>().clearCapabilityReset(peerId);
    }
    pendingScannerId.value = null;
    return ok;
  }

  void rejectScanner() {
    pendingScannerId.value = null;
  }

  Future<void> _handleVerifyEcho(Map<String, dynamic> data) async {
    if (!qrScreenActive) return; // no QR on screen → echoes mean nothing
    final from = data['from'] as String?;
    final bundle = data['bundle'] as String?;
    final macB64 = data['mac'] as String?;
    if (from == null || bundle == null || macB64 == null) return;
    if (from != expectedPeerId) return; // someone else scanned — not ours
    if (_secretSpent) return; // single-use secret

    final myId = _storage.deviceId;
    if (myId == null) return;

    // The echoed bundle must match our pin for that peer — a server-side
    // bound ID can't legitimately change keys, so a mismatch is a conflict.
    final pinned = _storage.getPeerBundle(from);
    if (pinned != null && pinned != bundle) {
      await _storage.pinPeerBundle(from, bundle); // records the conflict
      return;
    }

    final now = DateTime.now();
    Uint8List? secret = _currentSecret;
    if (secret == null ||
        now.difference(_currentSecretAt!) > _secretLifetime) {
      secret = null;
    }
    // Grace: the just-rotated secret remains acceptable briefly.
    if (secret == null &&
        _previousSecret != null &&
        now.difference(_previousSecretAt!) <
            _secretLifetime + _secretGrace) {
      secret = _previousSecret;
    }
    if (secret == null) return;

    final expected = await _computeEchoMac(
      secret: secret,
      idA: myId,
      idB: from,
      bundleB: bundle,
    );
    if (expected == null) return;
    late final Uint8List got;
    try {
      got = base64Decode(macB64);
    } catch (_) {
      return;
    }
    if (!_constTimeEquals(expected, got)) return;

    // Valid echo — surface "X scanned your code. Confirm?" to the user.
    pendingScannerId.value = from;
  }

  // ---------------------------------------------------------------------------
  // Scanner side — the QR is the authentic channel; never abort on mismatch
  // ---------------------------------------------------------------------------

  /// Result of scanning a QR payload.
  static const String scanVerified = 'verified';
  static const String scanPinnedNew = 'pinned_new';
  static const String scanMismatch = 'mismatch';
  static const String scanInvalid = 'invalid';
  static const String scanUnavailable = 'unavailable';

  /// Parse + validate a scanned payload and pin A's key.
  ///
  /// Returns (result, scannedDeviceId, scannedBundle). On [scanMismatch] the
  /// caller shows BOTH safety codes and an explicit "replace pin"
  /// confirmation — the pin may be the attacker's; the QR came from the
  /// real device.
  Future<(String, String?, String?)> handleScannedQr(String raw) async {
    final parsed = _parseQr(raw);
    if (parsed == null) return (scanInvalid, null, null);
    final (idA, bundleA, secret) = parsed;

    final peer = IdentityService.parseBundle(bundleA);
    if (peer == null) return (scanInvalid, idA, null);

    final existingPin = _storage.getPeerBundle(idA);
    if (_storage.pinStoreUnavailable.value) {
      return (scanUnavailable, idA, bundleA);
    }

    if (existingPin == null) {
      // First contact — pin the scanned key as verified. A QR scan IS the
      // verification; no need to echo-and-wait.
      final ok = await _storage.replacePeerPinVerified(idA, bundleA);
      if (!ok) return (scanUnavailable, idA, bundleA);
    } else if (existingPin == bundleA) {
      await _storage.markPeerVerified(idA);
    } else {
      // caller shows both safety codes + replace-pin confirmation
      return (scanMismatch, idA, bundleA);
    }
    if (Get.isRegistered<IdentityAnnouncementService>()) {
      Get.find<IdentityAnnouncementService>().clearCapabilityReset(idA);
    }

    // Bounce the secret back so the displayer learns who scanned.
    await _sendEcho(to: idA, secret: secret);
    return (
      existingPin == null ? scanPinnedNew : scanVerified,
      idA,
      bundleA,
    );
  }

  /// User confirmed "replace pin with the scanned key" after seeing both
  /// safety codes. Called only from the mismatch confirmation dialog.
  Future<bool> confirmReplacePin(String peerId, String scannedBundle) async {
    final ok = await _storage.replacePeerPinVerified(peerId, scannedBundle);
    if (ok && Get.isRegistered<IdentityAnnouncementService>()) {
      Get.find<IdentityAnnouncementService>().clearCapabilityReset(peerId);
    }
    return ok;
  }

  /// Safety code from the SCANNER's perspective: scanned bundle vs our own.
  Future<String?> scannedSafetyCode(String scannedId, String scannedBundle) {
    final myId = _storage.deviceId;
    final myBundle = _identity.identityBundleBase64;
    if (myId == null || myBundle == null) return Future.value(null);
    return SafetyCode.compute(
      idA: myId,
      bundleA: myBundle,
      idB: scannedId,
      bundleB: scannedBundle,
    );
  }

  Future<void> _sendEcho(
      {required String to, required Uint8List secret}) async {
    final myId = _storage.deviceId;
    final myBundle = _identity.identityBundleBase64;
    if (myId == null || myBundle == null) return;
    final mac = await _computeEchoMac(
      secret: secret,
      idA: to,
      idB: myId,
      bundleB: myBundle,
    );
    if (mac == null) return;
    await _socket.sendVerifyEcho(
      to: to,
      bundle: myBundle,
      mac: base64Encode(mac),
    );
  }

  /// HMAC-SHA256(secret, "vant-verify-echo"|idA|idB|bundleB-raw).
  /// The secret is the KEY — it never leaves the QR screen, so the server
  /// cannot forge or alter the echo.
  Future<Uint8List?> _computeEchoMac({
    required Uint8List secret,
    required String idA,
    required String idB,
    required String bundleB,
  }) async {
    late final Uint8List bundleBytes;
    try {
      bundleBytes = base64Decode(bundleB);
    } catch (_) {
      return null;
    }
    final msg = BytesBuilder()
      ..add(utf8.encode(_macDomain))
      ..add(utf8.encode(idA))
      ..add(utf8.encode(idB))
      ..add(bundleBytes);
    final mac = await Hmac.sha256().calculateMac(
      msg.toBytes(),
      secretKey: SecretKey(secret),
    );
    return Uint8List.fromList(mac.bytes);
  }

  /// Parse vant-verify?v=1&id=..&b=..&s=.. — strict, no auto-navigation.
  /// Returns (id, bundle, secretBytes) or null.
  (String, String, Uint8List)? _parseQr(String raw) {
    if (raw.length > 512) return null;
    late final Uri uri;
    try {
      uri = Uri.parse(raw);
    } catch (_) {
      return null;
    }
    if (uri.scheme != _qrScheme || uri.queryParameters['v'] != '1') {
      return null;
    }
    final id = uri.queryParameters['id'];
    final bundle = uri.queryParameters['b'];
    final secretB64 = uri.queryParameters['s'];
    if (id == null || bundle == null || secretB64 == null) return null;
    if (!RegExp(r'^\d{8,20}$').hasMatch(id)) return null;
    if (bundle.length > 200) return null;
    try {
      final s = base64Decode(secretB64);
      if (s.length != 32) return null;
      return (id, bundle, s);
    } catch (_) {
      return null;
    }
  }

  static Uint8List _random32() {
    final r = SecureRandom.fast;
    return Uint8List.fromList(
        List<int>.generate(32, (_) => r.nextInt(256)));
  }

  static bool _constTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  @override
  void onClose() {
    if (Get.isRegistered<SocketService>()) {
      _socket.onVerifyEcho = null;
    }
    super.onClose();
  }
}
