/// Per-conversation controller — the single owner of chat-screen logic.
///
/// Replaces the ~1830-line `chat_detail.dart` god-widget: the widget renders
/// [ChatView] and dispatches user actions here; all reads/sends/lifecycle live
/// in this controller. The wallet path reads a bounded latest-page window
/// directly from the repository (paginated; grows via [loadOlder]); the alias
/// path composes [aliasContactMessagesProvider]. Message mapping/grouping is
/// delegated to the pure helpers in `features/messaging/` so this glue stays
/// thin.
///
/// Handles wallet + alias sends, mark-read, rename, delete, and pending-invite
/// accept/decline (envelope retrieved from the synthetic carrier DM).
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sealed_app/core/service_locator.dart'
    show contactRepositoryProvider, messageRepositoryProvider;
import 'package:sealed_app/features/messaging/alias/alias_envelope.dart';
import 'package:sealed_app/features/messaging/chat_message_vm.dart';
import 'package:sealed_app/features/messaging/message_grouping.dart';
import 'package:sealed_app/models/message.dart';
import 'package:sealed_app/providers/alias_contact_provider.dart';
import 'package:sealed_app/providers/chain_provider.dart'
    show sealedChainClientProvider;
import 'package:sealed_app/providers/contact_keys_provider.dart';
import 'package:sealed_app/providers/message_provider.dart';

// ===========================================================================
// IDENTITY — the screen is opened for exactly one of these.
// ===========================================================================

/// Discriminated identity for a chat screen. Family key for [chatControllerProvider].
sealed class ChatIdentity {
  const ChatIdentity();
}

/// Wallet-to-wallet conversation.
class WalletChatId extends ChatIdentity {
  final String wallet;
  final String? username;
  const WalletChatId(this.wallet, {this.username});

  @override
  bool operator ==(Object other) =>
      other is WalletChatId && other.wallet == wallet;
  @override
  int get hashCode => wallet.hashCode;
}

/// Established alias chat (has a contact row).
class AliasChatId extends ChatIdentity {
  final String contactId;
  const AliasChatId(this.contactId);

  @override
  bool operator ==(Object other) =>
      other is AliasChatId && other.contactId == contactId;
  @override
  int get hashCode => contactId.hashCode;
}

/// Pending alias invitation — no contact row yet (keyed by inviteRef).
class PendingChatId extends ChatIdentity {
  final String inviteRef;
  const PendingChatId(this.inviteRef);

  @override
  bool operator ==(Object other) =>
      other is PendingChatId && other.inviteRef == inviteRef;
  @override
  int get hashCode => inviteRef.hashCode;
}

// ===========================================================================
// VIEW STATE — everything the screen renders.
// ===========================================================================

class ChatView {
  /// Grouped, chronological (oldest → newest) messages, ready to render.
  final List<GroupedChatMessage> groups;
  final String displayName;
  final bool isAlias;

  /// True for a pending invitation chat (no contact row yet).
  final bool isPending;

  /// False disables the composer (an inviter's pending chat has no key yet).
  final bool canSend;
  final String? sendDisabledReason;

  /// Non-null only for a creator's pending invite that is still waiting for the
  /// peer to accept — carries the invitee's display name for the "Waiting for
  /// @x to accept…" state. Null for acceptor-pending and established chats.
  final String? pendingWaitingName;

  const ChatView({
    required this.groups,
    required this.displayName,
    required this.isAlias,
    required this.isPending,
    required this.canSend,
    this.sendDisabledReason,
    this.pendingWaitingName,
  });
}

// ===========================================================================
// PURE HELPERS (unit-tested without Riverpod)
// ===========================================================================

String formatWalletShort(String address) => address.length <= 12
    ? address
    : '${address.substring(0, 6)}...${address.substring(address.length - 6)}';

/// Map source messages to view models, dropping alias invite/accept envelopes
/// (those surface only in `ChatsScreen`, never in the thread).
List<ChatMessageVM> mapDecryptedToVms(List<DecryptedMessage> msgs) => [
  for (final m in msgs)
    if (!isAliasInviteEnvelope(m.content))
      ChatMessageVM(
        id: m.id,
        content: m.content,
        isOutgoing: m.isOutgoing,
        timestamp: m.timestamp,
        isPending: m.id.startsWith('pending-'),
      ),
];

/// Merge saved + optimistic-pending messages, sort chronological, and group.
List<GroupedChatMessage> mergeAndGroup(
  List<ChatMessageVM> saved,
  List<ChatMessageVM> pending,
) {
  final all = [...saved, ...pending]
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return groupMessages(all);
}

