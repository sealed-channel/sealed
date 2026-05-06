import 'dart:typed_data';

/// Abstract wallet interface for multi-chain support.
/// Each chain implements this with its own key derivation and signing.
abstract class ChainWallet {
  /// Chain identifier (e.g., 'solana', 'algorand')
  String get chainId;

  /// Current wallet address in chain-native format
  String? get walletAddress;

  /// Whether a wallet has been created/loaded
  bool get hasWallet;

  /// Create a new wallet from a freshly generated mnemonic.
  /// Algorand: 25-word native phrase. Solana (legacy): BIP39.
  Future<void> createWallet();

  /// Restore wallet from an existing recovery phrase.
  /// Algorand accepts either the 25-word Algorand-native phrase or a legacy
  /// 12/24-word BIP39 phrase — see implementation for derivation rules.
  Future<void> restoreWallet(String mnemonic);

  /// Load an existing wallet from secure storage
  Future<void> loadExistingWallet();

  /// Get the raw 32-byte seed for key derivation (X25519 keys)
  /// This MUST return the same bytes regardless of chain — it feeds KeyService
  Future<Uint8List> getSeedBytes();

  /// Get the recovery phrase (Algorand 25-word or legacy BIP39)
  Future<String?> getMnemonic();

  /// Sign raw transaction bytes with the wallet's signing key
  Future<Uint8List> signTransactionBytes(Uint8List txBytes);

  /// Sign a UTF-8 string message (for auth/registration)
  Future<Uint8List> signMessage(String message);

  /// Get wallet balance in the chain's smallest unit (lamports, microAlgos)
  Future<int> getBalance();

  /// Delete wallet from secure storage
  Future<void> deleteWallet();
}
