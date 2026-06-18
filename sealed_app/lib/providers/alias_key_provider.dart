import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sealed_app/core/service_locator.dart';

/// Lazy lookup of an alias contact's scan-private key. Returns null if the
/// key isn't stored for [contactId]. The key bytes are sensitive — consumers
/// should pass them straight into the indexer registration call and never
/// retain them in widget state.
final aliasKeyProvider = FutureProvider.family<Uint8List?, String>((
  ref,
  contactId,
) async {
  final aliasKeys = ref.watch(aliasKeyServiceProvider);
  return aliasKeys.loadAliasScanPrivForContact(contactId);
});
