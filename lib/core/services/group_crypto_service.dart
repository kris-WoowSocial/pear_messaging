import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';

import 'encryption_service.dart';
import 'local_storage_service.dart';
import 'message_crypto_service.dart';

/// Group sender-key encryption (`v2g:`/`v3g:`).
///
/// Every sender holds a random 256-bit group sender key per group. Group
/// payloads are AES-256-GCM sealed under that key and carry only the key
/// id — the key itself is distributed to each member individually over
/// their pairwise `v3s:`/`v2s:` (or ratchet `v3:`/`v2:`) channel inside a
/// `VGK1:` control message, so the relay never sees it.
///
/// Rotation: the sender key binds to the membership fingerprint
/// (SHA-256 of the sorted member id set). Any add/remove changes the
/// fingerprint → the next send generates a fresh key and redistributes,
/// so removed members cannot read later traffic.
///
/// Prefix: `v3g:` when the pairwise channel to EVERY member is
/// post-quantum (pq_mlkem768 + e2e_msg), otherwise `v2g:`. Members with
/// no pinned identity bundle are skipped — a group key never travels
/// over the legacy XOR channel.
///
/// Wire formats:
///   group frame: `v2g:`/`v3g:` + base64url({"kid": keyId, "ct": boxB64})
///   key dist:    `VGK1:` + base64url({"g": groupId, "kid": keyId, "k": keyB64})
///                carried as the `t` field of a normal sealed 1:1 payload
class GroupCryptoService extends GetxService {
  MessageCryptoService get _mcs => Get.find<MessageCryptoService>();
  LocalStorageService get _storage => Get.find<LocalStorageService>();

  static const String groupPrefixV2 = 'v2g:';
  static const String groupPrefixV3 = 'v3g:';
  static const String keyDistPrefix = 'VGK1:';
  static const _storePrefix = 'vant_gk_v1';
  static const _maxPeerKeysPerMember = 8;

  static final _aes = AesGcm.with256bits();
  static final _sha = Sha256();

