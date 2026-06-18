import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sealed_app/providers/chain_provider.dart';
import 'package:sealed_app/providers/message_provider.dart'
    show messageRefreshCounterProvider;

/// Address-book surface: manually-added wallet contacts only (is_alias = 0
/// AND is_contact = 1), with the local user filtered out. Messaging a new
/// peer does NOT create a contact entry — the key-cache row it auto-inserts
/// stays invisible here until the user taps "Add to contacts" on the profile.
/// Refreshes when the global message refresh counter bumps (add/remove
/// actions bump it).
///
/// Sourced from [UserProfile] — the public projection (pubkeys only). The
/// private `Contact`/`ContactKeys` relationship record is deliberately kept out
/// of the contacts-list UI layer.
final contactsProvider = FutureProvider<List<UserProfile>>((ref) async {
  ref.watch(messageRefreshCounterProvider);

  final repo = ref.watch(contactRepositoryProvider);
  final contacts = await repo.getManualContacts();

  // Drop self — user_service saves the local profile as a contact row.
  final sealedClient = await ref.watch(sealedChainClientProvider.future);
  final myWallet = sealedClient.wallet.walletAddress;
  final visible = myWallet == null
      ? contacts
      : contacts.where((c) => c.walletAddress != myWallet).toList();

  // Named contacts first (alphabetical, case-insensitive); nameless last.
  String? nameOf(UserProfile p) {
    final n = (p.username?.isNotEmpty == true) ? p.username : p.alias;
    return (n?.isNotEmpty == true) ? n : null;
  }

  visible.sort((a, b) {
    final an = nameOf(a);
    final bn = nameOf(b);
    if (an == null && bn == null) {
      return a.walletAddress.compareTo(b.walletAddress);
    }
    if (an == null) return 1;
    if (bn == null) return -1;
    return an.toLowerCase().compareTo(bn.toLowerCase());
  });

  return visible;
});
