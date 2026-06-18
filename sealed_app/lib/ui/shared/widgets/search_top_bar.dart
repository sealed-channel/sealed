import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/core/extensions.dart';
import 'package:sealed_app/ui/shared/theme.dart';

/// Implemented by screens that host a [SearchTopBar] so a parent shell can
/// collapse their search when the tab is switched away from.
abstract interface class SearchCollapsible {
  void collapseSearch();
}

/// [TapRegion.groupId] shared by the expanded search bar and its result rows.
/// Tapping a row counts as "inside" the group so the bar's [TapRegion]
/// onTapOutside does not fire — the row navigates instead of collapsing.
/// Tapping anywhere else (hint, gaps, background) is outside → collapse.
const String kSearchTapGroup = 'sealed.search';

/// Reusable liquid-glass top bar: a screen title plus a search affordance that
/// expands into an inline search field. Feature-blind — it owns only the search
/// UI state (expansion, controller, focus, debounce) and reports out via
/// callbacks. Feature wiring (QR scan, search provider) stays in the parent.
///
/// Parents that need to force-collapse after navigating (e.g. a search result
/// tap that pushes a route and pops back) hold a [GlobalKey] of
/// [SearchTopBarState] and call [SearchTopBarState.collapse].
class SearchTopBar extends StatefulWidget {
  const SearchTopBar({
    super.key,
    required this.title,
    this.onExpandedChanged,
    this.onSearchingChanged,
    this.onQueryChanged,
    this.onQrTap,
    this.searchHint = 'Search Users',
  });

  final String title;

  /// Fired when the bar expands (true) or collapses (false). Drives parent
  /// layout that hides while searching (tab rows, FABs).
  final ValueChanged<bool>? onExpandedChanged;

  /// Fired immediately as the user types — true when the field is non-empty.
  /// Use to switch the body to a search view without waiting on the debounce.
  final ValueChanged<bool>? onSearchingChanged;

  /// Fired with the debounced query text. Use to drive the search provider.
  final ValueChanged<String>? onQueryChanged;

  /// QR affordance tap. When null the QR icon is hidden.
  final VoidCallback? onQrTap;

  final String searchHint;

  @override
  State<SearchTopBar> createState() => SearchTopBarState();
}

class SearchTopBarState extends State<SearchTopBar> {
  bool _isSearchExpanded = false;

  final FocusNode _searchFocusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  final Debouncer _debouncer = Debouncer();

  @override
  void dispose() {
    _searchFocusNode.dispose();
    _searchController.dispose();
    _debouncer.dispose();
    super.dispose();
  }

  // ── Search lifecycle ────────────────────────────────────────────────────

  void _onSearchChanged(String value) {
    widget.onSearchingChanged?.call(value.isNotEmpty);
    _debouncer.run(() {
      if (!mounted) return;
      widget.onQueryChanged?.call(value);
    });
  }

  void _expandSearch() {
    setState(() => _isSearchExpanded = true);
    widget.onExpandedChanged?.call(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  /// Collapse the search field and reset query state. Public so a parent can
  /// drive it after navigation. Safe to call when already collapsed.
  void collapse() {
    if (!_isSearchExpanded && _searchController.text.isEmpty) return;
    setState(() => _isSearchExpanded = false);
    _searchController.clear();
    _searchFocusNode.unfocus();
    widget.onSearchingChanged?.call(false);
    widget.onQueryChanged?.call('');
    widget.onExpandedChanged?.call(false);
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          return FadeTransition(opacity: animation, child: child);
        },
        child: _isSearchExpanded
            ? _buildExpandedTopBar()
            : _buildCollapsedTopBar(),
      ),
    );
  }

  Widget _buildCollapsedTopBar() {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 4.h),
      child: Row(
        key: const ValueKey('top-bar-collapsed'),
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.headlineSmall),
          const Spacer(),
          if (widget.onQrTap != null) ...[
            GestureDetector(
              onTap: widget.onQrTap,
              behavior: HitTestBehavior.opaque,
              child: SvgPicture.asset(
                'assets/icons/general/qr.svg',
                width: 24.w,
                height: 24.w,
                colorFilter: ColorFilter.mode(
                  Colors.white.withValues(alpha: 0.9),
                  BlendMode.srcIn,
                ),
              ),
            ),
            Gap(12.w),
          ],
          GestureDetector(
            onTap: _expandSearch,
            behavior: HitTestBehavior.opaque,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(100),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  width: 115.w,
                  padding: EdgeInsets.symmetric(
                    horizontal: 12.w,
                    vertical: 10.h,
                  ),
                  color: Colors.white.withValues(alpha: 0.08),
                  child: Row(
                    children: [
                      Icon(Icons.search, size: 18.w, color: mutedColor),
                      Gap(6.w),
                      Text(
                        "Search",
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium!.copyWith(color: neutralColor),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandedTopBar() {
    return TapRegion(
      // Tapping outside the search bar AND its result rows (same [groupId])
      // collapses back to the normal view. Result rows opt into the group so
      // a row tap navigates instead — collapse() also unfocuses the keyboard.
      groupId: kSearchTapGroup,
      onTapOutside: (_) => collapse(),
      child: ClipRRect(
        key: const ValueKey('top-bar-expanded'),
        borderRadius: BorderRadius.circular(9999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              border: Border.all(color: const Color(0xFF2E2E2E), width: 1.2),
            ),
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 0.h),
            child: Row(
              children: [
                Icon(CupertinoIcons.search, size: 16.w, color: mutedColor),
                Gap(8.w),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    onChanged: _onSearchChanged,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w400,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 8.h),
                      border: InputBorder.none,
                      hintText: widget.searchHint,
                      hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 14.sp,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: collapse,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(14.w, 12.h, 2.w, 12.h),
                    child: Icon(
                      CupertinoIcons.xmark,
                      size: 14.w,
                      color: neutralColor,
                    ),
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
