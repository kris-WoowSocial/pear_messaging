import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import 'feature_flag_service.dart';
import 'identity_service.dart';
import 'local_storage_service.dart';
import 'socket_service.dart';

/// Identity Announcement Service — spreads our identity bundle to existing
/// contacts (TOFU propagation) and pins bundles received from peers.
///
/// Sender side: on each registered socket we announce our self-signed bundle
/// to contacts with no pinned bundle yet. A target stays queued until the
/// RECIPIENT acks a terminal status (pinned/unchanged/conflict) — a bare
/// server relay or a 'rejected' ack (not-a-contact, degraded store, old
/// client) keeps it queued with exponential backoff.
///
/// Receiver side: an announcement is verified as self-signed by the claimed
/// key, then pinned only for an accepted contact AND only if no pin exists.
/// A differing bundle is a key-changed warning — never a silent overwrite.
class IdentityAnnouncementService extends GetxService {
  LocalStorageService get _storage => Get.find<LocalStorageService>();
  SocketService get _socket => Get.find<SocketService>();
  IdentityService get _identity => Get.find<IdentityService>();

  /// Per-target announce state. Backoff doubles per attempt (1min → 6h cap)
  /// so permanently-unreachable contacts (old clients) stop costing traffic.
  final Map<String, _AnnounceTarget> _targets = {};

  /// Contacts whose incoming bundle conflicts with the existing pin.
  /// Exposed so the UI can surface a key-changed warning.
  final RxSet<String> keyChangedConflicts = <String>{}.obs;

  /// Contacts whose signed capability sequence went backwards while their
  /// identity bundle stayed unchanged. This can mean a reinstall/reset or a
  /// replay attempt, so the UI must ask for explicit re-verification.
  final RxSet<String> capabilityResetContacts = <String>{}.obs;

  /// Test seam for counting UI alerts without creating a snackbar.
  @visibleForTesting
  void Function(String peerId)? capabilityResetAlert;

  static const Duration _retryTick = Duration(seconds: 30);
  static const Duration _baseBackoff = Duration(minutes: 1);
  static const Duration _maxBackoff = Duration(hours: 6);
  static const int _maxSendsPerFlush = 10;
  static const Duration _sendSpacing = Duration(milliseconds: 300);

  Timer? _retryTimer;
  Worker? _registrationWorker;

