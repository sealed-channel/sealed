import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/service_locator.dart';

import 'package:sealed_app/features/auth/screens/lock_screen.dart';
import 'package:sealed_app/features/auth/screens/pin_setup_screen.dart';
import 'package:sealed_app/features/auth/screens/wallet_setup.dart';
import 'package:sealed_app/features/chat/screens/chat_detail.dart';
import 'package:sealed_app/features/navigation/screens/main_shell.dart';
import 'package:sealed_app/local/database.dart';
import 'package:sealed_app/models/conversation.dart';
import 'package:sealed_app/providers/app_providers.dart';
import 'package:sealed_app/providers/connectivity_provider.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/local_wallet_provider.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:sealed_app/services/notification_service.dart';
import 'package:sealed_app/shared/widgets/theme.dart';

/// Global navigator key for notification navigation
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class SealedApp extends StatelessWidget {
  const SealedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sealed',
      navigatorKey: navigatorKey,
      theme: sealedTheme,
      home: Container(
        decoration: BoxDecoration(gradient: sealedBackgroundGradient),
        child: const AppShell(),
      ),
    );
  }
}

/// Root shell that handles app-level state and navigation.
///
/// Uses clean architecture with AsyncNotifier pattern:
/// - localWalletProvider: handles local wallet state (no external wallet needed!)
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

  /// Inactivity lock timer — fires the lock action after
  /// [_lockGraceDuration] of continuous background. Cancelled on resume so
  /// quick foreground hops (e.g., pulling notification shade or Control
  /// Centre, Face ID confirmation) do NOT lock the app. See SPEC.md §1.
  Timer? _lockTimer;
  static const Duration _lockGraceDuration = Duration(seconds: 25);

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
        print('[App] ⚠️ Silent-push binder failed: $e');
      }
    });

    // Listen for push notification sync triggers
    _syncSubscription = NotificationService().onShouldSync.listen((_) {
      print('[App] 📥 Push notification received, triggering sync...');
      ref.read(messagesNotifierProvider.notifier).syncMessages();
    });

    // Listen for notification taps to navigate to conversation
    _tapSubscription = NotificationService().onNotificationTap.listen((
      payload,
    ) async {
      print('[App] 👆 Notification tapped: ${payload.conversationWallet}');
      await _handleNotificationTap(payload);
    });
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

        final messageCache = ref.read(messageCacheProvider);
        final message = await messageCache.getMessageByPubkey(
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
        print('[App] ⚠️ Failed to lookup message: $e');
      }
    }

    // Fallback: try messageId as accountPubkey (legacy payload format)
    if (contactWallet == null && payload.messageId != null) {
      try {
        final messageCache = ref.read(messageCacheProvider);
        final message = await messageCache.getMessageByPubkey(
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
        print('[App] ⚠️ Failed to lookup message by messageId: $e');
      }
    }

    if (contactWallet == null) {
      print('[App] ⚠️ Cannot navigate: no conversation wallet');
      return;
    }

    // Look up contact username if not already resolved
    if (contactUsername == null) {
      try {
        final messageCache = ref.read(messageCacheProvider);
        contactUsername = await messageCache.getContactUsername(contactWallet);
      } catch (e) {
        print('[App] ⚠️ Failed to lookup contact username: $e');
      }
    }

    // Navigate to the conversation
    navigatorKey.currentState?.push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            ChatDetailScreen(
              conversation: Conversation(
                contactWallet: contactWallet!,
                contactUsername: contactUsername,
              ),
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

  @override
  Widget build(BuildContext context) {
    // Listen for connectivity changes and show/hide persistent snackbar
    ref.listen<AsyncValue<bool>>(connectivityStatusProvider, (previous, next) {
      final isOnline = next.whenOrNull(data: (v) => v) ?? true;
      if (!isOnline && !_isOfflineBannerShowing) {
        _isOfflineBannerShowing = true;
        // Use custom snackbar for persistent offline warning
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        final snackBar = SnackBar(
          content: const Row(
            children: [
              Icon(Icons.wifi_off, color: Colors.white, size: 20),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'No internet connection',
                  style: TextStyle(
                    color: Colors.white,
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

    // PIN gate: bootstrap the DEK, then either show LockScreen, force PIN
    // setup, or proceed with the existing wallet/keys/user flow.
    //
    // LockScreen is overlaid on top of the main subtree (Stack) rather
    // than replacing it. This keeps localWallet/keys/user providers
    // mounted across lock cycles — so on unlock the AsyncNotifier does
    // NOT re-resolve and there is no SplashScreen flicker between the
    // unlock animation and MainShell. See SPEC.md §5.
    final pinSession = ref.watch(pinSessionProvider);
    if (pinSession.phase == PinPhase.bootstrapping) {
      return const _QuantumLoading();
    }
    final isLocked = pinSession.phase == PinPhase.locked;

    // Watch local wallet state - this triggers auto-initialization
    final walletAsync = ref.watch(localWalletProvider);

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
              builder: (_) => const PinSetupScreen(mandatory: true),
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
    //   - Post-unlock flow (PIN set): null, so the persistent gif
    //     backdrop continues animating from the lock screen straight
    //     into the chat list. No spinner.
    final loadingWidget = pinSession.needsPinSetup
        ? const _SpinnerScreen()
        : null;
    final Widget? main = walletAsync.when(
      loading: () => loadingWidget,
      error: (error, stack) => ErrorScreen(error: error),
      data: (walletState) {
        // No wallet - show setup screen
        if (walletState.phase == WalletSetupPhase.noWallet) {
          return const WalletSetupScreen();
        }

        // Error state
        if (walletState.phase == WalletSetupPhase.error) {
          return ErrorScreen(error: walletState.error ?? 'Unknown error');
        }

        return keysAsync.when(
          loading: () => loadingWidget,
          error: (error, stack) => ErrorScreen(error: error),
          data: (keys) {
            if (keys == null) {
              return loadingWidget;
            }
            return userAsync.when(
              loading: () => loadingWidget,
              error: (error, stack) => ErrorScreen(error: error),
              data: (userState) {
                print(
                  'AppShell: userState: $userState | walletState: $walletState',
                );

                if (userState.phase == UserPhase.loading) {
                  return loadingWidget;
                }

                // All set - show main app
                return const MainShell();
              },
            );
          },
        );
      },
    );

    // Persistent backdrop only paints while foreground is null (loading
    // states). Once MainShell/SetupScreen is ready it owns the screen.
    // Keeping the backdrop conditional avoids the gif bleeding through
    // any transparent surfaces in the chat UI.
    return Stack(
      children: [
        if (main == null) const Positioned.fill(child: _QuantumLoading()),
        if (main != null) Positioned.fill(child: main),
        if (isLocked) const Positioned.fill(child: LockScreen()),
      ],
    );
  }
}

/// Plain centred spinner on black — used post-wallet-create while keys
/// derive and the user resolves. Distinct from the pre-bootstrap
/// quantum-gif backdrop so the create-account transition feels grounded.
class _SpinnerScreen extends StatelessWidget {
  const _SpinnerScreen();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: CircularProgressIndicator(color: primaryColor),
    );
  }
}

/// Black backdrop with the quantum-animation gif — used as the loading
/// surface for wallet/keys/user resolution so the visual is consistent
/// with the lock screen and onboarding flow. See SPEC.md §5.
///
/// Uses a manually-decoded ping-pong player (forwards then reversed) to
/// avoid the visible snap that `Image.asset` produces when a one-shot
/// gif loops back to frame 0.
class _QuantumLoading extends StatelessWidget {
  const _QuantumLoading();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: 100,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.8,
                width: double.infinity,
                child: const _PingPongGif(
                  asset: 'assets/quantum-animation.gif',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Local ping-pong gif player — same approach as the lock-screen
/// backdrop. Frames decoded once, played forwards then mirrored.
class _PingPongGif extends StatefulWidget {
  const _PingPongGif({required this.asset});
  final String asset;
  static const Duration _frameDuration = Duration(milliseconds: 50);

  @override
  State<_PingPongGif> createState() => _PingPongGifState();
}

class _PingPongGifState extends State<_PingPongGif>
    with SingleTickerProviderStateMixin {
  final List<ui.Image> _frames = [];
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final data = await rootBundle.load(widget.asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    for (var i = 0; i < codec.frameCount; i++) {
      final frame = await codec.getNextFrame();
      _frames.add(frame.image);
    }
    if (!mounted || _frames.isEmpty) return;
    final total = _PingPongGif._frameDuration * (_frames.length * 2);
    _controller = AnimationController(
      vsync: this,
      duration: total - const Duration(milliseconds: 2000),
    )..repeat();
    setState(() {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    for (final f in _frames) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || _frames.isEmpty) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value;
        final phase = t < 0.5 ? t * 2 : (1 - t) * 2;
        final idx = (phase * (_frames.length - 1)).round().clamp(
          0,
          _frames.length - 1,
        );
        return RawImage(image: _frames[idx], fit: BoxFit.cover);
      },
    );
  }
}

// ============================================================================
// PLACEHOLDER SCREENS
// ============================================================================

class ErrorScreen extends ConsumerWidget {
  final Object error;

  const ErrorScreen({super.key, required this.error});

  bool get _isSecureStorageCorruption {
    final msg = error.toString().toLowerCase();
    // Tighten the heuristic: only treat the error as secure-storage corruption
    // when the actual platform-channel/keystore signatures show up. SQLCipher
    // database errors (which contain "sqlcipher"/"cipher") are NOT keystore
    // corruption and must not match here.
    return msg.contains('bad_decrypt') ||
        msg.contains('badpaddingexception') ||
        msg.contains('keystoreexception') ||
        (msg.contains('platformexception') && msg.contains('secure'));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                'Something went wrong',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                _isSecureStorageCorruption
                    ? 'Your device\'s secure storage was reset. '
                          'Please set up your wallet again using your recovery phrase.'
                    : error.toString(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () async {
                  final storage = ref.read(flutterSecureStorageProvider);
                  await storage.deleteAll();
                  // Also delete the SQLCipher DB file — otherwise the
                  // next bootstrap creates a fresh DEK that does NOT
                  // match the stale on-disk DB, and writes silently
                  // fail with "attempt to write a readonly database".
                  await LocalDatabase.closeAndDelete();
                  ref.invalidate(localWalletProvider);
                  ref.invalidate(keysProvider);
                  ref.invalidate(userProvider);
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Reset & Start Fresh'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
