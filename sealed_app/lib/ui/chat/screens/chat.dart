import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/features/messaging/message_codec.dart' as codec;
import 'package:sealed_app/ui/shared/error_handler.dart';
import 'package:sealed_app/features/messaging/message_grouping.dart';
import 'package:sealed_app/providers/chat_controller.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/ui/contacts/contact_profile.dart';
import 'package:sealed_app/ui/chat/widgets/alias_change.dart';
import 'package:sealed_app/ui/chat/widgets/alias_termination.dart';

import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/dialogs.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';
import 'package:sealed_app/ui/shared/widgets/secure_screen.dart';
import 'package:sealed_app/ui/shared/widgets/snackbars.dart';

/// V2 chat thread. Renders [ChatView] from [chatControllerProvider] and
/// dispatches user actions to the controller — all logic lives there.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.identity});

  final ChatIdentity identity;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _sending = false;
  bool _didInitialScroll = false;
  bool _loadingOlder = false;
  bool _tooLarge = false;
  String? _selectedMessageId;

  /// Live byte-budget check: messages that won't fit the wire frame are
  /// flagged before send (rather than throwing at send time). Cheap — short
  /// messages skip gzip entirely (see [codec.messageContentTooLarge]).
  /// Rebuilds so the input bar can re-measure its line count for padding.
  void _onInputChanged(String value) {
    _closeSelection();
    setState(() => _tooLarge = codec.messageContentTooLarge(value.trim()));
  }

  /// True once the current input wraps past a single line, measured against
  /// the real text width. Drives the input's vertical padding (a single-line
  /// pill wants tight padding; a multi-line one needs room off the corners).
  bool _inputIsMultiline(double maxTextWidth) {
    final text = _input.text;
    if (text.isEmpty || maxTextWidth <= 0) return text.contains('\n');
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxTextWidth);
    return tp.computeLineMetrics().length > 1;
  }

  /// The conversation this screen is bound to. Starts as [widget.identity] but
  /// is swapped in place when a pending invite is accepted (PendingChatId →
  /// AliasChatId) so acceptance does NOT push a new screen — the same screen
  /// rebinds to the now-established alias chat.
  late ChatIdentity _identity;

  /// "New messages" jump pill state. While the user is scrolled up, incoming
  /// peer messages are counted instead of yanking the view to the bottom. The
  /// pill (count + down arrow) sits 12px above the composer and, on tap,
  /// animates to the newest message. [_lastSeenId] is the newest message id the
  /// user last saw while parked at the bottom — the anchor we count forward
  /// from. Outgoing sends auto-scroll, so only incoming rows bump the count.
  int _newCount = 0;
  bool _showJump = false;
  String? _lastSeenId;

  /// Within this many pixels of the end counts as "at the bottom".
  static const double _atBottomSlack = 120;

  /// While this thread is open + foregrounded we poll faster than the app-wide
  /// 6s background cadence so an active conversation feels live. Privacy note:
  /// this runs the SAME all-messages scan (not a per-peer indexer query, which
  /// would leak who you're talking to) — just more often, and only while the
  /// chat is on screen. Stops on background / dispose, back to the 6s poll.
  Timer? _focusedSyncTimer;
  static const _focusedSyncInterval = Duration(seconds: 2);

  /// While a pending invite is open, poll every 10s for the handshake to
  /// complete (peer accepted / accept envelope synced) so the waiting screen
  /// rebinds in place to the live alias chat.
  Timer? _acceptPollTimer;
  static const _acceptPollInterval = Duration(seconds: 10);

  /// Cached notifier so the focused-sync timer never touches `ref` (which is
  /// unsafe once the widget is deactivated). The messages notifier is an
  /// app-scoped singleton, safe to hold for the screen's lifetime.
  MessagesNotifier? _messagesNotifier;

  /// Mark-read only counts while the app is foregrounded — a message synced
  /// while this thread sits behind the lock screen has NOT been seen.
  bool _appResumed = true;

  bool get _isAlias => _identity is! WalletChatId;
  bool get _isPending => _identity is PendingChatId;

  /// Cached so [dispose] (and any post-deactivate path) never calls `ref.read`,
  /// which is unsafe once the widget unmounts. The family notifier is captured
  /// lazily on first mounted use — same rationale as [_messagesNotifier].
  ChatController? _chatController;

  ChatController get _ctrl => (_chatController ??= ref.read(
    chatControllerProvider(_identity).notifier,
  ))!;

  /// Thread visible + app foregrounded ⇒ incoming rows are read. Safe to call
  /// on every rebuild: the notifier no-ops (no refresh, no counter bump) when
  /// nothing is unread, so this cannot loop. Failures are logged, not thrown —
  /// a missed mark-read must never crash the thread.
  void _markRead() {
    if (!_appResumed) return;
    _ctrl.markRead().catchError((Object e) {
      debugPrint('[ChatScreen] ⚠️ markRead failed (badge may stay): $e');
    });
  }

  @override
  void initState() {
    super.initState();
    _identity = widget.identity;
    WidgetsBinding.instance.addObserver(this);
    // Capture the controller while mounted so dispose's mark-read backstop
    // never reaches for ref.read after the widget deactivates.
    _ctrl;
    WidgetsBinding.instance.addPostFrameCallback((_) => _markRead());
    _scroll.addListener(_onScroll);
    _startFocusedSync();
    _startAcceptPoll();
  }

  /// Poll for the pending invite to be accepted; on promotion, rebind this same
  /// screen to the live alias chat. No-op for non-pending chats.
  void _startAcceptPoll() {
    if (!_isPending) return;
    _acceptPollTimer?.cancel();
    _acceptPollTimer = Timer.periodic(_acceptPollInterval, (_) async {
      _messagesNotifier?.syncMessages(); // nudge the handshake forward
      final contactId = await _ctrl.promotedContactId();
      if (contactId != null && mounted && _isPending) {
        _rebindToAlias(contactId);
      }
    });
  }

  void _stopAcceptPoll() {
    _acceptPollTimer?.cancel();
    _acceptPollTimer = null;
  }

  bool _checkingPromoted = false;

  /// Immediately rebind if the invite has promoted to a contact. Used when the
  /// waiting view refreshes, so acceptance doesn't have to wait for the 10s poll.
  Future<void> _checkPromotedAndRebind() async {
    if (_checkingPromoted) return;
    _checkingPromoted = true;
    try {
      final contactId = await _ctrl.promotedContactId();
      if (contactId != null && mounted && _isPending) {
        _rebindToAlias(contactId);
      }
    } finally {
      _checkingPromoted = false;
    }
  }

  /// Swap this screen in place to the established alias chat (no new route).
  void _rebindToAlias(String contactId) {
    _stopAcceptPoll();
    setState(() {
      _chatController = null; // re-resolve _ctrl for the new identity
      _identity = AliasChatId(contactId);
      _acceptingInvite = false;
    });
  }

  /// Faster sync cadence while the chat is open + foregrounded. Fire-and-forget;
  /// MessagesNotifier.syncMessages() guards against overlapping runs, so this
  /// coexists with the global poll.
  void _startFocusedSync() {
    _focusedSyncTimer?.cancel();
    // Capture the notifier once; the timer must NOT call ref.read (unsafe after
    // the widget deactivates — a tick can race dispose).
    _messagesNotifier ??= ref.read(messagesNotifierProvider.notifier);
    final notifier = _messagesNotifier!;
    notifier.syncMessages(); // immediate catch-up on open
    _focusedSyncTimer = Timer.periodic(
      _focusedSyncInterval,
      (_) => notifier.syncMessages(),
    );
  }

  void _stopFocusedSync() {
    _focusedSyncTimer?.cancel();
    _focusedSyncTimer = null;
  }

  /// Load older history when the user scrolls near the top of the thread.
  /// Newest messages sit at the bottom (non-reverse list), so older history is
  /// prepended above — we anchor the scroll position by the inserted height so
  /// the view doesn't jump.
  void _onScroll() {
    // Reaching the bottom clears the new-message pill and re-anchors the count.
    if (_showJump && _atBottom()) {
      _resetJump();
    }
    if (_loadingOlder) return;
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels > 240) return; // not near the top yet
    final ctrl = _ctrl;
    if (!ctrl.hasMoreOlder) return;
    _loadOlder(ctrl);
  }

  bool _atBottom() {
    if (!_scroll.hasClients) return true;
    final p = _scroll.position;
    return p.maxScrollExtent - p.pixels <= _atBottomSlack;
  }

  /// Clear the pill and re-anchor [_lastSeenId] to the current newest message.
  void _resetJump() {
    final newest = _newestId();
    if (_newCount != 0 || _showJump) {
      setState(() {
        _newCount = 0;
        _showJump = false;
      });
    }
    if (newest != null) _lastSeenId = newest;
  }

  String? _newestId() {
    final view = ref.read(chatControllerProvider(_identity)).value;
    if (view == null || view.groups.isEmpty) return null;
    return view.groups.last.message.id;
  }

  /// Called on every thread update. While parked at the bottom we just track the
  /// newest id; while scrolled up we count incoming messages newer than the
  /// anchor and surface the pill.
  void _onThreadUpdate(ChatView view) {
    if (view.groups.isEmpty) return;
    if (_atBottom()) {
      // Parked at the bottom: keep the newest message in view as it arrives.
      final newest = view.groups.last.message.id;
      if (newest != _lastSeenId) _scrollToBottom();
      _resetJump();
      return;
    }
    final count = _countIncomingAfter(view, _lastSeenId);
    if (count != _newCount || (count > 0) != _showJump) {
      setState(() {
        _newCount = count;
        _showJump = count > 0;
      });
    }
  }

  /// Count incoming (peer) groups that arrived after [lastId]. Outgoing rows are
  /// ignored — the sender already scrolled to them.
  int _countIncomingAfter(ChatView view, String? lastId) {
    final groups = view.groups;
    int startIdx = -1;
    if (lastId != null) {
      for (int i = groups.length - 1; i >= 0; i--) {
        if (groups[i].message.id == lastId) {
          startIdx = i;
          break;
        }
      }
    }
    int c = 0;
    for (int i = startIdx + 1; i < groups.length; i++) {
      if (!groups[i].message.isOutgoing) c++;
    }
    return c;
  }

  void _onJumpTap() {
    _scrollToBottom();
    _resetJump();
  }

  Future<void> _loadOlder(ChatController ctrl) async {
    _loadingOlder = true;
    final before = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    try {
      await ctrl.loadOlder();
    } finally {
      // After the prepended page lays out, shift the offset by the height delta
      // so the messages the user was looking at stay put.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          final delta = _scroll.position.maxScrollExtent - before;
          if (delta > 0) {
            _scroll.jumpTo(_scroll.position.pixels + delta);
          }
        }
        _loadingOlder = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    if (_appResumed) {
      // Catch up on messages that synced while this thread was backgrounded.
      _markRead();
      _startFocusedSync();
    } else {
      _stopFocusedSync(); // don't fast-poll in the background
    }
  }

  @override
  void dispose() {
    // Backstop: anything rendered up to the pop is read, even if it landed
    // between the last listener tick and the pop.
    _markRead();
    _stopFocusedSync();
    _stopAcceptPoll();
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Jump (no animation) to the newest message the first time messages render.
  // Lazy ListView reports a stale maxScrollExtent on the first frame, so jump
  // again on the next few frames until the extent settles at the true bottom.
  void _jumpToBottomOnce() {
    if (_didInitialScroll) return;
    _didInitialScroll = true;
    _pinToBottom(3);
  }

  void _pinToBottom(int retries) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (_scroll.offset < max) _scroll.jumpTo(max);
      if (retries > 0) _pinToBottom(retries - 1);
    });
  }

  void _closeSelection() {
    if (_selectedMessageId != null) {
      setState(() => _selectedMessageId = null);
    }
  }

  Future<void> _send(ChatView view) async {
    _closeSelection();
    final text = _input.text.trim();
    if (text.isEmpty || _sending || !view.canSend || _tooLarge) return;

    _input.clear();
    setState(() {
      _sending = true;
      _tooLarge = false;
    });
    _scrollToBottom();
    try {
      await _ctrl.send(text);
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      final err = SendMessageException.fromError(e);
      if (err.kind == SendMessageErrorKind.insufficientBalance) {
        await CreditsRequiredDialog.show(context);
      } else {
        context.showSendError(err.message, onRetry: () => _send(view));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _openContactProfile() {
    final id = _identity;
    if (id is! WalletChatId) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ContactProfileScreen(
          contactWallet: id.wallet,
          contactUsername: id.username,
        ),
      ),
    );
  }

  Future<void> _renameAlias(ChatView view) async {
    final newName = await SealedDialog.show<String>(
      context: context,
      dialog: AliasChangeDialog(initialAlias: view.displayName),
    );
    if (newName != null && newName.isNotEmpty) {
      await _ctrl.rename(newName);
    }
  }

  Future<void> _deleteAlias() async {
    final confirmed = await SealedDialog.show<bool>(
      context: context,
      dialog: const AliasTerminationDialog(),
    );
    if (confirmed == true) {
      await _ctrl.delete();
      if (mounted) Navigator.of(context).pop();
    }
  }

  bool _acceptingInvite = false;

  Future<void> _acceptInvite() async {
    if (_acceptingInvite) return;
    setState(() => _acceptingInvite = true);
    try {
      final contactId = await _ctrl.accept();
      if (!mounted) return;
      // Rebind this SAME screen to the now-established alias chat — no new route.
      // _isPending flips off (composer replaces the accept/decline bar) and the
      // watched provider re-points at the alias thread, blank and ready to send.
      _rebindToAlias(contactId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _acceptingInvite = false);
      showErrorSnackBar(context, 'Failed to accept invitation');
    }
  }

  Future<void> _declineInvite() async {
    await _ctrl.decline();
    if (mounted) Navigator.of(context).pop();
  }

  bool _cancellingInvite = false;

  /// Creator-side: cancel the outgoing invite still waiting for acceptance.
  /// Tears down the pending invite (temp keys + row) and leaves the screen.
  Future<void> _cancelInvite() async {
    if (_cancellingInvite) return;
    setState(() => _cancellingInvite = true);
    try {
      await _ctrl.cancelInvite();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _cancellingInvite = false);
      showErrorSnackBar(context, 'Failed to cancel invitation');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Re-mark on every thread update while open: a message arriving during
    // the 5s sync poll renders here, so it is read — without this it kept
    // is_read=0 and showed a stale unread badge after leaving the chat.
    ref.listen(chatControllerProvider(_identity), (prev, next) {
      if (next.hasValue && !identical(prev?.value, next.value)) {
        // A waiting/pending view that just refreshed (e.g. a sync promoted the
        // invite) — rebind to the live chat immediately instead of waiting for
        // the 10s poll, so the accept/decline bar never flashes.
        if (next.value!.pendingWaitingName != null) {
          _checkPromotedAndRebind();
          return;
        }
        _markRead();
        _onThreadUpdate(next.value!);
      }
    });
    final viewAsync = ref.watch(chatControllerProvider(_identity));
    // Capture-protected while mounted (black screenshots/recordings).
    return SecureScreen(
      child: Scaffold(
        body: Container(
          margin: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 10),
          child: viewAsync.when(
            // Keep the previous view (and the keyboard focus) while the
            // controller rebuilds on incoming messages — only show the spinner
            // on first load.
            skipLoadingOnReload: true,
            skipError: true,
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Text(
                'Failed to load chat',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
              ),
            ),
            data: (view) => _buildBody(context, view),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ChatView view) {
    // Creator's pending invite: a waiting state (no thread, no composer) until
    // the peer accepts, after which the screen rebinds in place to the chat.
    if (view.pendingWaitingName != null) {
      return Column(
        children: [
          _buildTopBar(context, view),
          Expanded(child: _buildWaitingState(view.pendingWaitingName!)),
        ],
      );
    }
    return Column(
      children: [
        _buildTopBar(context, view),
        Expanded(
          child: Stack(
            children: [
              _buildMessages(view),
              Positioned(
                top: 12.h,
                left: 0,
                right: 0,
                child: Center(child: _buildPrivacyPill(view)),
              ),
              // New-message jump pill: 12px above the composer, only while
              // scrolled up with unseen incoming messages.
              if (_showJump && _newCount > 0)
                Positioned(
                  bottom: 12.h,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: _NewMessagesPill(
                      count: _newCount,
                      onTap: _onJumpTap,
                    ),
                  ),
                ),
            ],
          ),
        ),
        _isPending ? _buildPendingActions() : _buildInputBar(view),
      ],
    );
  }

  /// Creator-side "waiting for the peer to accept" state. No thread, no input —
  /// the 10s accept poll rebinds the screen once the handshake completes.
  Widget _buildWaitingState(String inviteeName) {
    // Usernames have no spaces; placeholders ("Unnamed", "Alias Chat") stay bare.
    final isHandle =
        inviteeName.isNotEmpty &&
        inviteeName != 'Unnamed' &&
        !inviteeName.contains(' ');
    final label = isHandle ? '@$inviteeName' : 'this contact';
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 32.w),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 28.w,
            height: 28.w,
            child: CircularProgressIndicator(
              color: primaryColor,
              strokeWidth: 2.4,
            ),
          ),
          Gap(20.h),
          Text(
            'Waiting for $label to accept…',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 16.sp,
              fontWeight: FontWeight.w500,
            ),
          ),
          Gap(8.h),
          Text(
            'The alias chat opens automatically once they accept your invitation.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 13.sp,
            ),
          ),
          Gap(32.h),
          // Cancel the outgoing invite (deletes the pending row + temp keys).
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 220.w),
            child: SealedCircularButton(
              label: 'Cancel invitation',
              loading: _cancellingInvite,
              onTap: _cancelInvite,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              textColor: Colors.white.withValues(alpha: 0.9),
              enableGlassBlur: true,
            ),
          ),
          Gap(MediaQuery.of(context).size.height * 0.06),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, ChatView view) {
    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 12.h,
          ),
          child: Row(
            children: [
              SealedBackButton(onTap: () => Navigator.of(context).pop()),
              Gap(16.w),
              // Tapping the bar opens rename for an established alias chat.
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _isPending
                      ? null
                      : (_isAlias
                            ? () => _renameAlias(view)
                            : _openContactProfile),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20.w,
                        backgroundColor: _isAlias
                            ? Colors.white.withValues(alpha: 0.08)
                            : primaryColor,
                        child: _isAlias
                            ? SvgPicture.asset("assets/svg/chat/alias.svg")
                            : Text(
                                view.displayName.isNotEmpty
                                    ? view.displayName.characters.first
                                          .toUpperCase()
                                    : '?',
                                style: const TextStyle(color: Colors.black),
                              ),
                      ),
                      Gap(12.w),
                      Flexible(
                        child: Text(
                          view.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      // Pencil signals the alias name is editable (tap = rename).
                      if (_isAlias && !_isPending) ...[
                        Gap(12.w),
                        Icon(
                          Icons.edit_outlined,
                          size: 16.w,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // Checkmark only on the acceptor's invite (they can accept). The
              // creator's waiting screen (pendingWaitingName != null) shows
              // nothing.
              if (_isPending && view.pendingWaitingName == null)
                _MiniAcceptButton(onTap: _acceptInvite)
              else if (_isAlias && !_isPending)
                _DeleteAliasButton(onTap: _deleteAlias),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          height: 1.h,
          color: Colors.white.withValues(alpha: 0.12),
        ),
      ],
    );
  }

  Widget _buildPrivacyPill(ChatView view) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(100),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: EdgeInsets.symmetric(vertical: 8.h, horizontal: 12.w),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(100),
            color: primaryColor.withValues(alpha: 0.12),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SvgPicture.asset("assets/svg/lock.svg", width: 16.w),
              Gap(8.w),
              Text(
                _isAlias
                    ? "Fully private & temporary conversation"
                    : "Post Quantum Secured",
                style: Theme.of(
                  context,
                ).textTheme.bodySmall!.copyWith(color: primaryColor),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessages(ChatView view) {
    if (view.groups.isEmpty) {
      return Center(
        child: Text(
          _isPending ? 'Alias chat invitation' : 'No messages yet',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
        ),
      );
    }
    _jumpToBottomOnce();
    // Anchor the new-message count to the newest row on first render so a later
    // scroll-up doesn't count pre-existing history as "new".
    _lastSeenId ??= view.groups.last.message.id;
    return ListView.separated(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(
        horizontalPadding.w,
        64.h,
        horizontalPadding.w,
        16.h,
      ),
      itemCount: view.groups.length,
      separatorBuilder: (_, g) => Gap(4.h),
      itemBuilder: (context, index) {
        final group = view.groups[index];
        return _Message(
          group: group,
          selecting: group.message.id == _selectedMessageId,
          onSelect: () => setState(() => _selectedMessageId = group.message.id),
          onClose: _closeSelection,
        );
      },
    );
  }

  Widget _buildInputBar(ChatView view) {
    final enabled = view.canSend;
    return SafeArea(
      top: false,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            height: 1.h,
            color: Colors.white.withValues(alpha: 0.12),
          ),
          if (_tooLarge)
            Padding(
              padding: EdgeInsets.only(
                left: horizontalPadding,
                right: horizontalPadding,
                top: 8.h,
              ),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
                decoration: BoxDecoration(
                  color: const Color(0xFFD31737).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: Text(
                  'Message is too large',
                  style: TextStyle(
                    color: const Color(0xFFD31737),
                    fontSize: 12.sp,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              // Text area width inside the pill: bar width minus the outer
              // padding, the inner horizontal contentPadding, and the suffix
              // send button. Used only to decide single- vs multi-line padding.
              final textWidth =
                  constraints.maxWidth -
                  horizontalPadding * 2 -
                  20.w * 2 -
                  48.w;
              final multiline = _inputIsMultiline(textWidth);
              return Container(
                padding: EdgeInsets.symmetric(
                  horizontal: horizontalPadding,
                  vertical: 12.h,
                ),
                child: TextField(
                  controller: _input,
                  enabled: enabled,
                  style: Theme.of(context).textTheme.titleMedium,
                  textInputAction: TextInputAction.send,
                  minLines: 1,
                  maxLines: 3,
                  onTap: _closeSelection,
                  onChanged: _onInputChanged,
                  onSubmitted: (enabled && !_tooLarge)
                      ? (_) => _send(view)
                      : null,
                  decoration: InputDecoration(
                    hintText: enabled ? null : view.sendDisabledReason,
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                    suffixIcon: Padding(
                      padding: EdgeInsets.only(right: 16.w),
                      child: _sending
                          ? Padding(
                              padding: EdgeInsets.all(6.w),
                              child: SizedBox(
                                width: 16.w,
                                height: 16.w,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: primaryColor,
                                ),
                              ),
                            )
                          : _SendButton(
                              onTap: (enabled && !_tooLarge)
                                  ? () => _send(view)
                                  : null,
                            ),
                    ),
                    suffixIconConstraints: BoxConstraints(
                      minWidth: 24.w,
                      minHeight: 24.w,
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      vertical: multiline ? 24.h : 8.h,
                      horizontal: 20.w,
                    ),
                    filled: true,
                    fillColor: cardColor,
                    border: _pillBorder(),
                    enabledBorder: _pillBorder(),
                    focusedBorder: _pillBorder(),
                    disabledBorder: _pillBorder(),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  OutlineInputBorder _pillBorder() => OutlineInputBorder(
    borderSide: BorderSide(
      width: 2,
      color: Colors.white.withValues(alpha: 0.24),
    ),
    borderRadius: BorderRadius.circular(100),
  );

  // Accept / Decline are wired in the pending-accept task; rendered here so the
  // pending layout is correct.
  Widget _buildPendingActions() {
    // Keep the buttons above the phone's system navigation bar / gesture area.
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          horizontalPadding,
          12.h,
          horizontalPadding,
          16.h,
        ),
        child: Row(
          children: [
            Expanded(
              child: SealedCircularButton(
                label: "Decline",
                onTap: _acceptingInvite ? () {} : _declineInvite,
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                textColor: Colors.white.withValues(alpha: 0.9),
                enableGlassBlur: true,
              ),
            ),
            Gap(16.w),
            Expanded(
              child: SealedCircularButton(
                label: "Accept",
                loading: _acceptingInvite,
                onTap: _acceptInvite,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeleteAliasButton extends StatefulWidget {
  const _DeleteAliasButton({this.onTap});

  final VoidCallback? onTap;

  @override
  State<_DeleteAliasButton> createState() => _DeleteAliasButtonState();
}

class _DeleteAliasButtonState extends State<_DeleteAliasButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 100),
        opacity: _pressed ? 0.6 : 1.0,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 100),
          scale: _pressed ? 0.9 : 1.0,
          child: SvgPicture.asset("assets/svg/chat/delete.svg"),
        ),
      ),
    );
  }
}

class _MiniAcceptButton extends StatefulWidget {
  const _MiniAcceptButton({this.onTap});

  final VoidCallback? onTap;

  @override
  State<_MiniAcceptButton> createState() => _MiniAcceptButtonState();
}

class _MiniAcceptButtonState extends State<_MiniAcceptButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 100),
        opacity: _pressed ? 0.6 : 1.0,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 100),
          scale: _pressed ? 0.9 : 1.0,
          child: Icon(Icons.check, size: 24.w, color: primaryColor),
        ),
      ),
    );
  }
}