/// Live display name for a wallet peer — the same resolution order the Chats
/// and Contacts lists use: contacts-table username (kept fresh by the 120s
/// refresh loop) first, then the newest per-message snapshot (covers row-less
/// unknown peers; populated at arrival from chain). Null when neither exists.
/// Re-runs on every [messageRefreshCounterProvider] bump.
final walletPeerNameProvider = FutureProvider.family<String?, String>((
  ref,
  wallet,
) async {
  ref.watch(messageRefreshCounterProvider);
  final contact = await ref.watch(contactRepositoryProvider).getContact(wallet);
  final fromContacts = contact?.username;
  if (fromContacts != null && fromContacts.isNotEmpty) return fromContacts;
  return ref.watch(messageRepositoryProvider).getContactUsername(wallet);
});

// ===========================================================================
// CONTROLLER
// ===========================================================================

class ChatController extends AsyncNotifier<ChatView> {
  ChatController(this.identity);

  final ChatIdentity identity;

  /// Optimistic, not-yet-confirmed outgoing messages (wallet path).
  final List<ChatMessageVM> _pending = [];

  /// Wallet-path pagination window. The chat opens to the latest [_pageSize]
  /// messages and grows the window via [loadOlder] as the user scrolls up, so
  /// opening a long thread doesn't read the whole history on every refresh.
  static const int _pageSize = 50;
  int _walletLimit = _pageSize;

  /// True while older messages remain to be loaded for the wallet path.
  bool hasMoreOlder = true;

  @override
  Future<ChatView> build() async {
    ref.watch(messageRefreshCounterProvider);

    switch (identity) {
      case WalletChatId(:final wallet, :final username):
        // Read the latest [_walletLimit] directly (bounded) rather than via
        // conversationMessagesProvider (which returns the full thread).
        // Liveness comes from the messageRefreshCounter watch above — every
        // message-write path bumps it, re-running this build.
        final client = await ref.watch(sealedChainClientProvider.future);
        final myWallet = client.wallet.walletAddress;
        final msgs = myWallet == null
            ? const <DecryptedMessage>[]
            : await ref
                  .watch(messageRepositoryProvider)
                  .getConversationMessages(
                    myWallet,
                    wallet,
                    limit: _walletLimit,
                  );
        // A full page back implies more history may exist upstream.
        hasMoreOlder = msgs.length >= _walletLimit;
        // Live display name. The nav-arg username is a snapshot frozen at
        // push time — a peer opened from a fresh incoming message carries
        // none, and a later username change never reaches it (the family key
        // ignores username, so even a re-push keeps the first identity).
        // Watched as a LIVE AsyncValue, not awaited: the thread renders
        // immediately with the nav-arg fallback and re-resolves when the
        // name provider lands (and on every refresh-counter bump, so the
        // 120s username refresh reaches an OPEN thread).
        final liveName = ref.watch(walletPeerNameProvider(wallet)).value;
        return ChatView(
          groups: mergeAndGroup(mapDecryptedToVms(msgs), _pending),
          displayName: (liveName != null && liveName.isNotEmpty)
              ? liveName
              : (username != null && username.isNotEmpty)
              ? username
              : formatWalletShort(wallet),
          isAlias: false,
          isPending: false,
          canSend: true,
        );

      case AliasChatId(:final contactId):
        final msgs = await ref.watch(
          aliasContactMessagesProvider(contactId).future,
        );
        final contact = await ref.watch(aliasContactProvider(contactId).future);
        final nick = contact?.nickname;
        return ChatView(
          groups: mergeAndGroup(mapDecryptedToVms(msgs), _pending),
          displayName: (nick != null && nick.isNotEmpty)
              ? nick
              : (contact?.aliasHandle ?? 'Alias'),
          isAlias: true,
          isPending: false,
          canSend: true,
        );

      case PendingChatId(:final inviteRef):
        final repo = ref.watch(contactRepositoryProvider);
        final pending = await repo.getPendingInvite(inviteRef);

        if (pending == null) {
          // Pending row is gone — the handshake promoted it to a contact (or it
          // was declined elsewhere). Show a neutral "completing…" waiting state,
          // NEVER accept/decline, while the screen rebinds to the live chat.
          return const ChatView(
            groups: [],
            displayName: '',
            isAlias: true,
            isPending: true,
            canSend: false,
            pendingWaitingName: '',
          );
        }

        final isCreator = pending.isCreator;

        if (isCreator) {
          // Creator side: waiting for the invitee to accept. aliasDisplay holds
          // the invitee label the creator set (their username / "Unnamed").
          final inviteeName = pending.aliasDisplay.isNotEmpty
              ? pending.aliasDisplay
              : 'contact';
          return ChatView(
            groups: const [],
            displayName: inviteeName,
            isAlias: true,
            isPending: true,
            canSend: false,
            pendingWaitingName: inviteeName,
          );
        }

        // Acceptor side: aliasDisplay holds the inviter wallet; online invites
        // carry an on-chain identity, so show the nickname, not the raw address.
        final inviterWallet = pending.aliasDisplay;
        final peerName = await ref.watch(
          walletPeerNameProvider(inviterWallet).future,
        );
        return ChatView(
          groups: const [],
          displayName: (peerName != null && peerName.isNotEmpty)
              ? peerName
              : formatWalletShort(inviterWallet),
          isAlias: true,
          isPending: true,
          canSend: true,
        );
    }
  }

