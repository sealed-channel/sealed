import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sealed_app/core/service_locator.dart';

/// `true` when no KEM-derived shared secret is cached for [walletAddress] —
/// i.e. the next outgoing text triggers a one-time handshake. The chat
/// composer uses this to surface a "first message" credit-cost hint.
final hasCachedPqSecretProvider = FutureProvider.family<bool, String>((
  ref,
  walletAddress,
) async {
  try {
    final repo = ref.watch(contactRepositoryProvider);
    final keys = await repo.getContactKeys(walletAddress);
    return keys.pqSharedSecret != null;
  } catch (_) {
    // Treat unknown as "secret cached" so we don't falsely warn about
    // first-message credit cost when the lookup itself fails.
    return true;
  }
});