class _SendButton extends StatefulWidget {
  const _SendButton({this.onTap});

  final VoidCallback? onTap;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 70),
        scale: _pressed ? 0.9 : 1,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 70),
          opacity: widget.onTap == null ? 0.4 : (_pressed ? 0.8 : 1),
          child: SvgPicture.asset("assets/svg/chat/send.svg", width: 24.w),
        ),
      ),
    );
  }
}

/// Sealed-style "N new messages" pill shown above the composer while the user
/// is scrolled up. Mirrors the privacy pill's glass look (blur + primary tint),
/// adds a down arrow and tap-to-jump with a press scale.
class _NewMessagesPill extends StatefulWidget {
  const _NewMessagesPill({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  State<_NewMessagesPill> createState() => _NewMessagesPillState();
}

class _NewMessagesPillState extends State<_NewMessagesPill> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final label = widget.count == 1
        ? '1 new message'
        : '${widget.count} new messages';
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 100),
        scale: _pressed ? 0.94 : 1,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(100),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 8.h, horizontal: 14.w),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(100),
                color: primaryColor.withValues(alpha: 0.16),
                border: Border.all(
                  color: primaryColor.withValues(alpha: 0.4),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall!.copyWith(color: primaryColor),
                  ),
                  Gap(6.w),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18.w,
                    color: primaryColor,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A single message group entry: optional timestamp header, the bubble, and a
