import 'dart:typed_data';

abstract class ChainClient {
  String get chainId;
  String? get activeWalletAddress;

  Future<int> getWalletBalance(String walletAddress);

  Future<String> sendMessage({
    required Uint8List recipientTag,
    required Uint8List ciphertext,
    required Uint8List senderEncryptionPubkey,
    required String recipientWallet,
  });

  Future<Map<String, dynamic>?> getMessageByAccount(String accountRef);

  Future<List<Map<String, dynamic>>> fetchRecentMemoMessages({
    int? sinceTimestamp,
    int limit = 200,
  });

  /// Fetch memo messages from a specific wallet address (for alias chat sync).
  Future<List<Map<String, dynamic>>> fetchMemoMessagesForAddress(
    String address, {
    int? sinceTimestamp,
    int limit = 200,
  });

  Future<String> setUsernameViaMemo({required String username});

  /// Look up the most recent on-chain username claim for [walletAddress].
  ///
  /// Returns the username string if found, or null if the wallet has never
  /// published a username. Used as a fallback during profile recovery when
  /// the off-chain indexer doesn't have the user (e.g. fresh indexer
  /// deploy, indexer downtime, or first ingest).
  Future<String?> fetchLatestUsernameForWallet(String walletAddress);

  /// Inverse lookup: find the wallet address that most recently claimed
  /// [username] on-chain. Returns null if no on-chain set_username call
  /// matches. Used by the username search bar so users can find each other
  /// across devices even when the off-chain indexer hasn't ingested the
  /// claim yet (chain-as-source-of-truth, indexer-as-cache).
  Future<String?> fetchWalletForUsername(String username);
  Future<void> waitForConfirmation(
    String txSignature, {
    Duration timeout = const Duration(seconds: 60),
  });

  /// Publish ML-KEM-512 public key on-chain for quantum-resistant key exchange.
  Future<String> publishPqPublicKey(Uint8List pqPubkey);

  /// Send raw note/memo bytes (used for KEM handshake and PQ key publication).
  Future<String> sendRawNote({
    required String recipientWallet,
    required Uint8List note,
  });

  /// Fetch raw on-chain notes (all note types: KEM_INIT, SEALED_PQ, etc.).
  /// Returns a list of maps with keys:
  ///   'noteBytes' (Uint8List), 'senderAddress' (String), 'txId' (String),
  ///   'timestamp' (int, Unix seconds).
  /// Used by MessageService to process KEM handshakes and PQ key publications.
  Future<List<Map<String, dynamic>>> fetchRawNotes({
    int? sinceTimestamp,
    int limit = 200,
  });
}
