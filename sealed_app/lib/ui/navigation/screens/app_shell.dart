import 'dart:async';
import 'package:sealed_app/core/log.dart';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/features/messaging/wake_nonce_queue.dart';
import 'package:sealed_app/features/notifications/notification_service.dart';
import 'package:sealed_app/infra/local/database.dart';
import 'package:sealed_app/providers/chat_controller.dart';
import 'package:sealed_app/providers/connectivity_provider.dart';
import 'package:sealed_app/providers/indexer_provider.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:sealed_app/ui/chat/screens/chat.dart';
import 'package:sealed_app/ui/navigation/navigator_key.dart';
import 'package:sealed_app/ui/navigation/nav_tab.dart';
import 'package:sealed_app/ui/navigation/screens/main_shell.dart';
import 'package:sealed_app/ui/onboarding/screens/pin_setup.dart';
import 'package:sealed_app/ui/onboarding/screens/welcome.dart';
import 'package:sealed_app/ui/shared/screens/error_screen.dart';
import 'package:sealed_app/ui/shared/widgets/loading_screens.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether AppShell must withhold the DB-touching wallet/keys/user subtree
/// (showing only a loading backdrop under SessionLockGate's lock screen),
/// instead of mounting that subtree while locked.
///
/// True ONLY before the first unlock of a launch. Until then those providers
/// have never resolved, so `userProvider.build()` (→ restoreSession /
/// syncMessages → LocalDatabase) would run while the DEK is null and throw
/// "LocalDatabase accessed while PIN session is not unlocked". Once the
/// session has unlocked once ([hasUnlockedThisLaunch]) the providers hold
/// cached data and re-lock keeps the subtree mounted (no re-resolve,
/// no flicker). `bootstrapping` is handled earlier and returns false here.
@visibleForTesting
bool shouldGateBehindLock(PinPhase phase, bool hasUnlockedThisLaunch) =>
    phase == PinPhase.locked && !hasUnlockedThisLaunch;

