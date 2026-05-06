import 'dart:typed_data';

class OnChainMessage {
  final Uint8List accountPubkey; // 32-byte pubkey
  final Uint8List senderEncryptionPubkey; // 32-byte pubkey
  final Uint8List recipientTag; // 32-byte recipient tag
  final int timestamp; // Unix timestamp in seconds
  final Uint8List cipherText; // rest of AES-GCM encryption

  const OnChainMessage({
    required this.accountPubkey,
    required this.senderEncryptionPubkey,
    required this.recipientTag,
    required this.timestamp,
    required this.cipherText,
  });
}

class DecryptedMessage {
  final String id;
  final String senderWallet;
  String? senderUsername; // for not outgoing messages, username may be null ;
  final String recipientWallet;
  String?
  recipientUsername; // for not incoming messages, username may be null ;
  final String content;
  final DateTime timestamp;
  final bool isOutgoing;
  final String onChainPubkey;

  DecryptedMessage({
    required this.id,
    required this.senderWallet,
    this.senderUsername,
    required this.recipientWallet,
    this.recipientUsername,
    required this.content,
    required this.timestamp,
    required this.isOutgoing,
    required this.onChainPubkey,
  });

  @override
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'senderWallet': senderWallet,
      'senderUsername': senderUsername,
      'recipientWallet': recipientWallet,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'isOutgoing': isOutgoing,
    };
  }

  @override
  factory DecryptedMessage.fromMap(Map<String, dynamic> map) {
    String? getString(dynamic a, dynamic b) {
      if (a != null) return a as String;
      if (b != null) return b as String;
      return '';
    }

    final id = map['id'] as String;
    final senderWallet =
        (map['sender_wallet'] ?? map['senderWallet']) as String;
    final senderUsername =
        (map['sender_username'] ?? map['senderUsername']) as String?;
    final recipientWallet =
        (map['recipient_wallet'] ?? map['recipientWallet']) as String;
    final content = map['content'] as String;
    final timestampRaw = map['timestamp'] ?? map['time'];
    final DateTime timestamp;
    if (timestampRaw is int) {
      timestamp = DateTime.fromMicrosecondsSinceEpoch(timestampRaw);
    } else if (timestampRaw is String) {
      timestamp = DateTime.parse(timestampRaw);
    } else {
      timestamp = DateTime.now();
    }
    final isOutgoingRaw = map['is_outgoing'] ?? map['isOutgoing'];
    final bool isOutgoing = isOutgoingRaw is int
        ? isOutgoingRaw == 1
        : (isOutgoingRaw as bool);
    final onChainPubkey =
        (map['on_chain_pubkey'] ?? map['onChainPubkey']) as String;

    return DecryptedMessage(
      id: id,
      senderWallet: senderWallet,
      senderUsername: (senderUsername == null || senderUsername.isEmpty)
          ? null
          : senderUsername,
      recipientWallet: recipientWallet,
      content: content,
      timestamp: timestamp,
      isOutgoing: isOutgoing,
      onChainPubkey: onChainPubkey,
    );
  }
}
