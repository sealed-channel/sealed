/// Per-contact stable channel state (Spec H §5.2 + alias-as-contact v15).
///
/// Persisted in the `contacts` table. All BLOB columns are 32B except
/// `peerMlkemPub` (800B ML-KEM-512 pub) and `myMlkemSk` (1632B ML-KEM-512 sk).
/// The whole table lives inside the SQLCipher-encrypted DB, so secret material
/// is at-rest-encrypted via the page-level cipher.
///
/// [Contact] = wallet-addressed counterpart. [AliasContact] extends with
/// alias-only metadata (display name, invite ref, creator flag). Cryptographic
/// material lives in a separate [ContactKeys] value to keep [Contact] focused
/// on identity/info fields. Dart-side branching uses `if (c is AliasContact)`;
/// SQLite-side branching uses the `is_alias` flag.
library;

import 'dart:typed_data';

enum ContactKind { wallet, alias }

/// All cryptographic material for a contact's stable channel. Bundled
/// separately from identity/info on [Contact] so the row-key surface stays
/// in one place; pass `contact.keys.peerX25519Scan` instead of widening
/// [Contact] with 11 BLOB fields.
class ContactKeys {
  final Uint8List sharedSecret;
  final Uint8List recipientTag;
  final Uint8List msgKey;
  final Uint8List peerX25519Pub;
  final Uint8List peerX25519Scan;
  final Uint8List? peerMlkemPub; // null = classical-only peer
  final Uint8List myX25519Sk;
  final Uint8List myX25519ScanSk;
  final Uint8List? myMlkemSk;
  final Uint8List tagSalt;
  final Uint8List? pqSharedSecret;

  const ContactKeys({
    required this.sharedSecret,
    required this.recipientTag,
    required this.msgKey,
    required this.peerX25519Pub,
    required this.peerX25519Scan,
    this.peerMlkemPub,
    required this.myX25519Sk,
    required this.myX25519ScanSk,
    this.myMlkemSk,
    required this.tagSalt,
    this.pqSharedSecret,
  });

  Map<String, Object?> toRow() => {
    'shared_secret': sharedSecret,
    'recipient_tag': recipientTag,
    'msg_key': msgKey,
    'peer_x25519_pub': peerX25519Pub,
    'peer_x25519_scan': peerX25519Scan,
    'peer_mlkem_pub': peerMlkemPub,
    'my_x25519_sk': myX25519Sk,
    'my_x25519_scan_sk': myX25519ScanSk,
    'my_mlkem_sk': myMlkemSk,
    'tag_salt': tagSalt,
    'pq_shared_secret': pqSharedSecret,
  };

  static ContactKeys fromRow(Map<String, Object?> r) => ContactKeys(
    sharedSecret: _blob(r['shared_secret']),
    recipientTag: _blob(r['recipient_tag']),
    msgKey: _blob(r['msg_key']),
    peerX25519Pub: _blob(r['peer_x25519_pub']),
    peerX25519Scan: _blob(r['peer_x25519_scan']),
    peerMlkemPub: _blobOrNull(r['peer_mlkem_pub']),
    myX25519Sk: _blob(r['my_x25519_sk']),
    myX25519ScanSk: _blob(r['my_x25519_scan_sk']),
    myMlkemSk: _blobOrNull(r['my_mlkem_sk']),
    tagSalt: _blob(r['tag_salt']),
    pqSharedSecret: _blobOrNull(r['pq_shared_secret']),
  );

  ContactKeys copyWith({
    Uint8List? peerMlkemPub,
    Uint8List? myMlkemSk,
    Uint8List? pqSharedSecret,
  }) => ContactKeys(
    sharedSecret: sharedSecret,
    recipientTag: recipientTag,
    msgKey: msgKey,
    peerX25519Pub: peerX25519Pub,
    peerX25519Scan: peerX25519Scan,
    peerMlkemPub: peerMlkemPub ?? this.peerMlkemPub,
    myX25519Sk: myX25519Sk,
    myX25519ScanSk: myX25519ScanSk,
    myMlkemSk: myMlkemSk ?? this.myMlkemSk,
    tagSalt: tagSalt,
    pqSharedSecret: pqSharedSecret ?? this.pqSharedSecret,
  );

  static Uint8List _blob(Object? v) {
    if (v is Uint8List) return v;
    if (v is List<int>) return Uint8List.fromList(v);
    throw ArgumentError('Expected BLOB, got ${v.runtimeType}');
  }

  static Uint8List? _blobOrNull(Object? v) {
    if (v == null) return null;
    return _blob(v);
  }
}

