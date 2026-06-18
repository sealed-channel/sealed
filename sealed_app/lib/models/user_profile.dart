// lib/models/user_profile.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class UserProfile {
  final String walletAddress; // wallet address (base58)
  final String? username;
  final String? alias;
  final String? bio; // public on-chain bio, ≤160 UTF-8 bytes (null = unset)
  final Uint8List encryptionPubkey; // 32-byte X25519 pubkey
  final Uint8List scanPubkey; // 32-byte X25519 scan pubkey
  final Uint8List?
  pqPublicKey; // 800-byte ML-KEM-512 pubkey (null for legacy profiles)
  final Uint8List? pqPubkeyHash; // 32B sha256(pqPublicKey) — on-chain anchor
  final DateTime createdAt;

  String get encryptionPubkeyBase64 => base64.encode(encryptionPubkey);
  String get scanPubkeyBase64 => base64.encode(scanPubkey);
  String? get pqPublicKeyBase64 =>
      pqPublicKey != null ? base64.encode(pqPublicKey!) : null;
  String? get pqPubkeyHashHex => pqPubkeyHash != null
      ? pqPubkeyHash!.map((b) => b.toRadixString(16).padLeft(2, '0')).join()
      : null;

  /// Constant-time verification that [pq] matches [expectedHash].
  /// Returns false on length mismatch or any byte difference.
  static bool verifyPqPubkey(Uint8List pq, Uint8List expectedHash) {
    if (expectedHash.length != 32) return false;
    final actual = Uint8List.fromList(sha256.convert(pq).bytes);
    if (actual.length != expectedHash.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual[i] ^ expectedHash[i];
    }
    return diff == 0;
  }

  UserProfile({
    required this.walletAddress,
    this.username,
    this.alias,
    this.bio,
    required this.encryptionPubkey,
    required this.scanPubkey,
    this.pqPublicKey,
    this.pqPubkeyHash,
    required this.createdAt,
  });

  /// From SQLite row
  factory UserProfile.fromMap(Map<String, dynamic> map) {
    Uint8List? maybePqKey;
    final rawPq = map['pq_public_key'];
    if (rawPq != null) {
      maybePqKey = rawPq is Uint8List
          ? rawPq
          : Uint8List.fromList((rawPq as List<int>));
    }
    Uint8List? maybePqHash;
    final rawHash = map['pq_pubkey_hash'];
    if (rawHash != null) {
      maybePqHash = rawHash is Uint8List
          ? rawHash
          : Uint8List.fromList((rawHash as List<int>));
    }
    return UserProfile(
      walletAddress: (map['wallet_address'] ?? map['walletAddress']) as String,
      username: map['username'] as String?,
      alias: map['alias'] as String?,
      bio: map['bio'] as String?,
      encryptionPubkey: map['encryption_pubkey'] is Uint8List
          ? map['encryption_pubkey']
          : Uint8List.fromList((map['encryption_pubkey'] as List<int>)),
      scanPubkey: map['scan_pubkey'] is Uint8List
          ? map['scan_pubkey']
          : Uint8List.fromList((map['scan_pubkey'] as List<int>)),
      pqPublicKey: maybePqKey,
      pqPubkeyHash: maybePqHash,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as int) * 1000,
      ),
    );
  }

  /// To SQLite row
  Map<String, dynamic> toMap() {
    return {
      'wallet_address': walletAddress,
      'username': username,
      'alias': alias,
      'bio': bio,
      'encryption_pubkey': encryptionPubkey,
      'scan_pubkey': scanPubkey,
      'pq_public_key': pqPublicKey,
      'pq_pubkey_hash': pqPubkeyHash,
      'created_at': createdAt.millisecondsSinceEpoch ~/ 1000,
    };
  }

  /// To JSON (for debugging/logging)
  Map<String, dynamic> toJson() {
    return {
      'walletAddress': walletAddress,
      'username': username,
      'alias': alias,
      'bio': bio,
      'encryptionPubkey': encryptionPubkeyBase64,
      'scanPubkey': scanPubkeyBase64,
      'pqPublicKey': pqPublicKeyBase64,
      'pqPubkeyHash': pqPubkeyHashHex,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  @override
  String toString() {
    return 'UserProfile(username: ${username ?? '-'}, walletAddress: ${walletAddress.substring(0, 8)}...)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    // Include the mutable display fields (username/alias/bio) so that a
    // change produces an unequal profile. currentUserProvider dedups by ==,
    // and keying on walletAddress alone swallowed username updates — the
    // settings UI then showed the stale name until the screen was rebuilt.
    return other is UserProfile &&
        other.walletAddress == walletAddress &&
        other.username == username &&
        other.alias == alias &&
        other.bio == bio;
  }

  @override
  int get hashCode => Object.hash(walletAddress, username, alias, bio);

  /// Create a copy with some fields updated
  UserProfile copyWith({
    String? walletAddress,
    String? username,
    String? alias,
    String? bio,
    Uint8List? encryptionPubkey,
    Uint8List? scanPubkey,
    Uint8List? pqPublicKey,
    Uint8List? pqPubkeyHash,
    DateTime? createdAt,
    bool clearBio = false,
  }) {
    return UserProfile(
      walletAddress: walletAddress ?? this.walletAddress,
      username: username ?? this.username,
      alias: alias ?? this.alias,
      // `bio: null` means "keep" like every other field; pass clearBio to
      // actually null it out (bio is clearable on-chain, unlike the others).
      bio: clearBio ? null : (bio ?? this.bio),
      encryptionPubkey: encryptionPubkey ?? this.encryptionPubkey,
      scanPubkey: scanPubkey ?? this.scanPubkey,
      pqPublicKey: pqPublicKey ?? this.pqPublicKey,
      pqPubkeyHash: pqPubkeyHash ?? this.pqPubkeyHash,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
