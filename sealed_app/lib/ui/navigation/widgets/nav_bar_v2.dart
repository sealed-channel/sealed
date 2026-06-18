import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/ui/navigation/nav_tab.dart';
import 'package:sealed_app/ui/shared/theme.dart';

/// Bottom navigation bar matching Figma Sealed App 1.0 (node 1:12662).
///
/// Flat dark bar (`#050a0a`) with a hairline top border, icon + label per tab.
/// Active tab: teal icon (`#6BFAD6`) + white label. Inactive: gray icon
/// (`#4E5551`) + soft gray label (`#AFB6AF`).
///
/// Stateless — caller owns [currentTab] / [onTabSelected]. See [MainShell].
class NavBarV2 extends StatelessWidget {
  const NavBarV2({
    super.key,
    required this.tabs,
    required this.currentTab,
    required this.onTabSelected,
  });

  final List<NavTabSpec> tabs;
  final NavTab currentTab;
  final ValueChanged<NavTab> onTabSelected;

  static const Color _bg = Color(0xFF050A0A);
  static const Color _topBorder = Color(0x1FFFFFFF); // white @ 12%
  static const Color _activeIcon = Color(0xFF6BFAD6);
  static const Color _inactiveIcon = Color(0xFF4E5551);
  static const Color _activeLabel = Colors.white;
  static const Color _inactiveLabel = Color(0xFFAFB6AF);

  @override
  Widget build(BuildContext context) {
    // Clamp to non-negative: when a modal route/sheet is pushed, the shell's
    // MediaQuery padding.bottom can drop to 0, making `0 - 12.h` negative and
    // tripping Padding's `isNonNegative` assertion (device-only — sim's home
    // indicator inset stays above 12.h).
    final bottomInset = (MediaQuery.of(context).padding.bottom + 6.h).clamp(
      0.0,
      double.infinity,
    );

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: _bg,
        border: Border(top: BorderSide(color: _topBorder, width: 1)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          horizontalPadding - 6,
          6,
          horizontalPadding - 6,
          bottomInset,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final spec in tabs)
              _NavBarV2Item(
                spec: spec,
                isActive: spec.tab == currentTab,
                onTap: () => onTabSelected(spec.tab),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavBarV2Item extends StatelessWidget {
  const _NavBarV2Item({
    required this.spec,
    required this.isActive,
    required this.onTap,
  });

  final NavTabSpec spec;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final iconColor = isActive ? NavBarV2._activeIcon : NavBarV2._inactiveIcon;
    final labelColor = isActive
        ? NavBarV2._activeLabel
        : NavBarV2._inactiveLabel;

    return Semantics(
      button: true,
      selected: isActive,
      label: spec.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 72.w,
          height: 48.h,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SvgPicture.asset(
                  spec.svgAsset,
                  width: 24,
                  height: 24,
                  colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
                ),
                const SizedBox(height: 2),
                Text(
                  spec.label,
                  style: TextStyle(
                    color: labelColor,
                    fontSize: 10,
                    height: 20 / 10,
                    fontWeight: isActive ? FontWeight.w500 : FontWeight.w400,
                    letterSpacing: 0.56,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tab list for [NavBarV2] — points at the v2 SVG icon set
/// (`assets/icons/nav-bar-v2/*`). Same labels and `comingSoon` flags as
/// [kDefaultNavTabs].
const List<NavTabSpec> kNavBarV2Tabs = [
  NavTabSpec(
    tab: NavTab.chats,
    label: 'Chats',
    svgAsset: 'assets/icons/nav-bar-v2/chats.svg',
  ),
  NavTabSpec(
    tab: NavTab.contacts,
    label: 'Contacts',
    svgAsset: 'assets/icons/nav-bar-v2/contacts.svg',
  ),
  NavTabSpec(
    tab: NavTab.files,
    label: 'Files',
    svgAsset: 'assets/icons/nav-bar-v2/files.svg',
    comingSoon: true,
  ),
  NavTabSpec(
    tab: NavTab.settings,
    label: 'Settings',
    svgAsset: 'assets/icons/nav-bar-v2/settings.svg',
  ),
];
