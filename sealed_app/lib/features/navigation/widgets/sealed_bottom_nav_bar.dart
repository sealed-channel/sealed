import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/features/navigation/nav_tab.dart';

/// Glass-morphic pill bottom navigation bar matching Figma (node 120:2350).
///
/// - Container: rounded pill (radius 28.5), white 6% fill, backdrop blur.
/// - Active tab: white 6% pill behind icon + label, teal accent color.
/// - Inactive tabs: white @ 90% opacity.
///
/// Pure presentational widget — state is owned by the parent
/// (see `MainShell`), which passes [currentTab] and [onTabSelected].
class SealedBottomNavBar extends StatelessWidget {
  const SealedBottomNavBar({
    super.key,
    required this.tabs,
    required this.currentTab,
    required this.onTabSelected,
  });

  final List<NavTabSpec> tabs;
  final NavTab currentTab;
  final ValueChanged<NavTab> onTabSelected;

  /// Figma accent color for the active tab icon + label.
  static const Color _accent = Color(0xFF00B09F);
  static const Color _inactive = Color(0xE6FFFFFF); // white @ 90%
  static const double _barHeight = 60;
  static const double _barRadius = 60;
  static const double _activePillRadius = 24;
  static const double _horizontalMargin = 18;
  static const double _bottomMargin = 0;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _horizontalMargin,
        0,
        _horizontalMargin,
        bottomInset + _bottomMargin,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_barRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            height: 60,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(_barRadius),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                for (final spec in tabs)
                  Expanded(
                    child: _NavBarTab(
                      spec: spec,
                      isActive: spec.tab == currentTab,
                      onTap: () => onTabSelected(spec.tab),
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

class _NavBarTab extends StatelessWidget {
  const _NavBarTab({
    required this.spec,
    required this.isActive,
    required this.onTap,
  });

  final NavTabSpec spec;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isActive
        ? SealedBottomNavBar._accent
        : SealedBottomNavBar._inactive;

    final assetPath = isActive
        ? (spec.svgAssetActive ?? spec.svgAsset)
        : spec.svgAsset;

    // chats_filled.svg has its own teal/black colors baked in — don't override.
    final useOriginalColors =
        assetPath == spec.svgAssetActive && spec.svgAssetActive != null;

    final colorFilter = useOriginalColors
        ? null
        : ColorFilter.mode(color, BlendMode.srcIn);

    return Semantics(
      button: true,
      selected: isActive,
      label: spec.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: isActive
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(
              SealedBottomNavBar._activePillRadius,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SvgPicture.asset(
                assetPath,
                width: 22,
                height: 22,
                colorFilter: colorFilter,
              ),
              const SizedBox(height: 2),
              Text(
                spec.label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
