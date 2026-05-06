import 'package:bip39/bip39.dart' as bip39;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sealed_app/chain/algorand_chain_client.dart';
import 'package:sealed_app/chain/algorand_wallet_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-app TestNet faucet that sends 1 ALGO to a user's wallet, rate-limited
/// to once per 24 hours per address.
///
/// The faucet uses its OWN isolated wallet (in-memory only — never persisted
/// to secure storage), so it cannot interfere with the user's wallet.
///
/// ⚠️ TODO(faucet): Replace [_faucetMnemonic] with the 25-word BIP39 mnemonic
/// of a TestNet wallet you have funded. The placeholder below WILL NOT WORK
/// until replaced. Generate a wallet via the official AlgoKit faucet, fund
/// it with ~50–100 test ALGO, and paste its mnemonic here. NEVER use a
/// MainNet wallet — this constant ships in the binary.
class FaucetService {
  // ──────────────────────────────────────────────────────────────────────────
  // ⚠️ REPLACE BEFORE TESTING.
  // 25-word BIP39 mnemonic of the TestNet faucet source wallet.
  // Must hold testnet ALGO. Will be packaged with the app — TestNet keys only.
  // ──────────────────────────────────────────────────────────────────────────
  static const String _faucetMnemonic =
      'crucial found vintage movie near coconut bubble puzzle sentence tool limb tip young rain tennis sheriff bounce marine doctor castle lamp brief pool elder';

  /// Amount sent per claim (1 ALGO = 1,000,000 microALGOs).
  static const int _claimMicroAlgos = 1_000_000;

  /// Per-address cooldown.
  static const Duration _cooldown = Duration(hours: 24);

  /// SharedPreferences key prefix for last-claim timestamps.
  static const String _claimKeyPrefix = 'faucet_last_claim_';

  _InMemoryAlgorandWallet? _wallet;
  AlgorandChainClient? _client;

  bool get isConfigured =>
      _faucetMnemonic != 'TODO_REPLACE_WITH_25_WORD_TESTNET_FAUCET_MNEMONIC' &&
      bip39.validateMnemonic(_faucetMnemonic);

  /// Lazily build the in-memory faucet wallet + chain client.
  Future<AlgorandChainClient> _ensureClient() async {
    if (_client != null) return _client!;
    if (!isConfigured) {
      throw const FaucetNotConfiguredException();
    }
    final wallet = _InMemoryAlgorandWallet();
    await wallet.restoreWallet(_faucetMnemonic);
    print('Faucet wallet address: ${wallet.walletAddress}');
    _wallet = wallet;
    _client = AlgorandChainClient.paymentOnly(wallet: wallet);
    return _client!;
  }

  /// Whether [address] is eligible to claim now.
  Future<bool> canClaim(String address) async {
    final last = await _readLastClaim(address);
    if (last == null) return true;
    return DateTime.now().difference(last) >= _cooldown;
  }

  /// Time until the next claim is allowed for [address], or null if ready now.
  Future<Duration?> timeUntilNextClaim(String address) async {
    final last = await _readLastClaim(address);
    if (last == null) return null;
    final next = last.add(_cooldown);
    final remaining = next.difference(DateTime.now());
    return remaining.isNegative ? null : remaining;
  }

  /// Send 1 ALGO from the faucet wallet to [recipient].
  Future<FaucetClaimResult> claim(String recipient) async {
    print('Faucet claim requested for $recipient');
    // Cooldown gate.
    final remaining = await timeUntilNextClaim(recipient);
    if (remaining != null) {
      return FaucetClaimResult.cooldown(remaining);
    }

    if (!isConfigured) {
      print(
        bip39.validateMnemonic(_faucetMnemonic)
            ? 'Faucet mnemonic is invalid.'
            : 'Faucet mnemonic not configured.',
      );
      return FaucetClaimResult.error(
        'Faucet not configured. Ask the app owner to fund it.',
      );
    }

    try {
      final client = await _ensureClient();
      final txId = await client.sendPayment(
        recipientWallet: recipient,
        microAlgos: _claimMicroAlgos,
      );
      // Record success BEFORE waiting for confirmation — once the tx is
      // submitted, the cooldown should apply even if the user closes the app.
      await _writeLastClaim(recipient);

      // Best-effort confirmation wait — don't fail the claim if it times out.
      // The user's polling loop will pick up the balance change either way.
      // ignore: unawaited_futures
      client
          .waitForConfirmation(txId, timeout: const Duration(seconds: 30))
          .catchError((Object e) {
            debugPrint('⚠️ Faucet: waitForConfirmation soft-failed: $e');
          });

      return FaucetClaimResult.success(txId);
    } on FaucetNotConfiguredException {
      return FaucetClaimResult.error(
        'Faucet not configured. Ask the app owner to fund it.',
      );
    } on DioException catch (e) {
      final msg = _friendlyDioError(e);
      return FaucetClaimResult.error(msg);
    } catch (e) {
      return FaucetClaimResult.error('Faucet claim failed: $e');
    }
  }

