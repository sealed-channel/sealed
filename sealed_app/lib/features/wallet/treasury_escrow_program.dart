/// Compiled TEAL bytes for the `TreasuryEscrow` LogicSig.
///
/// Source: `programs/sealed/out/TreasuryEscrow.teal` compiled via algod
/// (`/v2/teal/compile`) on TestNet. The output is deterministic — see the
/// golden-vector check in `test/chain/treasury_escrow_signer_test.dart`
/// (same b64 string is exercised there).
///
/// Inlining the bytes keeps app boot free of an algod round-trip and avoids
/// shipping `.teal` source as a runtime asset.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sealed_app/features/wallet/treasury_escrow_signer.dart';

const String kTreasuryEscrowProgramB64 =
    'CzEQgQESQQA3MQcxABJBAC8xCEAAKjEBgZChDw5BACAxIDIDEkEAGDEJMgMSQQAQMRZAAAsyBIECEkEAA4EBQ4EAQw==';

/// Singleton signer derived from the inlined compiled bytes. Cheap to
/// build (one sha512_256 + base32 encode) but the result is cached.
TreasuryEscrowSigner? _cached;
TreasuryEscrowSigner buildTreasuryEscrowSigner() {
  return _cached ??= TreasuryEscrowSigner(
    Uint8List.fromList(base64.decode(kTreasuryEscrowProgramB64)),
  );
}
