import 'package:dio/dio.dart';
import 'package:sealed_app/core/log.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/features/wallet/credits_service.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/features/wallet/sealed_credit_ops.dart';
import 'package:sealed_app/features/wallet/sealed_username_ops.dart';
import 'package:sealed_app/features/wallet/treasury_escrow_program.dart';
import 'package:sealed_app/infra/network/ohttp/ohttp_interceptor.dart';
import 'package:sealed_app/infra/zk/snark_prover.dart';
import 'package:sealed_app/providers/indexer_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';

// ============================================================================
// SEALED CHAIN CLIENT (unified contract — sendMessage / publishPqKey)
// ============================================================================

final sealedChainClientProvider = FutureProvider<SealedChainClient>((
  ref,
) async {
  final wallet = await ref.watch(algorandWalletProvider.future);
  final escrow = buildTreasuryEscrowSigner();

  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );
  dio.interceptors.add(OhttpInterceptor.algo());

  return SealedChainClient(
    sealedAppId: SEALED_APP_ID,
    algodUrl: ALGO_ALGOD_URL,
    indexerUrl: ALGO_INDEXER_URL,
    wallet: wallet,
    escrow: escrow,
    dio: dio,
  );
});

// ============================================================================
// CREDITS + USERNAME OPS (unified Sealed SC)
// ============================================================================

/// Credit ops binding (cache + redeem) for the unified Sealed contract.
final sealedCreditOpsProvider = FutureProvider<SealedCreditChainOps>((
  ref,
) async {
  final chain = await ref.watch(sealedChainClientProvider.future);
  return SealedCreditChainOps(chain);
});

/// Thin username ops: claim / release / resolve.
final sealedUsernameOpsProvider = FutureProvider<SealedUsernameOps>((
  ref,
) async {
  final chain = await ref.watch(sealedChainClientProvider.future);
  return SealedUsernameOps(chain);
});

/// CreditsService — high-level redeem/getCredits API with code normalize.
///
/// Wired with the SNARK prover + indexer for the SPEC-snark-redeem-B routing
/// (T11). Prover construction can fail on dev hosts without the native lib —
/// in that case we fall back to a legacy-only CreditsService and the SNARK
/// path is silently disabled (legacy path is unaffected).
final creditsServiceProvider = FutureProvider<CreditsService>((ref) async {
  final ops = await ref.watch(sealedCreditOpsProvider.future);
  final indexer = ref.watch(indexerClientProvider);

  SnarkProver? prover;
  try {
    prover = SnarkProver.platform();
  } catch (_) {
    // Native lib not loaded (e.g. desktop dev host without build) —
    // legacy-only mode. Log only the high-level decision.
    Log.d(
      '[chain_provider] CreditsService: SNARK prover unavailable, legacy-only',
    );
    prover = null;
  }

  return CreditsService(
    ops,
    prover: prover,
    indexer: indexer,
    loadAsset: (key) async {
      final data = await rootBundle.load(key);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    },
  );
});

/// Live credit balance for the current wallet. UI surface for top-up + settings.
///
/// Resolves to 0 when no wallet exists or no `w:` UserState box has been
/// created yet (pre-first-redeem). Invalidate after redeem / sendMessage /
/// publishKeys to force a refetch.
final creditsBalanceProvider = FutureProvider<int>((ref) async {
  final walletState = await ref.watch(walletProvider.future);
  final address = walletState.walletAddress;
  if (address == null) return 0;
  final chain = await ref.watch(sealedChainClientProvider.future);
  return chain.getCredits(address);
});