  /// Grow the wallet-path window by one page and rebuild. No-op for alias /
  /// pending chats or when no older messages remain. Called by the chat screen
  /// when the user scrolls near the top of the history.
  Future<void> loadOlder() async {
    if (identity is! WalletChatId) return;
    if (!hasMoreOlder) return;
    _walletLimit += _pageSize;
    ref.invalidateSelf();
    await future; // let the rebuilt view settle before the caller continues
  }

  /// Send a message. Wallet path shows the text optimistically while the
  /// on-chain post is in flight; alias path delegates straight through.
  /// Rethrows on failure so the screen can surface balance/retry UI — the
  /// optimistic entry is always rolled back first.
  Future<void> send(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final notifier = ref.read(messagesNotifierProvider.notifier);

    switch (identity) {
      case WalletChatId(:final wallet, :final username):
        final optimistic = ChatMessageVM(
          id: 'pending-${DateTime.now().microsecondsSinceEpoch}',
          content: t,
          isOutgoing: true,
          timestamp: DateTime.now(),
          isPending: true,
        );
        _pending.add(optimistic);
        ref.invalidateSelf();
        try {
          await notifier.sendMessage(
            recipientWallet: wallet,
            recipientUsername: username,
            plaintext: t,
          );
          ref.invalidate(hasCachedPqSecretProvider(wallet));
        } finally {
          _pending.removeWhere((m) => m.id == optimistic.id);
          ref.invalidateSelf();
        }

      case AliasChatId(:final contactId):
        await notifier.sendAliasMessage(contactId: contactId, plaintext: t);

      case PendingChatId():
        // Accept-by-reply: promote the invite, then send on the alias channel.
        final contactId = await accept();
        await notifier.sendAliasMessage(contactId: contactId, plaintext: t);
    }
  }

  /// Accept a pending invitation: derive keys from the inbound envelope, send
  /// the accept envelope back to the creator, and promote to a contact.
  /// Returns the new alias contactId so the screen can rebind.
  Future<String> accept() async {
    final id = identity;
    if (id is! PendingChatId) {
      throw StateError('accept() is only valid for a pending invite chat');
    }
    final repo = ref.read(contactRepositoryProvider);
    final pending = await repo.getPendingInvite(id.inviteRef);
    final creatorWallet = pending?.aliasDisplay;
    if (creatorWallet == null) {
      throw StateError('Pending invite not found');
    }
    return _acceptFromWallet(id.inviteRef, creatorWallet);
  }

  /// Shared accept path: find the carrier envelope from [creatorWallet], resolve
  /// the inviter's nickname, derive keys, send the accept envelope back, and
  /// promote the invite to an alias contact. Returns the new contactId.
  Future<String> _acceptFromWallet(
    String inviteRef,
    String creatorWallet,
  ) async {
    final env = await _findInviteEnvelope(creatorWallet);
    if (env == null) {
      throw StateError('Invite envelope unavailable');
    }

    final service = await ref.read(aliasOnboardingServiceProvider.future);

    // Online invites carry a real on-chain identity, so label the alias contact
    // by the inviter's nickname (the offline QR flow, which has no on-chain
    // identity, keeps "Unnamed"). Prefer the authoritative chain username, fall
    // back to any locally-cached peer name, and only "Unnamed" if neither.
    String inviterName = 'Unnamed';
    try {
      final chain = await ref.read(sealedChainClientProvider.future);
      final chainName = (await chain.getUserByWallet(creatorWallet))?.username;
      if (chainName != null && chainName.isNotEmpty) {
        inviterName = chainName;
      } else {
        final cached = await ref.read(
          walletPeerNameProvider(creatorWallet).future,
        );
        if (cached != null && cached.isNotEmpty) inviterName = cached;
      }
    } catch (_) {
      // Resolution is best-effort; "Unnamed" is the safe fallback.
    }

    final result = await service.acceptInvitationFromEnvelope(
      env: env,
      alias: inviterName,
    );

    final notifier = ref.read(messagesNotifierProvider.notifier);
    // Send the accept envelope back to the creator (fresh accept only).
    if (result.acceptEnvelopeBytes.isNotEmpty) {
      await notifier.sendMessageBytes(
        recipientWallet: creatorWallet,
        plaintextBytes: result.acceptEnvelopeBytes,
      );
    }
    notifier.bumpRefresh();
    return result.contact.contactId;
  }

