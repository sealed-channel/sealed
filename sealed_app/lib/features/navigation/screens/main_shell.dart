import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/features/chat/screens/chat_list.dart';
import 'package:sealed_app/features/navigation/nav_tab.dart';
import 'package:sealed_app/features/navigation/screens/coming_soon_screen.dart';
import 'package:sealed_app/features/navigation/widgets/sealed_bottom_nav_bar.dart';
import 'package:sealed_app/features/settings/screens/settings_screen.dart';
import 'package:sealed_app/features/settings/screens/settings_screen.dart';

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

  Widget _screenFor(NavTabSpec spec) {
    if (spec.comingSoon) {
      return ComingSoonScreen(title: spec.label, svgAsset: spec.svgAsset);
    }
    switch (spec.tab) {
      case NavTab.chats:
        return const ChatListScreen();
      case NavTab.settings:
        return const SettingsScreen();
      case NavTab.contacts:
      case NavTab.files:
        // Covered by comingSoon above; kept exhaustive.
        return ComingSoonScreen(title: spec.label, svgAsset: spec.svgAsset);
    }
  }

  @override
  Widget build(BuildContext context) {
    const tabs = kDefaultNavTabs;
    final currentIndex = tabs.indexWhere((t) => t.tab == _current);

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: IndexedStack(
        index: currentIndex,
        children: [for (final spec in tabs) _screenFor(spec)],
      ),
      bottomNavigationBar: SealedBottomNavBar(
        tabs: tabs,
        currentTab: _current,
        onTabSelected: (tab) {
          if (tab != _current) setState(() => _current = tab);
        },
      ),
    );
  }
}
