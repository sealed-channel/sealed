import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/models/contact.dart';
import 'package:sealed_app/providers/message_provider.dart'
    show messageRefreshCounterProvider;

/// Cached AliasContact lookup keyed by contactId. Refreshes when the global
/// message refresh counter bumps (so label edits or deletes flow through).
final aliasContactProvider = FutureProvider.family<AliasContact?, String>((
  ref,
  contactId,
) async {
  ref.watch(messageRefreshCounterProvider);
  final repo = ref.watch(contactRepositoryProvider);
  return repo.getAliasContact(contactId);
});
