import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/ui/onboarding/widgets/legacy_migration_dialog.dart';
import 'package:sealed_app/ui/chats/screens/chats.dart';
import 'package:sealed_app/ui/contacts/contacts.dart';
import 'package:sealed_app/ui/navigation/nav_tab.dart';
import 'package:sealed_app/ui/navigation/screens/coming_soon_screen.dart';
import 'package:sealed_app/ui/navigation/widgets/nav_bar_v2.dart';
import 'package:sealed_app/ui/settings/screens/settings.dart';
import 'package:sealed_app/ui/shared/widgets/search_top_bar.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';

/// Currently-selected bottom-nav tab. Exposed as a provider so non-widget code
/// (e.g. a notification tap handled in AppShell) can switch tabs — a tapped push
/// routes here to land the user on the Chats tab.
final navTabProvider = StateProvider<NavTab>((ref) => NavTab.chats);

/// Root authenticated shell that hosts the main tabs and the bottom navbar.
///
/// Uses [IndexedStack] so each tab keeps its state when switched away,
/// matching native mobile navigation expectations.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  NavTab _current = NavTab.chats;

  /// Stable keys for tabs hosting a search top bar, so the shell can collapse
  /// their expanded search when the tab is switched away from.
  final Map<NavTab, GlobalKey> _screenKeys = {
    NavTab.chats: GlobalKey(),
    NavTab.contacts: GlobalKey(),
  };

  /// Guards against double-firing the post-migration dialog if the shell
  /// rebuilds (e.g., due to a tab switch) before the async check completes.
  bool _migrationNoticeChecked = false;

  /// Guards against repeating the publishKeys check on every rebuild.
  bool _publishKeysChecked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowLegacyMigrationNotice();
      _maybePublishKeysOnBoot();
    });
  }

  /// Best-effort: if the wallet has credits but on-chain key bundle is stale
  /// or missing, publish it once per app boot so other clients can resolve
  /// our encryption/scan/PQ pubkeys. Idempotent — the notifier no-ops when
  /// the bundle already matches, when credits are unavailable, or when the
  /// [pqPublishBlockedFlagKey] flag has been set by a restore mismatch.
  Future<void> _maybePublishKeysOnBoot() async {
    if (_publishKeysChecked) return;
    _publishKeysChecked = true;
    await ref.read(keyManagementProvider.notifier).ensurePublished();
  }

  /// Show the one-shot post-migration informational dialog if it has been
  /// armed by a successful 12-word legacy mnemonic restore. Idempotent: the
  /// service consumes the trigger flag in [markShown], so subsequent shell
  /// mounts find `shouldShow() == false`.
  Future<void> _maybeShowLegacyMigrationNotice() async {
    if (_migrationNoticeChecked) return;
    _migrationNoticeChecked = true;

    final service = ref.read(migrationNoticeServiceProvider);
    if (!await service.shouldShow()) return;
    if (!mounted) return;

    await showLegacyMigrationDialog(context);
    await service.markShown();
  }

  Widget _screenFor(NavTabSpec spec) {
    if (spec.comingSoon) {
      return ComingSoonScreen(title: spec.label, svgAsset: spec.svgAsset);
    }
    switch (spec.tab) {
      case NavTab.chats:
        return ChatsScreen(key: _screenKeys[NavTab.chats]);
      case NavTab.settings:
        return const SettingsScreen();
      case NavTab.contacts:
        return ContactsScreen(key: _screenKeys[NavTab.contacts]);
      case NavTab.files:
        // Covered by comingSoon above; kept exhaustive.
        return ComingSoonScreen(title: spec.label, svgAsset: spec.svgAsset);
    }
  }

  /// Switch tab + collapse any expanded search on the tab being left. Single
  /// entry point for both a navbar tap and an external (provider-driven) switch.
  void _switchTo(NavTab tab) {
    if (tab == _current) return;
    final outgoing = _screenKeys[_current]?.currentState;
    if (outgoing is SearchCollapsible) {
      (outgoing as SearchCollapsible).collapseSearch();
    }
    setState(() => _current = tab);
  }

  @override
  Widget build(BuildContext context) {
    const tabs = kNavBarV2Tabs;
    final currentIndex = tabs.indexWhere((t) => t.tab == _current);

    // External switches (e.g. a tapped push routing to Chats) flow through the
    // provider; a navbar tap also writes it, so this is the single source.
    ref.listen<NavTab>(navTabProvider, (_, next) => _switchTo(next));

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: IndexedStack(
        index: currentIndex,
        children: [for (final spec in tabs) _screenFor(spec)],
      ),
      bottomNavigationBar: NavBarV2(
        tabs: tabs,
        currentTab: _current,
        onTabSelected: (tab) => ref.read(navTabProvider.notifier).state = tab,
      ),
    );
  }
}
