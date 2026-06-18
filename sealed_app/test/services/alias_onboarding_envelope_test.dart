/// T2 — createInvitationEnvelope unit tests.
///
/// Uses the real [CryptoService].
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/features/messaging/alias/alias_envelope.dart';
import 'package:sealed_app/features/messaging/alias/alias_key_service.dart';
import 'package:sealed_app/features/messaging/alias/alias_onboarding_service.dart';
import 'package:sealed_app/features/messaging/alias/combined_qr_codec.dart';
import 'package:sealed_app/features/messaging/alias/offline_handshake_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../local/repositories/test_db.dart';

// ---------------------------------------------------------------------------
// Real CryptoService factory
// ---------------------------------------------------------------------------

CryptoService _crypto() => CryptoService(
  x25519: X25519(),
  hkdf: Hkdf(hmac: Hmac(Sha256()), outputLength: 32),
  aesGcm: AesGcm.with256bits(),
  hmac: Hmac(Sha256()),
);

// ---------------------------------------------------------------------------
// In-memory SecureStorage
// ---------------------------------------------------------------------------

class _MemStorage extends FlutterSecureStorage {
  final _map = <String, String>{};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _map[key] = value ?? '';

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _map[key];

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _map.remove(key);

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.of(_map);
}

// ---------------------------------------------------------------------------
// Counting chain gateway
// ---------------------------------------------------------------------------

class _CountingGateway implements AliasChainGateway {
  int sendCount = 0;

  @override
  String? get myWalletAddress => 'TEST_WALLET';

  @override
  Future<void> sendNote({
    required Uint8List recipientTag,
    required Uint8List ciphertext,
  }) async => sendCount++;

  @override
  Future<List<Map<String, dynamic>>> fetchNotesFromSender(String s) async => [];

  @override
  Future<List<Map<String, dynamic>>> fetchOwnNotes() async => [];

  @override
  Future<List<Map<String, dynamic>>> fetchAllNotes() async => [];
}

// ---------------------------------------------------------------------------
// Test environment builder
// ---------------------------------------------------------------------------

typedef _Env = ({
  AliasOnboardingService service,
  AliasKeyService keyService,
  ContactRepositoryImpl repo,
  TestLocalDatabase db,
  _CountingGateway gateway,
});