/// Root shell that handles app-level state and navigation.
///
/// Uses clean architecture with AsyncNotifier pattern:
/// - walletProvider: handles local wallet state (no external wallet needed!)
/// - keysProvider: handles cryptographic keys state
/// - userProvider: handles user registration state
///
/// All providers auto-initialize when watched.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  bool _isOfflineBannerShowing = false;
  StreamSubscription<void>? _syncSubscription;
  StreamSubscription<NotificationPayload>? _tapSubscription;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _openedAppSubscription;

  /// Inactivity lock timer — fires the lock action after
  /// [_lockGraceDuration] of continuous background. Cancelled on resume so
  /// quick foreground hops (e.g., pulling notification shade or Control
  /// Centre, Face ID confirmation) do NOT lock the app. See SPEC.md §1.
  Timer? _lockTimer;
  static const Duration _lockGraceDuration = Duration(seconds: 25);

  /// True once the PIN session has reached `unlocked` at least once this
  /// launch. Gates the DB-touching wallet/keys/user subtree: before the
  /// first unlock there is no cached AsyncData, so resolving those providers
  /// while the DEK is null throws "LocalDatabase accessed while PIN session
  /// is not unlocked". After the first unlock we keep them mounted across
  /// re-locks; SessionLockGate paints the lock screen above (see build()).
  bool _hasUnlockedThisLaunch = false;

  // Interrupted-onboarding self-heal latch: ensures we trigger key re-derivation
  // at most once when a wallet exists but keys are missing (see build()).
  bool _keyDeriveAttempted = false;

  /// Route name for the mandatory onboarding PIN-setup push. We use this
  /// to prevent stacking duplicates (instead of a one-shot bool latch
  /// that wouldn't re-fire after a logout-then-create cycle).
  static const String _pinSetupRouteName = '/pin-setup-mandatory';

  /// Returns true iff the topmost route on [navState] is the mandatory
  /// PIN-setup screen — used to make the post-frame trigger idempotent
  /// while still allowing it to re-fire after a logout.
  bool _isPinSetupRouteOnTop(NavigatorState navState) {
    String? topName;
    navState.popUntil((r) {
      topName = r.settings.name;
      return true; // popUntil with `true` is a no-op; just inspects top.
    });
    return topName == _pinSetupRouteName;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Wire LocalDatabase to fetch the DEK from the unlocked PIN session.
    // Throws if accessed while locked — but the AppShell prevents that by
    // gating any DB-touching child behind the unlock screen.
    LocalDatabase.dekResolver = () async {
      final session = ref.read(pinSessionProvider);
      final dek = session.dek;
      if (dek == null) {
        throw StateError(
          'LocalDatabase accessed while PIN session is not unlocked',
        );
      }
      return dek;
    };

    // Wire the silent-push wake handler with bounded sync callback.
    // Fire-and-forget — the binder awaits MessageService, which settles
    // asynchronously. Until it lands the wake handler stays fail-closed
    // (kResultNoData), which is the safe default.
    Future.microtask(() async {
      try {
        await ref.read(silentPushBinderProvider.future);
      } catch (e) {
        Log.d('[App] ⚠️ Silent-push binder failed: $e');
      }
    });

    // Listen for push notification sync triggers
    _syncSubscription = NotificationService().onShouldSync.listen((_) {
      Log.d('[App] 📥 Push notification received, triggering sync...');
      ref.read(messagesNotifierProvider.notifier).syncMessages();
    });

    // Listen for notification taps to navigate to conversation
    _tapSubscription = NotificationService().onNotificationTap.listen((
      payload,
    ) async {
      Log.d('[App] 👆 Notification tapped: ${payload.conversationWallet}');
      await _handleNotificationTap(payload);
    });

    // Tapping an OS-rendered push (the current visible-alert FCM/APNs) opens the
    // app here, not via onNotificationTap (that fires only for app-presented
    // local notifications). The payload is content-free, so just land on Chats.
    FirebaseMessaging.instance.getInitialMessage().then((msg) {
      if (msg != null && mounted) _routeToChatsTab();
    });
    _openedAppSubscription = FirebaseMessaging.onMessageOpenedApp.listen((_) {
      if (mounted) _routeToChatsTab();
    });

    // Android: re-register with indexer when FCM token rotates.
    // Gated on user opt-in (targetedPushEnabled). iOS uses a stable APNs token
    // via MethodChannel — no refresh subscription needed on that platform.
    if (Platform.isAndroid) {
      _tokenRefreshSubscription = FirebaseMessaging.instance.onTokenRefresh
          .listen((newToken) async {
            Log.d(
              '[App] 🔄 FCM token refreshed, re-registering with indexer...',
            );
            try {
              final settings = await ref.read(
                appSettingsServiceProvider.future,
              );
              if (settings.targetedPushEnabled) {
                final indexer = await ref.read(indexerServiceProvider.future);
                await indexer.registerTargetedPush();
                // Mirror to alias rows so any opted-in alias contacts stay
                // registered against the freshly-rotated FCM token.
                await indexer.registerEnabledAliasViewKeys();
              }
            } catch (e) {
              Log.d('[App] ⚠️ FCM token refresh re-register failed: $e');
            }
          });
    }

    // ── Boot reconciler: re-sync alias push rows against stored per-alias
    // flags. Covers the relaunch / reinstall case where SharedPreferences
    // persist but the indexer's `targeted_push_tokens` table may have lost
    // rows (db reset, blinded_id rotated, etc.). Best-effort + fire-and-
    // forget; failures only log.
    Future.microtask(() async {
      try {
        final settings = await ref.read(appSettingsServiceProvider.future);
        if (!settings.targetedPushEnabled) return;
        final indexer = await ref.read(indexerServiceProvider.future);
        // Re-register the main row so already-opted-in users pick up newly
        // added registration fields (e.g. `wallet`, required for KEM
        // first-contact push) without having to re-toggle the setting. The
        // register is an idempotent upsert keyed by blinded_id.
        await indexer.registerTargetedPush();
        await indexer.registerEnabledAliasViewKeys();
      } catch (e) {
        Log.d('[App] ⚠️ Boot push reconcile failed: $e');
      }
    });
  }

  /// Pop any pushed routes and select the Chats tab. Used when a push has no
  /// conversation to deep-link to (the current content-free pushes).
  void _routeToChatsTab() {
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    ref.read(navTabProvider.notifier).state = NavTab.chats;
  }

  Future<void> _handleNotificationTap(NotificationPayload payload) async {
    // Get the conversation wallet from payload
    String? contactWallet = payload.conversationWallet;
    String? contactUsername;

    // If we don't have the wallet, try to look it up via accountPubkey
    if (contactWallet == null && payload.accountPubkey != null) {
      try {
        // Sync messages first so the message is available locally
        await ref.read(messagesNotifierProvider.notifier).syncMessages();

        final messageRepo = ref.read(messageRepositoryProvider);
        final message = await messageRepo.getMessageByPubkey(
          payload.accountPubkey!,
        );
        if (message != null) {
          contactWallet = message.isOutgoing
              ? message.recipientWallet
              : message.senderWallet;
          contactUsername = message.isOutgoing
              ? message.recipientUsername
              : message.senderUsername;
        }
      } catch (e) {
        Log.d('[App] ⚠️ Failed to lookup message: $e');
      }
    }

    // Fallback: try messageId as accountPubkey (legacy payload format)
    if (contactWallet == null && payload.messageId != null) {
      try {
        final messageRepo = ref.read(messageRepositoryProvider);
        final message = await messageRepo.getMessageByPubkey(
          payload.messageId!,
        );
        if (message != null) {
          contactWallet = message.isOutgoing
              ? message.recipientWallet
              : message.senderWallet;
          contactUsername = message.isOutgoing
              ? message.recipientUsername
              : message.senderUsername;
        }
      } catch (e) {
        Log.d('[App] ⚠️ Failed to lookup message by messageId: $e');
      }
    }

    if (contactWallet == null) {
      // Content-free push (no conversation data by design) — we can't open a
      // specific thread, so at least bring the user to the Chats tab.
      Log.d('[App] 👆 No convo in payload — routing to Chats tab');
      _routeToChatsTab();
      return;
    }

    // Look up contact username if not already resolved
    if (contactUsername == null) {
      try {
        final messageRepo = ref.read(messageRepositoryProvider);
        contactUsername = await messageRepo.getContactUsername(contactWallet);
      } catch (e) {
        Log.d('[App] ⚠️ Failed to lookup contact username: $e');
      }
    }

    // Navigate to the conversation
    navigatorKey.currentState?.push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => ChatScreen(
          identity: WalletChatId(contactWallet!, username: contactUsername),
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position:
                Tween<Offset>(
                  begin: const Offset(1.0, 0.0),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lockTimer?.cancel();
    _lockTimer = null;
    _syncSubscription?.cancel();
    _tapSubscription?.cancel();
    _tokenRefreshSubscription?.cancel();
    _openedAppSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Inactivity lock: arm timer on background, cancel on resume.
    // Pulling notification shade / Control Centre triggers a brief
    // inactive→resumed cycle; we ignore `inactive` so transient OS UI does
    // not lock the app. Only `paused` and `hidden` arm the timer.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Idempotent: if a timer is already running (e.g., paused→hidden
      // transition), don't restart it — the original deadline still applies.
      _lockTimer ??= Timer(_lockGraceDuration, _maybeLockNow);
    } else if (state == AppLifecycleState.resumed) {
      _lockTimer?.cancel();
      _lockTimer = null;
      // Drain any wake nonces queued by the background FCM isolate.
      _drainWakeQueue();
    }
    // `inactive` deliberately ignored — see comment above.
  }

  /// Lock the session if a PIN is configured. Called by the inactivity
  /// timer. No-op when running PIN-less ("noPin" phase).
  void _maybeLockNow() {
    _lockTimer = null;
    if (!mounted) return;
    final pin = ref.read(pinServiceProvider);
    pin.isPinSet().then((isSet) {
      if (!mounted) return;
      if (isSet) {
        ref.read(pinSessionProvider.notifier).lock();
      }
    });
  }

  /// Drain any wake nonces persisted by the background FCM isolate and trigger
  /// a bounded sync if the DEK is unlocked. If the DEK is locked, moves normal
  /// queue entries into the pending-unlock queue so they survive until the
  /// user enters their PIN (no nonce is lost).
  ///
  /// Called on [AppLifecycleState.resumed] and after a locked→unlocked
  /// transition (via [ref.listen] in [build]).
  Future<void> _drainWakeQueue({bool pendingUnlock = false}) async {
    if (!mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final queue = WakeNonceQueue(prefs);
      final pinSession = ref.read(pinSessionProvider);

      if (pendingUnlock) {
        // Called right after unlock — drain push pre-staged envelopes into the
        // DB first (instant, no network), then the pending-unlock nonce queue.
        ref.read(messagesNotifierProvider.notifier).drainWakeStage();
        final entries = await queue.drainPendingUnlock();
        if (entries.isNotEmpty && mounted) {
          Log.d(
            '[App] 🔔 Draining ${entries.length} pending-unlock wake nonces → sync',
          );
          ref.read(messagesNotifierProvider.notifier).syncMessages();
        }
        return;
      }

      if (pinSession.phase == PinPhase.unlocked) {
        // DEK present — drain staged envelopes (instant) + the nonce queue.
        ref.read(messagesNotifierProvider.notifier).drainWakeStage();
        final entries = await queue.drain(DateTime.now());
        if (entries.isNotEmpty && mounted) {
          Log.d('[App] 🔔 Draining ${entries.length} wake nonces → sync');
          ref.read(messagesNotifierProvider.notifier).syncMessages();
        }
      } else if (pinSession.phase == PinPhase.locked) {
        // DEK not yet available — move to pending-unlock queue so nothing
        // is dropped while the user hasn't entered their PIN.
        await queue.moveNormalToPending();
      }
      // noPin / bootstrapping — no sync possible, queue remains.
    } catch (e) {
      Log.d('[App] ⚠️ _drainWakeQueue failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listen for connectivity changes and show/hide persistent snackbar
    // Drain pending-unlock wake queue on locked→unlocked transition.
    ref.listen<PinSessionState>(pinSessionProvider, (previous, next) {
      if (previous?.phase == PinPhase.locked &&
          next.phase == PinPhase.unlocked) {
        _drainWakeQueue(pendingUnlock: true);
      }
    });

    ref.listen<AsyncValue<bool>>(connectivityStatusProvider, (previous, next) {
      final isOnline = next.whenOrNull(data: (v) => v) ?? true;
      if (!isOnline && !_isOfflineBannerShowing) {
        _isOfflineBannerShowing = true;
        // Use custom snackbar for persistent offline warning
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        final snackBar = SnackBar(
          content: Row(
            children: [
              Icon(
                Icons.wifi_off,
                color: Colors.white.withValues(alpha: 0.9),
                size: 20,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'No internet connection',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: Colors.orange.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          duration: const Duration(days: 1), // persistent until dismissed
          dismissDirection: DismissDirection.none,
        );
        ScaffoldMessenger.of(context).showSnackBar(snackBar);
      } else if (isOnline && _isOfflineBannerShowing) {
        _isOfflineBannerShowing = false;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }
    });

    // PIN gate: bootstrap the DEK, then either withhold the subtree, force
    // PIN setup, or proceed with the existing wallet/keys/user flow.
    //
    // The lock screen itself is NOT rendered here. It lives in
    // SessionLockGate, mounted above the root Navigator via
    // MaterialApp.builder, so it covers pushed routes (ChatScreen, settings,
    // dialogs) too — an overlay inside this home-route subtree would paint
    // BELOW them. AppShell keeps the localWallet/keys/user providers mounted
    // across lock cycles, so on unlock the AsyncNotifier does NOT re-resolve
    // and there is no SplashScreen flicker between the unlock animation and
    // MainShell. See SPEC.md §5.
    final pinSession = ref.watch(pinSessionProvider);
    if (pinSession.phase == PinPhase.bootstrapping) {
      return const LoadingBackdrop();
    }

    // Gate the DB-touching subtree behind the FIRST unlock.
    //
    // The contract is stated at initState (≈L104): "AppShell prevents
    // [locked DB access] by gating any DB-touching child behind the unlock
    // screen." On re-lock the providers already hold cached AsyncData, so
    // keeping them mounted is fine — but on the FIRST locked state of a
    // launch they have never resolved. userProvider.build() would then run
    // restoreSession()/syncMessages() → LocalDatabase while the DEK is
    // still null and throw, tripping ErrorScreen. Reproduces on hot restart
    // and on a genuine cold launch with a PIN set.
    //
    // So: GATE before the first unlock (loading backdrop only, lock screen
    // painted above by SessionLockGate), keep mounted after. Once unlocked
    // we latch the flag, so subsequent re-locks keep the providers mounted
    // (no re-resolve, no SplashScreen flicker). Decision lives in
    // [shouldGateBehindLock] so it can be unit-tested.
    if (pinSession.phase == PinPhase.unlocked) {
      _hasUnlockedThisLaunch = true;
    }
    if (shouldGateBehindLock(pinSession.phase, _hasUnlockedThisLaunch)) {
      return const LoadingBackdrop();
    }

    // PIN/DEK bootstrap failed (keychain unreadable, DB undeletable, etc.).
    // Render the error instead of watching the data providers (which would hit
    // a locked DB with no DEK) or leaving an eternal LoadingBackdrop. Dismiss
    // the lock overlay so the error is actually visible.
    if (pinSession.phase == PinPhase.error) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final readyNotifier = ref.read(appContentReadyProvider.notifier);
        if (!readyNotifier.state) readyNotifier.state = true;
      });
      return ErrorScreen(error: pinSession.error ?? 'Initialization failed');
    }

    // Watch local wallet state - this triggers auto-initialization
    final walletAsync = ref.watch(walletProvider);

    // Watch keys state
    final keysAsync = ref.watch(keysProvider);

    // Watch user state
    final userAsync = ref.watch(userProvider);

    // After the wallet is ready and the user has reached the main app,
    // ensure the user is prompted to set a PIN (mandatory) if they have
    // not yet done so. This must happen post-frame so we have a Navigator.
    //
    // The route-name check (instead of a one-shot bool flag) is what
    // makes this re-fire after Logout → create-new-wallet without an
    // app restart: `clearPinAndDekState` in performLogout resets
    // pinSession back to needsPinSetup=true, and we'll only push if no
    // PinSetupScreen is currently mounted.
    walletAsync.whenData((walletState) {
      if (walletState.hasWallet && pinSession.needsPinSetup) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          final navState = navigatorKey.currentState;
          if (navState == null) return;
          if (_isPinSetupRouteOnTop(navState)) return;
          await navState.push(
            MaterialPageRoute(
              settings: const RouteSettings(name: _pinSetupRouteName),
              builder: (_) => const PinSetupScreenV2(mandatory: true),
              fullscreenDialog: true,
            ),
          );
          if (mounted) {
            ref.read(pinSessionProvider.notifier).clearPinSetupPrompt();
            setState(() {});
          }
        });
      }
    });

    // Handle wallet initialization states.
    //
    // Two loading visuals:
    //   - Post-create flow (PIN not yet set, `needsPinSetup` true): plain
    //     spinner on black — the user just came from the create-account
    //     screen and the gif would feel out of place.
    //   - Post-unlock flow (PIN set): null, so the persistent pulsing-keypad
    //     backdrop continues animating from the lock screen straight
    //     into the chat list. No spinner.
    final loadingWidget = pinSession.needsPinSetup
        ? const SpinnerScreen()
        : null;

    // Error visuals must be reachable. appContentReadyProvider is what tells
    // SessionLockGate to drop the post-unlock lock overlay; if we render an
    // ErrorScreen without flipping it, the pulsing keypad stays painted on top
    // and the user sees an eternal lock with no input accepted. So every error
    // path goes through this helper, which dismisses the overlay post-frame.
    Widget errorScreen(Object error) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final readyNotifier = ref.read(appContentReadyProvider.notifier);
        if (!readyNotifier.state) readyNotifier.state = true;
      });
      return ErrorScreen(error: error);
    }

    final Widget? main = walletAsync.when(
      loading: () => loadingWidget,
      error: (error, stack) => errorScreen(error),
      data: (onboardingState) {
        // No wallet - show setup screen
        if (onboardingState.phase == OnboardingPhase.noWallet) {
          return const WelcomeScreen();
        }

        // Error state
        if (onboardingState.phase == OnboardingPhase.error) {
          return errorScreen(onboardingState.error ?? 'Unknown error');
        }

        return keysAsync.when(
          loading: () => loadingWidget,
          error: (error, stack) => errorScreen(error),
          data: (keys) {
            if (keys == null) {
              // Interrupted-onboarding self-heal. The wallet exists but keys
              // were never derived — app killed between wallet creation and
              // key save, or keys cleared by the keystore-corruption recovery.
              // Keys are deterministically re-derivable from the local wallet,
              // so derive them once instead of spinning forever. If derivation
              // fails it surfaces via keysAsync.error → errorScreen above.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || _keyDeriveAttempted) return;
                // The wallet-restore flow derives keys itself; by the time this
                // post-frame fires it may already have populated them. Re-check
                // so we don't fire a redundant second derive (which re-runs the
                // keystore-corruption wipe and can flash an error/loading frame).
                if (ref.read(keysProvider).value != null) return;
                _keyDeriveAttempted = true;
                ref.read(keysProvider.notifier).deriveKeysFromLocalWallet();
              });
              return loadingWidget;
            }
            return userAsync.when(
              loading: () => loadingWidget,
              error: (error, stack) => errorScreen(error),
              data: (userState) {
                Log.d(
                  'AppShell: userState: $userState | walletState: $onboardingState',
                );

                if (userState.phase == UserPhase.loading) {
                  return loadingWidget;
                }

                // Content is ready. Signal SessionLockGate so it can dismiss
                // the post-unlock lock overlay (pulsing keypad) and reveal the
                // app. Post-frame + guard so we only flip the flag once and
                // never mutate a provider during build.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  final readyNotifier = ref.read(
                    appContentReadyProvider.notifier,
                  );
                  if (!readyNotifier.state) readyNotifier.state = true;
                });

                // All set - show main app
                return const MainShell();
              },
            );
          },
        );
      },
    );

    // Persistent backdrop only paints while foreground is null (loading
    // states). On the returning-user path the lock overlay (pulsing keypad)
    // covers this until MainShell is ready; this black backdrop only shows
    // on the brief pre-lock bootstrapping frame. Once MainShell/SetupScreen
    // is ready it owns the screen.
    return main ?? const LoadingBackdrop();
  }
}