  final FlutterSecureStorage _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      keyCipherAlgorithm: KeyCipherAlgorithm.RSA_ECB_PKCS1Padding,
      storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
      resetOnError: false,
    ),
    iOptions: IOSOptions(
      accountName: 'VantGroupKeyStore',
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );

  // groupId -> persisted state
  final Map<String, _GroupKeyState> _states = {};
  final Map<String, Future<void>> _locks = {};

  Future<T> _locked<T>(String groupId, Future<T> Function() op) {
    final prev = _locks[groupId] ?? Future.value();
    final run = prev.then((_) => op());
    _locks[groupId] = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<_GroupKeyState> _stateFor(String groupId) async {
    final cached = _states[groupId];
    if (cached != null) return cached;
    final state = _GroupKeyState();
    try {
      final raw = await _secure.read(key: '$_storePrefix:$groupId');
      if (raw != null) {
        state.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('⚠️ Group key state read failed for $groupId: $e');
    }
    _states[groupId] = state;
    return state;
  }

  Future<void> _persist(String groupId) async {
    try {
      await _secure.write(
          key: '$_storePrefix:$groupId',
          value: jsonEncode(_states[groupId]?.toJson() ?? {}));
    } catch (e) {
      debugPrint('⚠️ Group key state persist failed for $groupId: $e');
    }
  }

  /// Prepare a group message for send. Returns the sealed `v2g:`/`v3g:`
  /// ciphertext plus, when the sender key (re)generated, the `VGK1:`
  /// control payload and the member list it must be pairwise-distributed
  /// to BEFORE the group frame is emitted.
  Future<GroupSendPlan?> encryptForGroup({
    required String groupId,
    required List<String> memberIds,
    required String plaintext,
  }) async {
    final myId = _storage.deviceId;
    if (myId == null) return null;
    return _locked(groupId, () async {
      final state = await _stateFor(groupId);
      final members =
          memberIds.where((m) => m != myId && m.isNotEmpty).toList();
      final allIds = List<String>.from(members)..add(myId);
      final mh = await _memberHashAsync(allIds);

      String? keyMessage;
      List<String> distributeTo = const [];
      if (state.mine == null || state.mine!.memberHash != mh) {
        final key = await _aes.newSecretKey();
        final keyBytes =
            Uint8List.fromList(await key.extractBytes());
        final kid = base64Encode(_randomBytes(9));
        // v3g only when every member's pairwise channel is post-quantum.
        final pq = members.isNotEmpty &&
            members.every(_mcs.canSealPqTo);
        state.mine = _SenderKey(
          keyId: kid,
          keyB64: base64Encode(keyBytes),
          memberHash: mh,
          postQuantum: pq,
        );
        keyMessage = _buildKeyMessage(groupId, kid, keyBytes);
        distributeTo = members;
      }

      final mine = state.mine!;
      final wire = await sealFrame(
        keyBytes: base64Decode(mine.keyB64),
        keyId: mine.keyId,
        plaintext: plaintext,
        postQuantum: mine.postQuantum,
      );
      await _persist(groupId);
      return GroupSendPlan(
        ciphertext: wire,
        keyMessage: keyMessage,
        distributeTo: distributeTo,
      );
    });
  }

  /// Decrypt an incoming group frame. Dispatches `v2g:`/`v3g:` to the
  /// sender's stored group key; anything else is legacy XOR (history /
  /// un-upgraded senders). Returns null when no key is cached for the
  /// frame's keyId or AEAD fails.
  Future<String?> decryptForGroup({
    required String groupId,
    required String senderDeviceId,
    required String payload,
  }) async {
    if (!payload.startsWith(groupPrefixV2) &&
        !payload.startsWith(groupPrefixV3)) {
      return EncryptionService.decryptMessage(payload);
    }
    return _locked(groupId, () async {
      try {
        final frame = parseFrame(payload);
        if (frame == null) return null;
        final state = await _stateFor(groupId);
        Uint8List? keyBytes;
        if (senderDeviceId == _storage.deviceId) {
          if (state.mine?.keyId == frame.keyId) {
            keyBytes = base64Decode(state.mine!.keyB64);
          }
        } else {
          final keyB64 = state.peers[senderDeviceId]?[frame.keyId];
          if (keyB64 != null) keyBytes = base64Decode(keyB64);
        }
        if (keyBytes == null) {
          debugPrint(
              '⚠️ No group key for $groupId sender=$senderDeviceId kid=${frame.keyId}');
          return null;
        }
        return await openFrame(keyBytes: keyBytes, frame: frame);
      } catch (e) {
        debugPrint('⚠️ Group frame decrypt failed: $e');
        return null;
      }
    });
  }

  /// Consume a decrypted 1:1 envelope. Returns true (caller must skip
  /// bubble handling) when the payload is a `VGK1:` key-distribution
  /// message — stores the sender's group key under THEIR deviceId.
  Future<bool> maybeHandleKeyDistribution(String senderId, String text) {
    if (!text.startsWith(keyDistPrefix)) return Future.value(false);
    return () async {
      try {
        final dist = parseKeyMessage(text);
        if (dist == null) return true;
        await _locked(dist.groupId, () async {
          final state = await _stateFor(dist.groupId);
          final keys = state.peers.putIfAbsent(
              senderId, () => <String, String>{});
          keys[dist.keyId] = dist.keyB64;
          // Bound memory: drop oldest keyIds past the cap.
          while (keys.length > _maxPeerKeysPerMember) {
            keys.remove(keys.keys.first);
          }
          await _persist(dist.groupId);
        });
        debugPrint('🔑 Stored group key from $senderId for ${dist.groupId}');
      } catch (e) {
        debugPrint('⚠️ Bad VGK1 payload from $senderId: $e');
      }
      return true;
    }();
  }

  /// Forget all key material for a group (leave/delete flow).
  Future<void> clearGroup(String groupId) async {
    _states.remove(groupId);
    try {
      await _secure.delete(key: '$_storePrefix:$groupId');
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // Pure frame helpers — injectable so tests drive them without GetX.
  // ---------------------------------------------------------------------

  /// `v2g:`/`v3g:` + base64url({"kid","ct"}) — AES-256-GCM of [plaintext].
  static Future<String> sealFrame({
    required Uint8List keyBytes,
    required String keyId,
    required String plaintext,
    required bool postQuantum,
  }) async {
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(keyBytes),
    );
    final prefix = postQuantum ? groupPrefixV3 : groupPrefixV2;
    return prefix +
        base64UrlEncode(utf8.encode(jsonEncode({
          'kid': keyId,
          'ct': base64Encode(box.concatenation()),
        })));
  }

  /// Parse a `v2g:`/`v3g:` wire frame. Returns null for non-group or
  /// malformed payloads.
  static GroupFrame? parseFrame(String payload) {
    if (!payload.startsWith(groupPrefixV2) &&
        !payload.startsWith(groupPrefixV3)) {
      return null;
    }
    try {
      final body = jsonDecode(utf8.decode(base64Url
              .decode(payload.substring(groupPrefixV2.length))))
          as Map<String, dynamic>;
      final kid = body['kid'] as String?;
      final ctB64 = body['ct'] as String?;
      if (kid == null || ctB64 == null) return null;
      return GroupFrame(
        keyId: kid,
        ciphertextB64: ctB64,
        postQuantum: payload.startsWith(groupPrefixV3),
      );
    } catch (_) {
      return null;
    }
  }

  /// AES-256-GCM open of a parsed frame under [keyBytes]. Null on
  /// authentication or decode failure.
  static Future<String?> openFrame({
    required Uint8List keyBytes,
    required GroupFrame frame,
  }) async {
    try {
      final pt = await _aes.decrypt(
        SecretBox.fromConcatenation(
          base64Decode(frame.ciphertextB64),
          nonceLength: 12,
          macLength: 16,
        ),
        secretKey: SecretKey(keyBytes),
      );
      return utf8.decode(pt);
    } catch (_) {
      return null;
    }
  }

  /// `VGK1:` + base64url({"g","kid","k"}) — key-distribution control
  /// payload for the pairwise `t` field.
  static String buildKeyMessage(
      String groupId, String keyId, Uint8List keyBytes) {
    return keyDistPrefix +
        base64UrlEncode(utf8.encode(jsonEncode({
          'g': groupId,
          'kid': keyId,
          'k': base64Encode(keyBytes),
        })));
  }

  /// Parse a `VGK1:` control payload. Null on malformed input or a key
  /// that isn't exactly 32 bytes.
  static GroupKeyDistribution? parseKeyMessage(String text) {
    if (!text.startsWith(keyDistPrefix)) return null;
    try {
      final body = jsonDecode(utf8.decode(base64Url
              .decode(text.substring(keyDistPrefix.length))))
          as Map<String, dynamic>;
      final groupId = body['g'] as String?;
      final kid = body['kid'] as String?;
      final keyB64 = body['k'] as String?;
      if (groupId == null || kid == null || keyB64 == null) return null;
      if (base64Decode(keyB64).length != 32) return null;
      return GroupKeyDistribution(
        groupId: groupId,
        keyId: kid,
        keyB64: keyB64,
      );
    } catch (_) {
      return null;
    }
  }

  static String _buildKeyMessage(
          String groupId, String keyId, Uint8List keyBytes) =>
      buildKeyMessage(groupId, keyId, keyBytes);

  Future<String> _memberHashAsync(List<String> memberIds) async {
    final sorted = List<String>.from(memberIds)..sort();
    final digest = await _sha.hash(utf8.encode(sorted.join(',')));
    return base64Encode(digest.bytes);
  }

  static Uint8List _randomBytes(int n) {
    final rnd = SecureRandom.safe;
    return Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));
  }
}