  /// Faucet wallet's current balance in ALGO (for health checks / debug).
  Future<double> faucetBalance() async {
    if (!isConfigured) return 0;
    final client = await _ensureClient();
    final addr = _wallet!.walletAddress!;
    final micro = await client.getWalletBalance(addr);
    return micro / 1_000_000;
  }

  /// Reset cooldown for an address (debug only).
  Future<void> resetCooldown(String address) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_claimKeyPrefix$address');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Internals
  // ──────────────────────────────────────────────────────────────────────────

  Future<DateTime?> _readLastClaim(String address) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_claimKeyPrefix$address');
      if (raw == null) return null;
      return DateTime.parse(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeLastClaim(String address) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_claimKeyPrefix$address',
      DateTime.now().toIso8601String(),
    );
  }

  String _friendlyDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return 'Network timed out — please try again.';
      case DioExceptionType.badResponse:
        final status = e.response?.statusCode;
        return 'Faucet error (HTTP $status). Try again later.';
      default:
        return 'Network error: ${e.message ?? 'unknown'}';
    }
  }
}

/// Result of a faucet claim attempt.
class FaucetClaimResult {
  final FaucetClaimStatus status;
  final String? message;
  final String? txId;
  final Duration? cooldownRemaining;

  const FaucetClaimResult._({
    required this.status,
    this.message,
    this.txId,
    this.cooldownRemaining,
  });

  factory FaucetClaimResult.success(String txId) => FaucetClaimResult._(
    status: FaucetClaimStatus.success,
    txId: txId,
    message: '1 ALGO sent successfully',
  );

  factory FaucetClaimResult.cooldown(Duration remaining) => FaucetClaimResult._(
    status: FaucetClaimStatus.cooldown,
    cooldownRemaining: remaining,
    message: 'Try again in ${_formatDuration(remaining)}',
  );

  factory FaucetClaimResult.error(String message) =>
      FaucetClaimResult._(status: FaucetClaimStatus.error, message: message);

  bool get isSuccess => status == FaucetClaimStatus.success;
  bool get isCooldown => status == FaucetClaimStatus.cooldown;
  bool get isError => status == FaucetClaimStatus.error;

  static String _formatDuration(Duration d) {
    if (d.inHours >= 1) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    if (d.inMinutes >= 1) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }
}

enum FaucetClaimStatus { success, cooldown, error }

class FaucetNotConfiguredException implements Exception {
  const FaucetNotConfiguredException();
  @override
  String toString() => 'FaucetNotConfiguredException';
}

// ════════════════════════════════════════════════════════════════════════════
// In-memory wallet — subclasses AlgorandWallet so it satisfies the chain
// client's static type, but uses an in-memory FlutterSecureStorage stub
// instead of the real platform keystore. This guarantees the faucet's
// mnemonic NEVER overwrites the user's `algo_mnemonic` keystore entry.
// ════════════════════════════════════════════════════════════════════════════
class _InMemoryAlgorandWallet extends AlgorandWallet {
  _InMemoryAlgorandWallet() : super(_NoopSecureStorage());
}

/// FlutterSecureStorage stub that ignores all writes and returns null reads.
/// Used to keep the faucet wallet ephemeral — nothing ever hits the keystore.
class _NoopSecureStorage implements FlutterSecureStorage {
  // Backing in-memory map so multiple reads/writes within the same session
  // remain self-consistent (although AlgorandWallet only writes once anyway).
  final Map<String, String> _mem = {};

  @override
  AndroidOptions get aOptions => const AndroidOptions();
  @override
  IOSOptions get iOptions => const IOSOptions();
  @override
  LinuxOptions get lOptions => const LinuxOptions();
  @override
  MacOsOptions get mOptions => const MacOsOptions();
  @override
  WindowsOptions get wOptions => const WindowsOptions();
  @override
  WebOptions get webOptions => const WebOptions();

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _mem[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _mem.remove(key);
    } else {
      _mem[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _mem.remove(key);
  }

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _mem.clear();
  }

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.of(_mem);

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _mem.containsKey(key);

  // Other interface methods we don't use — provide minimal defaults.
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
