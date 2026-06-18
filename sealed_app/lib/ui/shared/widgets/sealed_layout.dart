import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/topbar.dart';

class SealedLayout extends StatelessWidget {
  SealedLayout({
    super.key,
    this.children = const [],
    this.header,
    this.scrollable = false,
    this.topBar,
    this.expandedBody,
    this.horizontalPadding = HORIZONTAL_PADDING,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  });
  List<Widget> children;
  double horizontalPadding;
  Widget? header;
  TopBar? topBar;
  bool scrollable;
  Widget? expandedBody;
  CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        margin: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 10,
          bottom: scrollable ? 0 : MediaQuery.of(context).padding.bottom,
        ),

        child: Column(
          crossAxisAlignment: crossAxisAlignment,
          children: [
            topBar != null ? topBar! : Center(),
            topBar != null && !scrollable ? Gap(12.h) : Center(),
            ?header,
            scrollable
                ? (Expanded(
                    child: ListView(
                      // The shell renders with extendBody:true behind a nav bar
                      // whose height includes the system bottom inset, so add
                      // that inset here or trailing content (e.g. the settings
                      // version row) sits under the nav bar.
                      padding: EdgeInsets.only(
                        left: horizontalPadding,
                        right: horizontalPadding,
                        top: 12.h,
                        bottom:
                           24.h + MediaQuery.of(context).padding.bottom,
                      ),
                      children: children,
                    ),
                  ))
                : Expanded(
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                      ),
                      child: Column(
                        crossAxisAlignment: crossAxisAlignment,
                        children: [
                          ...children,
                          if (expandedBody != null)
                            Expanded(child: expandedBody!),
                        ],
                      ),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}