Future<_Env> _buildEnv() async {
  sqfliteFfiInit();
  final db = await TestLocalDatabase.open();
  final repo = ContactRepositoryImpl(db);
  final keyService = AliasKeyService(storage: _MemStorage(), x25519: X25519());
  final gateway = _CountingGateway();
  final service = AliasOnboardingService(
    repo: repo,
    keyService: keyService,
    cryptoService: _crypto(),
    chain: gateway,
  );
  return (
    service: service,
    keyService: keyService,
    repo: repo,
    db: db,
    gateway: gateway,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('T2: createInvitationEnvelope', () {
    test('returns 865-byte invite envelope with tag 0x01', () async {
      final env = await _buildEnv();
      final result = await env.service.createInvitationEnvelope(alias: 'Ghost');

      expect(result.envelopeBytes.length, equals(inviteEnvelopeLength));
      expect(result.envelopeBytes[0], equals(aliasInviteTagByte));

      await env.db.close();
    });

    test('envelope round-trips through AliasInviteEnvelope.tryParse', () async {
      final env = await _buildEnv();
      final result = await env.service.createInvitationEnvelope(alias: 'Ghost');

      final parsed = AliasInviteEnvelope.tryParse(result.envelopeBytes);
      expect(parsed, isNotNull);

      await env.db.close();
    });

    test('saves pending invite row: isCreator=true, status=pending', () async {
      final env = await _buildEnv();
      final result = await env.service.createInvitationEnvelope(alias: 'Ghost');

      final pending = await env.repo.getPendingInvite(result.inviteRef);
      expect(pending, isNotNull);
      expect(pending!.isCreator, isTrue);
      expect(pending.status, equals('pending'));
      expect(pending.aliasDisplay, equals('Ghost'));

      await env.db.close();
    });

    test('temp X25519 keys retrievable by inviteRef', () async {
      final env = await _buildEnv();
      final result = await env.service.createInvitationEnvelope(alias: 'Ghost');

      final keys = await env.keyService.loadTempKeyPairByRef(result.inviteRef);
      expect(keys, isNotNull);
      expect(keys!.enc.publicKey.length, equals(32));
      expect(keys.scan.publicKey.length, equals(32));

      await env.db.close();
    });

    test('temp PQ private key retrievable by inviteRef', () async {
      final env = await _buildEnv();
      final result = await env.service.createInvitationEnvelope(alias: 'Ghost');

      final pqPriv = await env.keyService.loadTempPqPrivateKeyByRef(
        result.inviteRef,
      );
      expect(pqPriv, isNotNull);

      await env.db.close();
    });

    test('envelope encPub/scanPub match stored temp keys', () async {
      final env = await _buildEnv();
      final result = await env.service.createInvitationEnvelope(alias: 'Ghost');

      final parsed = AliasInviteEnvelope.tryParse(result.envelopeBytes)!;
      final keys = (await env.keyService.loadTempKeyPairByRef(
        result.inviteRef,
      ))!;

      expect(parsed.encPub, equals(keys.enc.publicKey));
      expect(parsed.scanPub, equals(keys.scan.publicKey));

      await env.db.close();
    });

    test('inviteRef = sha256hex(encPub||scanPub||pqPub)', () async {
      final env = await _buildEnv();
      final result = await env.service.createInvitationEnvelope(alias: 'Ghost');

      final parsed = AliasInviteEnvelope.tryParse(result.envelopeBytes)!;
      final combined = Uint8List.fromList([
        ...parsed.encPub,
        ...parsed.scanPub,
        ...parsed.pqPub,
      ]);
      final hash = await Sha256().hash(combined);
      final expected = hash.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      expect(result.inviteRef, equals(expected));

      await env.db.close();
    });

    test('no on-chain write (sendNote never called)', () async {
      final env = await _buildEnv();
      await env.service.createInvitationEnvelope(alias: 'Ghost');
      expect(env.gateway.sendCount, equals(0));

      await env.db.close();
    });

    test('two calls produce distinct inviteRefs', () async {
      final env = await _buildEnv();
      final r1 = await env.service.createInvitationEnvelope(alias: 'A');
      final r2 = await env.service.createInvitationEnvelope(alias: 'B');
      expect(r1.inviteRef, isNot(equals(r2.inviteRef)));

      await env.db.close();
    });
  });

  // ---------------------------------------------------------------------------
  // T3 + T4: full envelope round-trip
  // ---------------------------------------------------------------------------

  group('T3+T4: envelope round-trip (creator ↔ acceptor)', () {
    late _Env creator;
    late _Env acceptor;

    setUp(() async {
      creator = await _buildEnv();
      acceptor = await _buildEnv();
    });

    tearDown(() async {
      await creator.db.close();
      await acceptor.db.close();
    });

    test('sharedSecret identical on both sides', () async {
      // Creator builds invite envelope.
      final inviteResult = await creator.service.createInvitationEnvelope(
        alias: 'Anon',
      );
      final inviteEnv = AliasInviteEnvelope.tryParse(
        inviteResult.envelopeBytes,
      )!;

      // Acceptor processes invite, gets accept envelope.
      final acceptResult = await acceptor.service.acceptInvitationFromEnvelope(
        env: inviteEnv,
        alias: 'Creator',
      );
      expect(
        acceptResult.acceptEnvelopeBytes.length,
        equals(acceptEnvelopeLength),
      );
      expect(acceptResult.acceptEnvelopeBytes[0], equals(aliasAcceptTagByte));

      // Creator processes accept envelope.
      final acceptEnv = AliasAcceptEnvelope.tryParse(
        acceptResult.acceptEnvelopeBytes,
      )!;
      final creatorContact = await creator.service.completeFromAcceptEnvelope(
        acceptEnv,
      );

      expect(creatorContact, isNotNull);
      expect(
        creatorContact!.keys.sharedSecret,
        equals(acceptResult.contact.keys.sharedSecret),
      );
    });

    test('recipientTag identical on both sides', () async {
      final inviteResult = await creator.service.createInvitationEnvelope(
        alias: 'Anon',
      );
      final inviteEnv = AliasInviteEnvelope.tryParse(
        inviteResult.envelopeBytes,
      )!;
      final acceptResult = await acceptor.service.acceptInvitationFromEnvelope(
        env: inviteEnv,
        alias: 'Creator',
      );
      final acceptEnv = AliasAcceptEnvelope.tryParse(
        acceptResult.acceptEnvelopeBytes,
      )!;
      final creatorContact = await creator.service.completeFromAcceptEnvelope(
        acceptEnv,
      );

      expect(
        creatorContact!.keys.recipientTag,
        equals(acceptResult.contact.keys.recipientTag),
      );
    });

    test('msgKey identical on both sides', () async {
      final inviteResult = await creator.service.createInvitationEnvelope(
        alias: 'Anon',
      );
      final inviteEnv = AliasInviteEnvelope.tryParse(
        inviteResult.envelopeBytes,
      )!;
      final acceptResult = await acceptor.service.acceptInvitationFromEnvelope(
        env: inviteEnv,
        alias: 'Creator',
      );
      final acceptEnv = AliasAcceptEnvelope.tryParse(
        acceptResult.acceptEnvelopeBytes,
      )!;
      final creatorContact = await creator.service.completeFromAcceptEnvelope(
        acceptEnv,
      );

      expect(
        creatorContact!.keys.msgKey,
        equals(acceptResult.contact.keys.msgKey),
      );
    });

    test('pqSharedSecret identical on both sides', () async {
      final inviteResult = await creator.service.createInvitationEnvelope(
        alias: 'Anon',
      );
      final inviteEnv = AliasInviteEnvelope.tryParse(
        inviteResult.envelopeBytes,
      )!;
      final acceptResult = await acceptor.service.acceptInvitationFromEnvelope(
        env: inviteEnv,
        alias: 'Creator',
      );
      final acceptEnv = AliasAcceptEnvelope.tryParse(
        acceptResult.acceptEnvelopeBytes,
      )!;
      final creatorContact = await creator.service.completeFromAcceptEnvelope(
        acceptEnv,
      );

      expect(
        creatorContact!.keys.pqSharedSecret,
        equals(acceptResult.contact.keys.pqSharedSecret),
      );
    });

    test(
      '_findDiscoveryNote never called (no on-chain write either side)',
      () async {
        final inviteResult = await creator.service.createInvitationEnvelope(
          alias: 'Anon',
        );
        final inviteEnv = AliasInviteEnvelope.tryParse(
          inviteResult.envelopeBytes,
        )!;
        final acceptResult = await acceptor.service
            .acceptInvitationFromEnvelope(env: inviteEnv, alias: 'Creator');
        final acceptEnv = AliasAcceptEnvelope.tryParse(
          acceptResult.acceptEnvelopeBytes,
        )!;
        await creator.service.completeFromAcceptEnvelope(acceptEnv);

        // Neither side calls chain.sendNote in envelope flow.
        expect(creator.gateway.sendCount, equals(0));
        expect(acceptor.gateway.sendCount, equals(0));
      },
    );

    test(
      'creator contact is isCreator=true, acceptor is isCreator=false',
      () async {
        final inviteResult = await creator.service.createInvitationEnvelope(
          alias: 'Anon',
        );
        final inviteEnv = AliasInviteEnvelope.tryParse(
          inviteResult.envelopeBytes,
        )!;
        final acceptResult = await acceptor.service
            .acceptInvitationFromEnvelope(env: inviteEnv, alias: 'Creator');
        final acceptEnv = AliasAcceptEnvelope.tryParse(
          acceptResult.acceptEnvelopeBytes,
        )!;
        final creatorContact = await creator.service.completeFromAcceptEnvelope(
          acceptEnv,
        );

        expect(creatorContact!.isCreator, isTrue);
        expect(acceptResult.contact.isCreator, isFalse);
      },
    );

    test(
      'completeFromAcceptEnvelope idempotent: repeat call returns same contact',
      () async {
        final inviteResult = await creator.service.createInvitationEnvelope(
          alias: 'Anon',
        );
        final inviteEnv = AliasInviteEnvelope.tryParse(
          inviteResult.envelopeBytes,
        )!;
        final acceptResult = await acceptor.service
            .acceptInvitationFromEnvelope(env: inviteEnv, alias: 'Creator');
        final acceptEnv = AliasAcceptEnvelope.tryParse(
          acceptResult.acceptEnvelopeBytes,
        )!;
        final first = await creator.service.completeFromAcceptEnvelope(
          acceptEnv,
        );
        final second = await creator.service.completeFromAcceptEnvelope(
          acceptEnv,
        );

        expect(first, isNotNull);
        expect(second!.contactId, equals(first!.contactId));
      },
    );

    test(
      'acceptInvitationFromEnvelope idempotent: repeat returns same contact, empty bytes',
      () async {
        final inviteResult = await creator.service.createInvitationEnvelope(
          alias: 'Anon',
        );
        final inviteEnv = AliasInviteEnvelope.tryParse(
          inviteResult.envelopeBytes,
        )!;
        final first = await acceptor.service.acceptInvitationFromEnvelope(
          env: inviteEnv,
          alias: 'Creator',
        );
        final second = await acceptor.service.acceptInvitationFromEnvelope(
          env: inviteEnv,
          alias: 'Creator',
        );

        expect(first.contact.contactId, equals(second.contact.contactId));
        expect(second.acceptEnvelopeBytes.length, equals(0));
      },
    );

    test(
      'completeFromAcceptEnvelope returns null for unknown prefix',
      () async {
        final fakeEnv = AliasAcceptEnvelope(
          inviteRefPrefix: Uint8List(8), // all zeros — no matching invite
          encPub: Uint8List(32),
          scanPub: Uint8List(32),
          kemCiphertext: Uint8List(768),
        );
        final result = await creator.service.completeFromAcceptEnvelope(
          fakeEnv,
        );
        expect(result, isNull);
      },
    );

    test('creator temp keys erased after completeFromAcceptEnvelope', () async {
      final inviteResult = await creator.service.createInvitationEnvelope(
        alias: 'Anon',
      );
      final inviteEnv = AliasInviteEnvelope.tryParse(
        inviteResult.envelopeBytes,
      )!;
      final acceptResult = await acceptor.service.acceptInvitationFromEnvelope(
        env: inviteEnv,
        alias: 'Creator',
      );
      final acceptEnv = AliasAcceptEnvelope.tryParse(
        acceptResult.acceptEnvelopeBytes,
      )!;
      await creator.service.completeFromAcceptEnvelope(acceptEnv);

      final keys = await creator.keyService.loadTempKeyPairByRef(
        inviteResult.inviteRef,
      );
      final pqPriv = await creator.keyService.loadTempPqPrivateKeyByRef(
        inviteResult.inviteRef,
      );
      expect(keys, isNull);
      expect(pqPriv, isNull);
    });
  });

  group('recordIncomingInvite (receiver pending row)', () {
    // Creator builds an envelope; a SEPARATE receiver env records it — mirrors
    // two devices so the creator's own pending row doesn't mask the receiver's.
    Future<AliasInviteEnvelope> _inviteFrom(_Env creator) async {
      final r = await creator.service.createInvitationEnvelope(alias: 'Ghost');
      return AliasInviteEnvelope.tryParse(r.envelopeBytes)!;
    }

    test('records a non-creator pending row labeled by sender', () async {
      final creator = await _buildEnv();
      final receiver = await _buildEnv();
      final env = await _inviteFrom(creator);

      final ref = await receiver.service.recordIncomingInvite(
        env: env,
        senderWallet: 'SENDER_WALLET',
      );

      final pending = await receiver.repo.getAllPendingInvites();
      expect(pending.length, 1);
      expect(pending.single.inviteRef, ref);
      expect(pending.single.isCreator, isFalse);
      expect(pending.single.status, 'pending');
      expect(pending.single.aliasDisplay, 'SENDER_WALLET');

      await creator.db.close();
      await receiver.db.close();
    });

    test('idempotent: second record does not duplicate', () async {
      final creator = await _buildEnv();
      final receiver = await _buildEnv();
      final env = await _inviteFrom(creator);

      await receiver.service.recordIncomingInvite(env: env, senderWallet: 'S');
      await receiver.service.recordIncomingInvite(env: env, senderWallet: 'S');

      expect((await receiver.repo.getAllPendingInvites()).length, 1);
      await creator.db.close();
      await receiver.db.close();
    });

    test('declined invite is not resurrected on re-record', () async {
      final creator = await _buildEnv();
      final receiver = await _buildEnv();
      final env = await _inviteFrom(creator);

      final ref = await receiver.service.recordIncomingInvite(
        env: env,
        senderWallet: 'S',
      );
      await receiver.repo.markInviteDismissed(ref);
      // Simulates a forceResync re-delivering the same envelope.
      await receiver.service.recordIncomingInvite(env: env, senderWallet: 'S');

      final pending = await receiver.repo.getAllPendingInvites();
      expect(pending.length, 1);
      expect(pending.single.inviteDismissed, isTrue);
      await creator.db.close();
      await receiver.db.close();
    });

    test('already-accepted invite records no pending row', () async {
      final creator = await _buildEnv();
      final receiver = await _buildEnv();
      final env = await _inviteFrom(creator);

      // Accept first (promotes to a contact), then a late re-delivery arrives.
      await receiver.service.acceptInvitationFromEnvelope(
        env: env,
        alias: 'Creator',
      );
      await receiver.service.recordIncomingInvite(env: env, senderWallet: 'S');

      expect(await receiver.repo.getAllPendingInvites(), isEmpty);
      await creator.db.close();
      await receiver.db.close();
    });
  });

  group('discardPendingInvite', () {
    test(
      'erases temp keys + deletes pending row for an unused invite',
      () async {
        final env = await _buildEnv();
        final result = await env.service.createInvitationEnvelope(
          alias: 'Ghost',
        );

        // Sanity: minted.
        expect(await env.repo.getPendingInvite(result.inviteRef), isNotNull);
        expect(
          await env.keyService.loadTempKeyPairByRef(result.inviteRef),
          isNotNull,
        );

        await env.service.discardPendingInvite(result.inviteRef);

        expect(await env.repo.getPendingInvite(result.inviteRef), isNull);
        expect(
          await env.keyService.loadTempKeyPairByRef(result.inviteRef),
          isNull,
        );
        expect(
          await env.keyService.loadTempPqPrivateKeyByRef(result.inviteRef),
          isNull,
        );

        await env.db.close();
      },
    );

    test('never throws for an unknown inviteRef', () async {
      final env = await _buildEnv();
      await env.service.discardPendingInvite('deadbeef' * 8);
      await env.db.close();
    });

    test('is a no-op once the invite has been promoted to a contact', () async {
      final creator = await _buildEnv();
      final acceptor = await _buildEnv();

      final inviteResult = await creator.service.createInvitationEnvelope(
        alias: 'Anon',
      );
      final inviteEnv = AliasInviteEnvelope.tryParse(
        inviteResult.envelopeBytes,
      )!;
      final acceptResult = await acceptor.service.acceptInvitationFromEnvelope(
        env: inviteEnv,
        alias: 'Creator',
      );
      final acceptEnv = AliasAcceptEnvelope.tryParse(
        acceptResult.acceptEnvelopeBytes,
      )!;
      final contact = await creator.service.completeFromAcceptEnvelope(
        acceptEnv,
      );
      expect(contact, isNotNull);

      // Discard must NOT tear down a completed handshake.
      await creator.service.discardPendingInvite(inviteResult.inviteRef);
      expect(await creator.repo.getAliasContact(contact!.contactId), isNotNull);

      await creator.db.close();
      await acceptor.db.close();
    });
  });

  group('instant-invite e2e (combined QR transport, fully offline)', () {
    // Reassemble a payload by framing it through the multi-frame codec and
    // feeding every frame into a fresh accumulator — exactly the camera path.
    Future<Uint8List> roundTripFrames(Uint8List payload) async {
      final frames = await OfflineHandshakeCodec.encode(payload);
      final acc = OfflineHandshakeCodec.decoder();
      Uint8List? out;
      for (final f in frames) {
        out = acc.feed(f) ?? out;
      }
      return out!;
    }

    test(
      'combined QR → accept → scan-back completes; zero chain writes',
      () async {
        final creator = await _buildEnv(); // displayer (My QR)
        final acceptor = await _buildEnv(); // scanner (chats QR)
        const creatorAddress =
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB';

        // 1. Creator mints an invite and shows it as a combined QR.
        final invite = await creator.service.createInvitationEnvelope(
          alias: 'Anon',
        );
        final combined = encodeCombinedQr(
          address: creatorAddress,
          inviteEnvelope: invite.envelopeBytes,
        );

        // 2. Acceptor scans the combined QR (multi-frame) and decodes it.
        final decoded = decodeCombinedQr(await roundTripFrames(combined));
        expect(decoded, isNotNull);
        expect(decoded!.address, equals(creatorAddress));
        final inviteEnv = AliasInviteEnvelope.tryParse(decoded.inviteEnvelope)!;

        // 3. Acceptor derives keys + produces the accept envelope (shown as QR).
        final accept = await acceptor.service.acceptInvitationFromEnvelope(
          env: inviteEnv,
          alias: 'alias_partner',
        );

        // 4. Creator scans the accept QR back (multi-frame) and completes.
        final acceptEnv = AliasAcceptEnvelope.tryParse(
          await roundTripFrames(accept.acceptEnvelopeBytes),
        )!;
        final creatorContact = await creator.service.completeFromAcceptEnvelope(
          acceptEnv,
        );

        // Both sides agree on the shared secret + recipient tag.
        expect(creatorContact, isNotNull);
        expect(
          creatorContact!.keys.sharedSecret,
          equals(accept.contact.keys.sharedSecret),
        );
        expect(
          creatorContact.keys.recipientTag,
          equals(accept.contact.keys.recipientTag),
        );

        // Fully offline: not a single chain note on either side.
        expect(creator.gateway.sendCount, equals(0));
        expect(acceptor.gateway.sendCount, equals(0));

        await creator.db.close();
        await acceptor.db.close();
      },
    );

    test(
      'a second handshake from a fresh invite yields a distinct contact',
      () async {
        final creator = await _buildEnv();
        final acceptorA = await _buildEnv();
        final acceptorB = await _buildEnv();

        Future<String> runOnce(_Env acceptor) async {
          final invite = await creator.service.createInvitationEnvelope(
            alias: 'Anon',
          );
          final inviteEnv = AliasInviteEnvelope.tryParse(invite.envelopeBytes)!;
          final accept = await acceptor.service.acceptInvitationFromEnvelope(
            env: inviteEnv,
            alias: 'partner',
          );
          final acceptEnv = AliasAcceptEnvelope.tryParse(
            accept.acceptEnvelopeBytes,
          )!;
          final contact = await creator.service.completeFromAcceptEnvelope(
            acceptEnv,
          );
          return contact!.contactId;
        }

        final idA = await runOnce(acceptorA);
        final idB = await runOnce(acceptorB);
        expect(
          idA,
          isNot(equals(idB)),
        ); // rotation → unlinkable, distinct chats

        await creator.db.close();
        await acceptorA.db.close();
        await acceptorB.db.close();
      },
    );
  });
}
