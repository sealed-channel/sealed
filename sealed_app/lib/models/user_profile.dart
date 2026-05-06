// lib/models/user_profile.dart

import 'dart:convert';
import 'dart:typed_data';

class UserProfile {
  final String owner; // wallet address (base58)
  final String? username;
  final String? displayName;
  final Uint8List encryptionPubkey; // 32-byte X25519 pubkey
  final Uint8List scanPubkey; // 32-byte X25519 scan pubkey
  final Uint8List?
  pqPublicKey; // 800-byte ML-KEM-512 pubkey (null for legacy profiles)
  final DateTime createdAt;

  /// Marks profiles imported from the pre-Algorand indexer-service. These
  /// owners are Solana base58, never published on Algorand chain, and the
  /// UI must render them dimmed and non-messageable until re-claimed.
  /// In-memory only — not persisted to local SQLite cache.
  final bool legacy;

  String get encryptionPubkeyBase64 => base64.encode(encryptionPubkey);
  String get scanPubkeyBase64 => base64.encode(scanPubkey);
  String? get pqPublicKeyBase64 =>
      pqPublicKey != null ? base64.encode(pqPublicKey!) : null;

  // Alias for consistency with other code
  String get walletAddress => owner;

  UserProfile({
    required this.owner,
    this.username,
    this.displayName,
    required this.encryptionPubkey,
    required this.scanPubkey,
    this.pqPublicKey,
    required this.createdAt,
    this.legacy = false,
  });

  /// From on-chain account data (Solana RPC response)
  factory UserProfile.fromAccountData(Map<String, dynamic> data) {
    Uint8List decodeKey(dynamic v) {
      if (v is String) return base64.decode(v);
      if (v is Uint8List) return v;
      if (v is List<int>) return Uint8List.fromList(v);
      throw ArgumentError('Unsupported key format');
    }

    return UserProfile(
      owner: data['owner'] as String,
      username: data['username'] as String?,
      displayName: (data['displayName'] ?? data['display_name']) as String?,
      encryptionPubkey: decodeKey(
        data['encryptionPubkey'] ?? data['encryption_pubkey'],
      ),
      scanPubkey: decodeKey(data['scanPubkey'] ?? data['scan_pubkey']),
      pqPublicKey: data['pqPublicKey'] != null || data['pq_public_key'] != null
          ? decodeKey(data['pqPublicKey'] ?? data['pq_public_key'])
          : null,
      createdAt: data['createdAt'] is DateTime
          ? data['createdAt']
          : DateTime.parse(data['createdAt'] as String),
    );
  }

  /// From SQLite row
  factory UserProfile.fromMap(Map<String, dynamic> map) {
    Uint8List? maybePqKey;
    final rawPq = map['pq_public_key'];
    if (rawPq != null) {
      maybePqKey = rawPq is Uint8List
          ? rawPq
          : Uint8List.fromList((rawPq as List<int>));
    }
    return UserProfile(
      owner: map['wallet_address'] as String,
      username: map['username'] as String?,
      displayName: map['display_name'] as String?,
      encryptionPubkey: map['encryption_pubkey'] is Uint8List
          ? map['encryption_pubkey']
          : Uint8List.fromList((map['encryption_pubkey'] as List<int>)),
      scanPubkey: map['scan_pubkey'] is Uint8List
          ? map['scan_pubkey']
          : Uint8List.fromList((map['scan_pubkey'] as List<int>)),
      pqPublicKey: maybePqKey,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as int) * 1000,
      ),
    );
  }

  /// To SQLite row
  Map<String, dynamic> toMap() {
    return {
      'wallet_address': owner,
      'username': username,
      'display_name': displayName,
      'encryption_pubkey': encryptionPubkey,
      'scan_pubkey': scanPubkey,
      'pq_public_key': pqPublicKey,
      'created_at': createdAt.millisecondsSinceEpoch ~/ 1000,
    };
  }

  /// To JSON (for debugging/logging)
  Map<String, dynamic> toJson() {
    return {
      'owner': owner,
      'username': username,
      'displayName': displayName,
      'encryptionPubkey': encryptionPubkeyBase64,
      'scanPubkey': scanPubkeyBase64,
      'pqPublicKey': pqPublicKeyBase64,
      'createdAt': createdAt.toIso8601String(),
      'legacy': legacy,
    };
  }

  @override
  String toString() {
    return 'UserProfile(username: ${username ?? '-'}, owner: ${owner.substring(0, 8)}...)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UserProfile && other.owner == owner;
  }

  @override
  int get hashCode => owner.hashCode;

  /// Create a copy with some fields updated
  UserProfile copyWith({
    String? owner,
    String? username,
    String? displayName,
    Uint8List? encryptionPubkey,
    Uint8List? scanPubkey,
    Uint8List? pqPublicKey,
    DateTime? createdAt,
    bool? legacy,
  }) {
    return UserProfile(
      owner: owner ?? this.owner,
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      encryptionPubkey: encryptionPubkey ?? this.encryptionPubkey,
      scanPubkey: scanPubkey ?? this.scanPubkey,
      pqPublicKey: pqPublicKey ?? this.pqPublicKey,
      createdAt: createdAt ?? this.createdAt,
      legacy: legacy ?? this.legacy,
    );
  }
}
