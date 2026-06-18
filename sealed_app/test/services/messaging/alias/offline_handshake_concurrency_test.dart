// /// T8 — Concurrent offline handshake safety.
// ///
// /// Single creator device juggles TWO pending invites (A, B) simultaneously.
// /// Two separate acceptor devices (X, Y) each produce one accept envelope.
// /// We route the envelopes through the multi-frame QR codec — same transport
// /// the production screen uses — and feed them back into the creator in
// /// mixed order via `completeFromAcceptEnvelope`.
// ///
// /// Invariants under test:
// ///   1. Accept from X resolves only Invite A's contact (matching
// ///      sharedSecret with X's locally promoted contact).
// ///   2. Accept from Y resolves only Invite B's contact (matching
// ///      sharedSecret with Y's locally promoted contact).
// ///   3. No cross-promotion: the contact resolved for A must not match Y's
// ///      sharedSecret and vice versa.
// ///   4. An accept envelope that points at no pending invite returns null —
// ///      no exception, no partial state.
// ///   5. Zero `AliasChainGateway.sendNote` calls on any device.
// ///
// /// All transport goes through `OfflineHandshakeCodec` to mirror the screen.
// library;

// import 'dart:typed_data';

// import 'package:flutter_test/flutter_test.dart';
// import 'package:sealed_app/features/qr/offline_handshake_codec.dart';
// import 'package:sealed_app/services/alias_envelope.dart';

// import '../../../support/alias_onboarding_env.dart';

// /// Round-trip [bytes] through the multi-frame QR codec. Encodes, then feeds
// /// every frame into a fresh accumulator and returns the reassembled bytes.
// Future<Uint8List> _roundTripCodec(Uint8List bytes) async {
//   final frames = await OfflineHandshakeCodec.encode(bytes);
//   final acc = OfflineHandshakeCodec.decoder();
//   Uint8List? out;
//   for (final f in frames) {
//     out = acc.feed(f);
//     if (out != null) break;
//   }
//   expect(out, isNotNull, reason: 'codec accumulator did not complete');
//   return out!;
// }

// void main() {
//   group('T8: concurrent offline handshakes on one creator device', () {
//     late TestAliasEnv creator;
//     late TestAliasEnv acceptorX;
//     late TestAliasEnv acceptorY;

//     setUp(() async {
//       creator = await buildTestAliasEnv();
//       acceptorX = await buildTestAliasEnv();
//       acceptorY = await buildTestAliasEnv();
//     });

//     tearDown(() async {
//       await creator.db.close();
//       await acceptorX.db.close();
//       await acceptorY.db.close();
//     });

//     test('two pending invites resolve to distinct contacts without cross-promotion',
//         () async {
//       // Creator opens two pending invites back-to-back.
//       final inviteA =
//           await creator.service.createInvitationEnvelope(alias: 'Friend-A');
//       final inviteB =
//           await creator.service.createInvitationEnvelope(alias: 'Friend-B');
//       expect(inviteA.inviteRef, isNot(equals(inviteB.inviteRef)));

//       // Each acceptor receives one invite over the QR transport.
//       final inviteABytesRx = await _roundTripCodec(inviteA.envelopeBytes);
//       final inviteBBytesRx = await _roundTripCodec(inviteB.envelopeBytes);
//       final inviteAEnv = AliasInviteEnvelope.tryParse(inviteABytesRx);
//       final inviteBEnv = AliasInviteEnvelope.tryParse(inviteBBytesRx);
//       expect(inviteAEnv, isNotNull);
//       expect(inviteBEnv, isNotNull);

//       final acceptA = await acceptorX.service.acceptInvitationFromEnvelope(
//         env: inviteAEnv!,
//         alias: 'Creator-from-X',
//       );
//       final acceptB = await acceptorY.service.acceptInvitationFromEnvelope(
//         env: inviteBEnv!,
//         alias: 'Creator-from-Y',
//       );

//       // Round-trip accept envelopes back through QR transport.
//       final acceptABytesRx =
//           await _roundTripCodec(acceptA.acceptEnvelopeBytes);
//       final acceptBBytesRx =
//           await _roundTripCodec(acceptB.acceptEnvelopeBytes);
//       final acceptAEnv = AliasAcceptEnvelope.tryParse(acceptABytesRx);
//       final acceptBEnv = AliasAcceptEnvelope.tryParse(acceptBBytesRx);
//       expect(acceptAEnv, isNotNull);
//       expect(acceptBEnv, isNotNull);

//       // Creator completes in mixed order: B first, then A. The
//       // `inviteRefPrefix` invariant should still route each to the right
//       // pending row.
//       final contactForB =
//           await creator.service.completeFromAcceptEnvelope(acceptBEnv!);
//       final contactForA =
//           await creator.service.completeFromAcceptEnvelope(acceptAEnv!);

//       expect(contactForA, isNotNull, reason: 'invite A must resolve');
//       expect(contactForB, isNotNull, reason: 'invite B must resolve');

//       // Each side resolved to a distinct contact.
//       expect(contactForA!.contactId, isNot(equals(contactForB!.contactId)));

//       // Cryptographic invariant: creator's contact for A must match X's
//       // shared secret, NOT Y's. Same for B / Y.
//       expect(
//         contactForA.keys.sharedSecret,
//         equals(acceptA.contact.keys.sharedSecret),
//         reason: 'creator contact A == acceptor X contact (matching ss)',
//       );
//       expect(
//         contactForB.keys.sharedSecret,
//         equals(acceptB.contact.keys.sharedSecret),
//         reason: 'creator contact B == acceptor Y contact (matching ss)',
//       );

//       // Cross-check: no promotion of A's contact against Y's secret.
//       expect(
//         contactForA.keys.sharedSecret,
//         isNot(equals(acceptB.contact.keys.sharedSecret)),
//         reason: 'no cross-promotion of A into Y',
//       );
//       expect(
//         contactForB.keys.sharedSecret,
//         isNot(equals(acceptA.contact.keys.sharedSecret)),
//         reason: 'no cross-promotion of B into X',
//       );

//       // Zero on-chain writes on every device.
//       expect(creator.gateway.sendCount, equals(0));
//       expect(acceptorX.gateway.sendCount, equals(0));
//       expect(acceptorY.gateway.sendCount, equals(0));
//     });

//     test('accept envelope without a matching pending invite returns null, no throw',
//         () async {
//       // Build a real pending invite so the creator has *some* pending state,
//       // but feed it an unrelated accept envelope (all-zero prefix).
//       await creator.service.createInvitationEnvelope(alias: 'Friend-A');

//       final stray = AliasAcceptEnvelope(
//         inviteRefPrefix: Uint8List(8), // no pending row hashes to all-zero
//         encPub: Uint8List(32),
//         scanPub: Uint8List(32),
//         kemCiphertext: Uint8List(768),
//       );

//       final result = await creator.service.completeFromAcceptEnvelope(stray);
//       expect(result, isNull);
//       expect(creator.gateway.sendCount, equals(0));
//     });
//   });
// }