class Contact {
  final String contactId;
  final ContactKind kind;
  final String? walletAddress; // wallet-kind only; null for alias
  /// User-set nickname for this contact. Optional in Dart; persisted in the
  /// `alias_label` column (legacy NOT NULL) via `'' ↔ null` sentinel at the
  /// toRow/fromRow boundary. Phase 2 (v18 migration) drops NOT NULL.
  final String? nickname;
  final int createdAt; // unix seconds
  final ContactKeys keys;

  const Contact({
    required this.contactId,
    this.kind = ContactKind.wallet,
    this.walletAddress,
    this.nickname,
    required this.createdAt,
    required this.keys,
  });

  Map<String, Object?> toRow() => {
    'contact_id': contactId,
    'is_alias': kind == ContactKind.alias ? 1 : 0,
    'wallet_address': walletAddress,
    'alias_label': nickname ?? '',
    'alias_display': null,
    'invite_ref': null,
    'is_creator': null,
    'created_at': createdAt,
    ...keys.toRow(),
  };

  /// Polymorphic factory: returns [AliasContact] when `is_alias=1`, plain
  /// [Contact] otherwise.
  static Contact fromRow(Map<String, Object?> r) {
    final isAlias = (r['is_alias'] as int? ?? 0) == 1;
    final keys = ContactKeys.fromRow(r);
    final rawLabel = r['alias_label'] as String?;
    final nickname = (rawLabel == null || rawLabel.isEmpty) ? null : rawLabel;
    if (isAlias) {
      return AliasContact(
        contactId: r['contact_id'] as String,
        nickname: nickname,
        createdAt: r['created_at'] as int,
        keys: keys,
        aliasHandle: r['alias_display'] as String,
        inviteRef: r['invite_ref'] as String,
        isCreator: (r['is_creator'] as int? ?? 0) == 1,
      );
    }
    return Contact(
      contactId: r['contact_id'] as String,
      walletAddress: r['wallet_address'] as String?,
      nickname: nickname,
      createdAt: r['created_at'] as int,
      keys: keys,
    );
  }
}

class AliasContact extends Contact {
  /// Wire-presented alias name from the invite payload (Spec H §5.1 invite
  /// `alias_label` JSON field — kept under the wire name for compat).
  final String aliasHandle;

  /// Hex sha256 of the raw inviteSecret. Raw secret lives only in
  /// FlutterSecureStorage — never in SQLite.
  final String inviteRef;

  /// True on the device that originated the invite, false on the acceptor.
  final bool isCreator;

  const AliasContact({
    required super.contactId,
    super.nickname,
    required super.createdAt,
    required super.keys,
    required this.aliasHandle,
    required this.inviteRef,
    required this.isCreator,
  }) : super(kind: ContactKind.alias, walletAddress: null);

  @override
  Map<String, Object?> toRow() => {
    ...super.toRow(),
    'is_alias': 1,
    'wallet_address': null,
    'alias_display': aliasHandle,
    'invite_ref': inviteRef,
    'is_creator': isCreator ? 1 : 0,
    // Alias handshake is a deliberate mutual act — alias rows are always
    // manual contacts (unlike wallet rows, which auto-insert as key cache).
    'is_contact': 1,
  };
}

class ContactMessage {
  final String id;
  final String contactId;
  final int direction; // 0 = in, 1 = out
  final String content;
  final int timestamp; // unix ms
  final String? onChainRef;

  /// Mirrors wallet-side semantics: outgoing rows are always read; inbound
  /// rows arrive unread (`false`) until the user opens the chat. Defaults to
  /// `true` so that outgoing-side callers don't have to specify it.
  final bool isRead;

  const ContactMessage({
    required this.id,
    required this.contactId,
    required this.direction,
    required this.content,
    required this.timestamp,
    this.onChainRef,
    this.isRead = true,
  });

  Map<String, Object?> toRow() => {
    'id': id,
    'contact_id': contactId,
    'direction': direction,
    'content': content,
    'timestamp': timestamp,
    'on_chain_ref': onChainRef,
    'is_read': isRead ? 1 : 0,
  };

  static ContactMessage fromRow(Map<String, Object?> r) => ContactMessage(
    id: r['id'] as String,
    contactId: r['contact_id'] as String,
    direction: r['direction'] as int,
    content: r['content'] as String,
    timestamp: r['timestamp'] as int,
    onChainRef: r['on_chain_ref'] as String?,
    isRead: (r['is_read'] as int? ?? 1) == 1,
  );
}
