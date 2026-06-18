import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/svg.dart';
import 'package:intl/intl.dart';
import 'package:sealed_app/models/chat_preview.dart';
import 'package:sealed_app/ui/shared/theme.dart';

/// Single row in the alias-chats list.
class AliasChatRow extends StatefulWidget {
  const AliasChatRow({super.key, required this.preview, required this.onTap});

  final ChatPreview preview;

  final VoidCallback onTap;

  @override
  State<AliasChatRow> createState() => _AliasChatRowState();
}

class _AliasChatRowState extends State<AliasChatRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final aliasContact = widget.preview.aliasContact!;
    final lastMsg = widget.preview.lastMessageContent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onHighlightChanged: (v) => setState(() => _pressed = v),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 100),
          opacity: _pressed ? 0.6 : 1.0,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 100),
            scale: _pressed ? 0.98 : 1.0,
            child: Container(
              margin: EdgeInsets.symmetric(),
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),

              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Isolate the expensive backdrop-blur in its own layer so a
                  // per-sync list rebuild can't force it to re-composite — the
                  // avatar never changes, so it should never repaint with the row.
                  RepaintBoundary(
                    child: ClipOval(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                        child: Container(
                          width: 40.w,
                          height: 40.w,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.12),
                          ),
                          alignment: Alignment.center,
                          child: SvgPicture.asset("assets/svg/chats/chat.svg"),
                        ),
                      ),
                    ),
                  ),
                  Gap(16.w),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          aliasContact.nickname ?? aliasContact.aliasHandle,
                          style: TextStyle(
                            fontSize: 14.sp,
                            fontWeight: FontWeight.w500,
                            height: 1.1,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        SizedBox(height: 2.h),

                        Text(
                          (lastMsg == null || lastMsg.isEmpty)
                              ? "No messages yet"
                              : lastMsg.replaceAll('\n', ' '),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 14.sp,
                            fontWeight: widget.preview.unreadCount > 0
                                ? FontWeight.w500
                                : FontWeight.w400,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.end,

                    children: [
                      Text(
                        widget.preview.lastMessageTimestamp != null
                            ? DateFormat("HH:mm").format(
                                DateTime.fromMillisecondsSinceEpoch(
                                  widget.preview.lastMessageTimestamp!,
                                ),
                              )
                            : '',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall!.copyWith(color: neutralColor),
                      ),

                      if (widget.preview.unreadCount > 0) ...[
                        Gap(2.h),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 2.w,
                            vertical: 2.h,
                          ),
                          decoration: BoxDecoration(
                            color: primaryColor,
                            shape: BoxShape.circle,
                          ),
                          constraints: BoxConstraints(minWidth: 20.w),
                          child: Text(
                            widget.preview.unreadCount > 99
                                ? '99+'
                                : '${widget.preview.unreadCount}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 10.sp,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ] else
                        Gap(20.h),
                    ],
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