/// What [GroupCryptoService.encryptForGroup] produces for one send.
class GroupSendPlan {
  GroupSendPlan({
    required this.ciphertext,
    this.keyMessage,
    this.distributeTo = const [],
  });

  /// `v2g:`/`v3g:` frame to emit as the group's encryptedPayload.
  final String ciphertext;


  /// `VGK1:` payload for pairwise distribution — non-null only when the
  /// sender key was (re)generated for this send.
  final String? keyMessage;

  /// Members the [keyMessage] must reach BEFORE the group frame lands.
  final List<String> distributeTo;
}

class _SenderKey {
  _SenderKey({
    required this.keyId,
    required this.keyB64,
    required this.memberHash,
    required this.postQuantum,
  });

  final String keyId;
  final String keyB64;
  final String memberHash;
  final bool postQuantum;

  Map<String, dynamic> toJson() => {
        'kid': keyId,
        'k': keyB64,
        'mh': memberHash,
        'pq': postQuantum,
      };

  static _SenderKey? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final kid = j['kid'] as String?;
    final k = j['k'] as String?;
    final mh = j['mh'] as String?;
    if (kid == null || k == null || mh == null) return null;
    return _SenderKey(
      keyId: kid,
      keyB64: k,
      memberHash: mh,
      postQuantum: j['pq'] == true,
    );
  }
}

/// Parsed `v2g:`/`v3g:` frame (see [GroupCryptoService.parseFrame]).
class GroupFrame {
  GroupFrame({
    required this.keyId,
    required this.ciphertextB64,
    required this.postQuantum,
  });

  final String keyId;
  final String ciphertextB64;
  final bool postQuantum;
}

/// Parsed `VGK1:` key-distribution payload.
class GroupKeyDistribution {
  GroupKeyDistribution({
    required this.groupId,
    required this.keyId,
    required this.keyB64,
  });

  final String groupId;
  final String keyId;
  final String keyB64;
}

class _GroupKeyState {
  _SenderKey? mine;

  /// senderDeviceId -> {keyId -> keyB64}
  final Map<String, Map<String, String>> peers = {};

  Map<String, dynamic> toJson() => {
        'mine': mine?.toJson(),
        'peers': peers,
      };

  void fromJson(Map<String, dynamic> j) {
    mine = _SenderKey.fromJson(j['mine'] as Map<String, dynamic>?);
    final p = j['peers'];
    if (p is Map) {
      p.forEach((sender, keys) {
        if (keys is Map) {
          peers[sender as String] = Map<String, String>.from(keys);
        }
      });
    }
  }
}
