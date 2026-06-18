import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/service_locator.dart'
    show messageRepositoryProvider;
import 'package:sealed_app/features/wallet/algorand_wallet_client.dart';
import 'package:sealed_app/features/wallet/sealed_chain_client.dart';
import 'package:sealed_app/features/wallet/treasury_escrow_signer.dart';
import 'package:sealed_app/infra/local/repositories/message_repository.dart';
import 'package:sealed_app/models/chat_preview.dart';
import 'package:sealed_app/models/message.dart';
import 'package:sealed_app/providers/chain_provider.dart'
    show sealedChainClientProvider;
import 'package:sealed_app/providers/chat_controller.dart';
import 'package:sealed_app/providers/message_provider.dart';

// The wallet-path controller now reads bounded history directly from the
// MessageRepository (with myWallet from the chain client) rather than
// conversationMessagesProvider, so the tests mock the data layer.

class _FakeWallet implements AlgorandWallet {
  @override
  final String? walletAddress;
  _FakeWallet(this.walletAddress);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeEscrow implements TreasuryEscrowSigner {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMessageRepo implements MessageRepository {
  final List<DecryptedMessage> saved;
  _FakeMessageRepo(this.saved);

  @override
  Future<List<DecryptedMessage>> getConversationMessages(
    String walletA,
    String walletB, {
    int? limit,
  }) async => limit == null ? saved : saved.take(limit).toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Minimal fake: avoids MessagesNotifier's heavy build()/timers/network. Records
// sends and can gate / throw to drive optimistic-state assertions.
class _FakeMessagesNotifier extends MessagesNotifier {
  final List<String> sent = [];
  Completer<void>? gate;
  bool throwOnSend = false;

  @override
  Future<List<ChatPreview>> build() async => [];

  @override
  Future<void> sendMessage({
    required String recipientWallet,
    String? recipientUsername,
    required String plaintext,
  }) async {
    sent.add(plaintext);
    if (gate != null) await gate!.future;
    if (throwOnSend) throw StateError('boom');
  }

  @override
  Future<void> markConversationAsRead(String contactWallet) async {}
}

DecryptedMessage _dm(
  String id, {
  required String content,
  bool out = false,
  int minute = 0,
}) => DecryptedMessage(
  id: id,
  senderWallet: out ? 'me' : 'them',
  recipientWallet: out ? 'them' : 'me',
  content: content,
  timestamp: DateTime.fromMillisecondsSinceEpoch(
    1_700_000_000_000 + minute * 60000,
  ),
  isOutgoing: out,
  onChainPubkey: '',
);

void main() {
  ProviderContainer makeContainer({
    List<DecryptedMessage> saved = const [],
    _FakeMessagesNotifier? notifier,
  }) {
    return ProviderContainer(
      overrides: [
        messageRepositoryProvider.overrideWithValue(_FakeMessageRepo(saved)),
        sealedChainClientProvider.overrideWith(
          (ref) async => SealedChainClient(
            sealedAppId: 1,
            algodUrl: 'https://algod.test',
            indexerUrl: 'https://indexer.test',
            wallet: _FakeWallet('me'),
            escrow: _FakeEscrow(),
            dio: Dio(),
          ),
        ),
        if (notifier != null)
          messagesNotifierProvider.overrideWith(() => notifier),
      ],
    );
  }

  group('build composition (wallet)', () {
    test('maps messages, uses username, filters invite envelopes', () async {
      final c = makeContainer(
        saved: [
          _dm('a', content: 'hi', minute: 0),
          _dm('b', content: 'sealed://alias-envelope?b=zz', minute: 1),
          _dm('c', content: 'yo', out: true, minute: 2),
        ],
      );
      addTearDown(c.dispose);

      final view = await c.read(
        chatControllerProvider(
          const WalletChatId('W', username: 'alice'),
        ).future,
      );

      expect(view.displayName, 'alice');
      expect(view.isAlias, isFalse);
      expect(view.canSend, isTrue);
      // Envelope dropped → 2 messages.
      expect(view.groups.map((g) => g.message.content), ['hi', 'yo']);
    });

    test('falls back to short wallet when no username', () async {
      final c = makeContainer();
      addTearDown(c.dispose);
      final view = await c.read(
        chatControllerProvider(WalletChatId('A' * 58)).future,
      );
      expect(view.displayName, 'AAAAAA...AAAAAA');
    });
  });

  group('optimistic send (wallet)', () {
    test('optimistic message appears, then rolls back after success', () async {
      final fake = _FakeMessagesNotifier()..gate = Completer<void>();
      final c = makeContainer(notifier: fake);
      addTearDown(c.dispose);

      const id = WalletChatId('W');
      // Prime the controller.
      await c.read(chatControllerProvider(id).future);

      // Fire send without awaiting — it suspends on the gate mid-flight.
      final sending = c.read(chatControllerProvider(id).notifier).send('hello');

      // Mid-flight: optimistic message is visible and pending.
      final midView = await c.read(chatControllerProvider(id).future);
      expect(midView.groups.length, 1);
      expect(midView.groups.single.message.content, 'hello');
      expect(midView.groups.single.message.isPending, isTrue);

      // Release the gate → send completes → optimistic rolled back.
      fake.gate!.complete();
      await sending;

      final endView = await c.read(chatControllerProvider(id).future);
      expect(endView.groups, isEmpty);
      expect(fake.sent, ['hello']);
    });

    test('rolls back optimistic message on send failure', () async {
      final fake = _FakeMessagesNotifier()..throwOnSend = true;
      final c = makeContainer(notifier: fake);
      addTearDown(c.dispose);

      const id = WalletChatId('W');
      await c.read(chatControllerProvider(id).future);

      await expectLater(
        c.read(chatControllerProvider(id).notifier).send('boom'),
        throwsA(isA<StateError>()),
      );

      final endView = await c.read(chatControllerProvider(id).future);
      expect(endView.groups, isEmpty); // no leftover pending
    });
  });

  group('wallet pagination', () {
    // Alternate sender so no two adjacent messages group together — keeps
    // groups.length == message count for easy assertions.
    List<DecryptedMessage> manyMessages(int n) => [
      for (var i = 0; i < n; i++)
        _dm('m$i', content: 'm$i', out: i.isEven, minute: i),
    ];

    test('opens to one page and grows via loadOlder', () async {
      final c = makeContainer(saved: manyMessages(120));
      addTearDown(c.dispose);

      const id = WalletChatId('W');
      final ctrl = c.read(chatControllerProvider(id).notifier);

      final first = await c.read(chatControllerProvider(id).future);
      expect(first.groups.length, 50, reason: 'opens to the latest page only');
      expect(ctrl.hasMoreOlder, isTrue);

      await ctrl.loadOlder();
      final second = await c.read(chatControllerProvider(id).future);
      expect(second.groups.length, 100);
      expect(ctrl.hasMoreOlder, isTrue);

      await ctrl.loadOlder();
      final third = await c.read(chatControllerProvider(id).future);
      expect(third.groups.length, 120, reason: 'capped at the available total');
      expect(ctrl.hasMoreOlder, isFalse, reason: 'no more history to load');
    });

    test('short thread loads fully and reports no more history', () async {
      final c = makeContainer(saved: manyMessages(10));
      addTearDown(c.dispose);

      const id = WalletChatId('W');
      final ctrl = c.read(chatControllerProvider(id).notifier);
      final view = await c.read(chatControllerProvider(id).future);

      expect(view.groups.length, 10);
      expect(ctrl.hasMoreOlder, isFalse);
    });
  });
}
