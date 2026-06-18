import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/ui/shared/theme.dart';

/// Shared shell for the app's modal dialogs: rounded clip, black header with a
/// title + close button, a hairline divider, then a translucent body holding
/// [child]. The 3 alias dialogs (change / invitation / termination) and any
/// future dialog share this chrome — only the title, close behavior, body
/// padding, and body content vary.
///
/// [child] owns its own content *and* action buttons (they differ per dialog).
/// Show it with [SealedDialog.show], which wraps it in the canonical
/// transparent [Dialog] and returns the popped result.
class SealedDialog extends StatelessWidget {
  const SealedDialog({
    super.key,
    required this.title,
    required this.child,
    this.onClose,
    this.closeEnabled = true,
    this.bodyPadding,
  });

  /// Header label.
  final String title;

  /// Body content, including action buttons.
  final Widget child;

  /// Tapped on the header close (X). Defaults to `Navigator.pop(context)`.
  /// Ignored when [closeEnabled] is false.
  final VoidCallback? onClose;

  /// When false, the close button is inert (e.g. while an async op runs).
  final bool closeEnabled;

  /// Body padding. Defaults to horizontal [horizontalPadding] + vertical 24.h.
  final EdgeInsetsGeometry? bodyPadding;

  /// Wrap [dialog] in the canonical transparent [Dialog] and show it. Returns
  /// whatever the dialog pops (`Navigator.pop(context, value)`). [dialog] is
  /// typically a [SealedDialog] or a stateful wrapper that builds one.
  static Future<T?> show<T>({
    required BuildContext context,
    required Widget dialog,
    bool barrierDismissible = true,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (_) => Stack(
        children: [
          // Frost the whole screen *behind* the dialog (iOS sheet style).
          // Lives here, not in the body, so the dialog's own widgets stay crisp.
          Positioned.fill(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: const SizedBox.shrink(),
            ),
          ),
          Dialog(
            backgroundColor: cardColor.withValues(alpha: 0),
            insetPadding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: dialog,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16.r),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(
            title: title,
            onClose: closeEnabled
                ? (onClose ?? () => Navigator.of(context).pop())
                : null,
          ),
          Container(
            width: double.infinity,
            height: 1.h,
            color: Colors.white.withValues(alpha: 0.1),
          ),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
            ),
            padding:
                bodyPadding ??
                EdgeInsets.symmetric(
                  horizontal: horizontalPadding,
                  vertical: 12.h,
                ),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onClose});

  final String title;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.8)),
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: 24.h,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          GestureDetector(
            onTap: onClose,
            child: Container(
              padding: EdgeInsets.all(6.w),
              decoration: BoxDecoration(
                color: cardColor.withValues(alpha: 0),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.close, size: 16.w),
            ),
          ),
        ],
      ),
    );
  }
}