/// single TX-success ("Sent") line shown only on the last of an outgoing run.
///
/// Long-pressing the bubble enters selection mode: the text becomes
/// selectable (for precise character selection) and a copy/close action row
/// appears under the bubble. Selection state is owned by the screen so only
/// one bubble can be in selection mode at a time.
class _Message extends StatelessWidget {
  const _Message({
    required this.group,
    required this.selecting,
    required this.onSelect,
    required this.onClose,
  });

  final GroupedChatMessage group;
  final bool selecting;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final m = group.message;
    final isOutgoing = m.isOutgoing;
    final textStyle = Theme.of(context).textTheme.bodyMedium!.copyWith(
      color: isOutgoing
          ? Theme.of(context).scaffoldBackgroundColor
          : Colors.white.withValues(alpha: 0.95),
    );
    return Column(
      crossAxisAlignment: isOutgoing
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (group.showTimestamp) ...[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 4.w, vertical: 4.h),
            child: Text(
              DateFormat('HH:mm').format(m.timestamp),
              style: Theme.of(context).textTheme.titleSmall!.copyWith(
                color: neutralColor.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
        Opacity(
          opacity: m.isPending ? 0.6 : 1,
          child: GestureDetector(
            onLongPress: selecting
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    onSelect();
                  },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Tail/arrow renders only on the last bubble of a group.
                if (group.isLastInGroup)
                  Positioned(
                    right: isOutgoing ? 0 : null,
                    left: isOutgoing ? null : 0,
                    bottom: 0,
                    child: SvgPicture.asset(
                      "assets/svg/chat/pointer.svg",
                      colorFilter: ColorFilter.mode(
                        isOutgoing ? primaryColor : cardColor,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                Container(
                  padding: EdgeInsets.symmetric(
                    vertical: 14.h,
                    horizontal: 12.w,
                  ),
                  decoration: BoxDecoration(
                    color: isOutgoing ? primaryColor : cardColor,
                    borderRadius: BorderRadius.circular(20.r),
                  ),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.8,
                  ),
                  child: selecting
                      ? SelectableText(m.content, style: textStyle)
                      : Text(m.content, style: textStyle),
                ),
              ],
            ),
          ),
        ),
        // Copy/close row smoothly grows + fades in when the bubble is held
        // into selection mode, and shrinks + fades out on close. AnimatedSwitcher
        // swaps between the action row and a zero-size placeholder so both the
        // enter and exit transitions animate.
        // AnimatedSwitcher's internal Stack centers children, overriding the
        // Column's crossAxisAlignment. Wrap in Align to pin the action row to
        // the bubble's side.
        Align(
          alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SizeTransition(
                sizeFactor: anim,
                axisAlignment: -1,
                child: child,
              ),
            ),
            child: !selecting
                ? const SizedBox.shrink(key: ValueKey('no-actions'))
                : Padding(
                    key: const ValueKey('actions'),
                    padding: EdgeInsets.only(top: 6.h),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _BubbleAction(
                          icon: Icons.copy_rounded,
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: m.content));
                            onClose();
                            showInfoSnackBar(context, 'Copied to clipboard');
                          },
                        ),
                        Gap(8.w),
                        _BubbleAction(
                          icon: Icons.close_rounded,
                          onTap: onClose,
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        if (group.showStatus) ...[
          Gap(4.h),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Sent",
                style: Theme.of(context).textTheme.titleSmall!.copyWith(
                  color: neutralColor.withValues(alpha: 0.8),
                ),
              ),
              Gap(4.w),
              Icon(Icons.check, color: primaryColor, size: 12.w),
            ],
          ),
        ],
      ],
    );
  }
}

/// Circular icon button shown under a bubble in selection mode.
/// Scales down while pressed for tap feedback.
class _BubbleAction extends StatefulWidget {
  const _BubbleAction({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_BubbleAction> createState() => _BubbleActionState();
}

class _BubbleActionState extends State<_BubbleAction> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 70),
        scale: _pressed ? 0.85 : 1,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 70),
          opacity: _pressed ? 0.8 : 1,
          child: Container(
            padding: EdgeInsets.all(10.w),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(12.r),
            ),
            child: Icon(
              widget.icon,
              size: 16.w,
              color: Colors.white.withValues(alpha: 0.9),
            ),
          ),
        ),
      ),
    );
  }
}