  /// sha256(utf8 bundleBase64) hex — attached to acks so the sender can match
  /// the ack to the exact bundle it announced.
  static Future<String> bundleHash(String bundleBase64) async {
    final digest = await Sha256().hash(utf8.encode(bundleBase64));
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Map a pin result to the wire ack status. 'unchanged' must stay
  /// 'unchanged' — acking it 'rejected' would retry already-pinned contacts
  /// forever. 'rejected' is the generic refusal (no probing signal).
  static String statusForPinResult(String pinResult) {
    switch (pinResult) {
      case LocalStorageService.pinResultPinned:
        return 'pinned';
      case LocalStorageService.pinResultUnchanged:
        return 'unchanged';
      case LocalStorageService.pinResultConflict:
        return 'conflict';
      default: // no_chat, unavailable (degraded store)
        return 'rejected';
    }
  }

  @override
  void onInit() {
    super.onInit();
    _socket.onIdentityAnnounce = _handleAnnouncement;
    _socket.onIdentityAnnounceAcked = _handleAnnounceAck;

    // Restore persisted security warnings — a restart must never drop them,
    // and a sender stops retrying after a 'conflict' ack.
    keyChangedConflicts.addAll(_storage.peersWithConflict());
    capabilityResetContacts.addAll(_storage.peersWithCapabilityReset());

    // Re-announce whenever the socket registers — reconnect resets backoff
    // so fresh connections retry immediately.
    _registrationWorker = ever(_socket.isRegistered, (registered) {
      if (registered == true) {
        for (final t in _targets.values) t.nextDue = DateTime.now();
        _rescanAndAnnounce();
      }
    });

    _retryTimer = Timer.periodic(_retryTick, (_) {
      if (_targets.isNotEmpty && _socket.isRegistered.value) {
        _flushPending();
      }
    });
  }

  /// Announce our bundle to every contact that lacks a pin (paced).
  Future<void> announceToContacts() => _rescanAndAnnounce();

  /// Announce to a single contact — resets its backoff, so calling this on
  /// contact acceptance announces immediately.
  Future<void> announceTo(String deviceId) async {
    if (!_identity.hasIdentity.value) return;
    if (_storage.getPeerBundle(deviceId) != null) return;
    _targets[deviceId] = _AnnounceTarget()..nextDue = DateTime.now();
    await _flushPending();
  }

  Future<void> _rescanAndAnnounce() async {
    if (!_identity.hasIdentity.value) return;
    for (final id in _storage.contactsWithoutPin()) {
      _targets.putIfAbsent(id, _AnnounceTarget.new);
    }
    await _flushPending();
  }

  Future<void> _flushPending() async {
    if (!_identity.hasIdentity.value) return;
    // Retry opening the pin store if it was degraded — recovers after a
    // locked-device window or transient keystore failure.
    await _storage.retryPeerIdentityStore();

    final bundle = _identity.identityBundleBase64;
    final myId = _storage.deviceId;
    if (bundle == null || myId == null) return;

    final signature = await _identity.signAnnouncement(myId);
    if (signature == null) return;

    final flags = Get.isRegistered<FeatureFlagService>()
        ? Get.find<FeatureFlagService>()
        : null;
    final encryptedAvailable =
        flags?.encryptedSignaling.value == true && _identity.hasIdentity.value;
    final capabilities = IdentityService.canonicalCapabilities([
      if (encryptedAvailable) 'encrypted_call',
      if (encryptedAvailable && flags?.videoCalling.value == true) 'video_call',
    ]);
    final capabilitySeq = await _identity.nextCapabilitySequence();

    final now = DateTime.now();
    var sent = 0;
    for (final entry in _targets.entries.toList()) {
      if (sent >= _maxSendsPerFlush) break;
      final to = entry.key;
      final state = entry.value;
      if (state.nextDue.isAfter(now)) continue; // backing off
      try {
        final capabilitySig = await _identity.signCapabilities(
          myId,
          to,
          capabilitySeq,
          capabilities,
        );
        if (capabilitySig == null) continue;
        // Server ack = relayed only; target stays queued for the recipient's
        // terminal ack (matched by bundleHash).
        await _socket.sendIdentityAnnounce(
          to: to,
          bundle: bundle,
          signature: signature,
          capabilities: capabilities,
          capabilitySeq: capabilitySeq,
          capabilitySig: capabilitySig,
        );
        state.attempts += 1;
        state.nextDue = now.add(_backoffFor(state.attempts));
        sent += 1;
        if (sent < _maxSendsPerFlush) {
          await Future.delayed(_sendSpacing);
        }
      } catch (e) {
        debugPrint('⚠️ Identity announce to $to failed: $e');
        state.attempts += 1;
        state.nextDue = now.add(_backoffFor(state.attempts));
      }
    }
  }

  static Duration _backoffFor(int attempts) {
    final shift = attempts.clamp(0, 20);
    final ms = _baseBackoff.inMilliseconds << shift;
    return Duration(
      milliseconds:
          ms > _maxBackoff.inMilliseconds ? _maxBackoff.inMilliseconds : ms,
    );
  }

  /// Dequeue rule for announce acks — extracted for testing. An ack clears
  /// a target only when ALL hold: terminal status (not 'rejected'), the
  /// ack's `from` is a target we actually announced to, and the bundleHash
  /// matches what we sent.
  static bool isDequeueableAck({
    required String status,
    required bool targetQueued,
    required bool hashMatch,
  }) {
    // Whitelist terminal statuses — an unexpected value stays queued rather
    // than trusting "anything but rejected".
    const terminal = {'pinned', 'unchanged', 'conflict'};
    return terminal.contains(status) && targetQueued && hashMatch;
  }

  /// Recipient pin result, matched to the exact bundle we announced.
  /// 'rejected' keeps the target queued; everything else dequeues.
  void _handleAnnounceAck(Map<String, dynamic> data) {
    final from = data['from'] as String?;
    final status = data['status'] as String?;
    final hash = data['bundleHash'] as String?;
    if (from == null || status == null) return;
    () async {
      final bundle = _identity.identityBundleBase64;
      final ours = bundle == null ? null : await bundleHash(bundle);
      final dequeue = isDequeueableAck(
        status: status,
        targetQueued: _targets.containsKey(from),
        hashMatch: ours != null && ours == hash,
      );
      if (!dequeue) return;
      _targets.remove(from);
      if (status == 'conflict') {
        debugPrint('⚠️ $from reports a key conflict with our bundle');
      }
    }();
  }

  @visibleForTesting
  Future<void> handleAnnouncementForTest(Map<String, dynamic> data) {
    return _handleAnnouncement(data);
  }

  Future<void> _handleAnnouncement(Map<String, dynamic> data) async {
    final from = data['from'] as String?;
    final to = data['to'] as String?;
    final bundle = data['bundle'] as String?;
    final signature = data['signature'] as String?;
    if (from == null || bundle == null || signature == null) return;

    Future<void> ack(String status) async {
      _socket.sendIdentityAnnounceAck(
        to: from,
        status: status,
        bundleHash: await bundleHash(bundle),
      );
    }

    if (to == null || to != _storage.deviceId) {
      await ack('rejected');
      return;
    }

    // Only accept announcements from ACCEPTED contacts. A pending connection
    // request creates a chat record too — those must not pin. The ack is a
    // generic 'rejected' so strangers can't probe our contact list.
    final chat = _storage.getChat(from);
    final isPendingRequest =
        chat?.lastMessage?.contains('Invitation sent') == true;
    if (chat == null || isPendingRequest) {
      await ack('rejected');
      return;
    }

    // Verify the bundle is self-signed by its own Ed25519 key — prevents
    // corrupted/inconsistent bundles being pinned.
    final valid = await _identity.verifyAnnouncement(
      senderDeviceId: from,
      bundleBase64: bundle,
      signatureBase64: signature,
    );
    if (!valid) {
      debugPrint('⚠️ Identity announcement signature invalid from $from');
      await ack('rejected');
      return;
    }

    final hasCapabilityField = data.containsKey('capabilities') ||
        data.containsKey('capabilitySeq') ||
        data.containsKey('capabilitySig');
    var capabilities = const <String>[];
    var capabilitySeq = -1;
    if (hasCapabilityField) {
      final rawSeq = data['capabilitySeq'];
      final capabilitySig = data['capabilitySig'];
      final rawCapabilities = data['capabilities'];
      capabilitySeq = rawSeq is int
          ? rawSeq
          : rawSeq is num
              ? rawSeq.toInt()
              : -1;
      capabilities = rawCapabilities is List
          ? IdentityService.canonicalCapabilities(
              rawCapabilities.whereType<String>(),
            )
          : const <String>[];
      final signed = capabilitySeq >= 0 &&
          capabilitySig is String &&
          rawCapabilities is List &&
          await _identity.verifyCapabilities(
            senderDeviceId: from,
            targetDeviceId: to,
            bundleBase64: bundle,
            sequence: capabilitySeq,
            capabilities: capabilities,
            signatureBase64: capabilitySig,
          );
      if (!signed) {
        debugPrint('⚠️ Capability announcement signature invalid from $from');
        await ack('rejected');
        return;
      }
    }

    final result = await _storage.pinPeerBundle(from, bundle);
    if (hasCapabilityField &&
        (result == LocalStorageService.pinResultPinned ||
            result == LocalStorageService.pinResultUnchanged)) {
      final accepted = await _storage.recordPeerCapabilities(
        from,
        capabilities,
        capabilitySeq,
        bundleBase64: bundle,
      );
      if (!accepted) {
        if (_storage.hasPeerCapabilityReset(from) &&
            capabilityResetContacts.add(from)) {
          final alert = capabilityResetAlert;
          if (alert != null) {
            alert(from);
          } else {
            Get.snackbar(
              'Contact security reset?',
              'Their secure-call state rolled back. Verify again to clear this warning.',
              snackPosition: SnackPosition.BOTTOM,
              duration: const Duration(seconds: 6),
            );
          }
        }
        debugPrint('⚠️ Stale capability announcement ignored for $from');
      } else {
        capabilityResetContacts.remove(from);
      }
    }
    await ack(statusForPinResult(result));
    switch (result) {
      case LocalStorageService.pinResultPinned:
        debugPrint('🔐 Pinned identity bundle for $from (TOFU/unverified)');
        break;
      case LocalStorageService.pinResultConflict:
        debugPrint('⚠️ Key-changed conflict for $from — flagging for UI');
        keyChangedConflicts.add(from);
        break;
      default:
        break;
    }
  }

  /// Clear a surfaced conflict after the user has acknowledged it.
  /// Clears the persisted record too — the pin itself is untouched.
  void dismissConflict(String deviceId) {
    keyChangedConflicts.remove(deviceId);
    _storage.clearPeerConflict(deviceId);
  }

  /// Clear a capability rollback warning after explicit re-verification or
  /// user acknowledgment. Verification also clears persisted state.
  void clearCapabilityReset(String deviceId) {
    capabilityResetContacts.remove(deviceId);
    _storage.clearPeerCapabilityReset(deviceId);
  }

  @override
  void onClose() {
    _retryTimer?.cancel();
    _registrationWorker?.dispose();
    if (Get.isRegistered<SocketService>()) {
      _socket.onIdentityAnnounce = null;
      _socket.onIdentityAnnounceAcked = null;
    }
    super.onClose();
  }
}

class _AnnounceTarget {
  int attempts = 0;
  DateTime nextDue = DateTime.fromMillisecondsSinceEpoch(0);
}