  /// For a pending invite: the alias contactId once the handshake has promoted
  /// it to a real contact (the peer accepted, or — creator side — the accept
  /// envelope arrived via sync). Null while still pending. The screen polls this
  /// to rebind in place from the waiting state to the live alias chat.
  Future<String?> promotedContactId() async {
    final id = identity;
    if (id is! PendingChatId) return null;
    if (id.inviteRef.length < 32) return null;
    // contactId = first 32 hex chars of inviteRef (see AliasOnboardingService).
    final contactId = id.inviteRef.substring(0, 32);
    final contact = await ref
        .read(contactRepositoryProvider)
        .getAliasContact(contactId);
    return contact != null ? contactId : null;
  }

  /// Decline a pending invitation (durable dismiss; survives re-sync).
  Future<void> decline() async {
    final id = identity;
    if (id is! PendingChatId) return;
    await ref.read(contactRepositoryProvider).markInviteDismissed(id.inviteRef);
    ref.read(messagesNotifierProvider.notifier).bumpRefresh();
  }

  /// Creator-side cancel of an outgoing alias invite still waiting for the peer
  /// to accept: erase the temp key material and delete the pending row. No-op if
  /// the handshake already promoted to a contact (discardPendingInvite guards
  /// that), so a completed accept is never torn down.
  Future<void> cancelInvite() async {
    final id = identity;
    if (id is! PendingChatId) return;
    final service = await ref.read(aliasOnboardingServiceProvider.future);
    await service.discardPendingInvite(id.inviteRef);
    ref.read(messagesNotifierProvider.notifier).bumpRefresh();
  }

  /// Locate the inbound invite envelope (synthetic DM carrier) from [sender].
  Future<AliasInviteEnvelope?> _findInviteEnvelope(String sender) async {
    final msgs = await ref.read(conversationMessagesProvider(sender).future);
    for (final m in msgs) {
      if (m.content.startsWith(kAliasEnvelopePrefix)) {
        final b = Uri.tryParse(m.content)?.queryParameters['b'];
        if (b != null) {
          final env = AliasInviteEnvelope.tryParse(base64Url.decode(b));
          if (env != null) return env;
        }
      }
    }
    return null;
  }

  /// Mark this conversation read (clears unread badge in the list).
  Future<void> markRead() async {
    final notifier = ref.read(messagesNotifierProvider.notifier);
    switch (identity) {
      case WalletChatId(:final wallet):
        await notifier.markConversationAsRead(wallet);
      case AliasChatId(:final contactId):
        await notifier.markAliasAsRead(contactId);
      case PendingChatId():
        break;
    }
  }

  /// Rename an alias conversation (no-op for non-alias / pending).
  Future<void> rename(String newName) async {
    final name = newName.trim();
    if (name.isEmpty) return;
    if (identity case AliasChatId(:final contactId)) {
      await ref
          .read(messagesNotifierProvider.notifier)
          .updateNickname(contactId, name);
    }
  }

  /// Delete this conversation: alias contact (+ keys) or wallet message rows.
  Future<void> delete() async {
    final notifier = ref.read(messagesNotifierProvider.notifier);
    switch (identity) {
      case AliasChatId(:final contactId):
        await notifier.deleteAliasContact(contactId);
      case WalletChatId(:final wallet):
        await notifier.deleteConversation(wallet);
      case PendingChatId():
        break;
    }
  }
}

/// Per-conversation controller, keyed by [ChatIdentity].
final chatControllerProvider =
    AsyncNotifierProvider.family<ChatController, ChatView, ChatIdentity>(
      ChatController.new,
    );
