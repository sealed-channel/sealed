import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/models/chat_preview.dart';
import 'package:sealed_app/ui/shared/theme.dart';

/// Single row in the regular-chats / spam list. Pure UI — caller passes
/// the formatted display strings.
class ChatRow extends StatefulWidget {
  const ChatRow({
    super.key,
    required this.conversation,
    required this.displayName,
    required this.avatarInitial,
    required this.timeLabel,
    required this.onTap,
  });

  final ChatPreview conversation;
  final String displayName;
  final String avatarInitial;
  final String timeLabel;
  final VoidCallback onTap;

  @override
  State<ChatRow> createState() => _ChatRowState();
}

class _ChatRowState extends State<ChatRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;
    final lastMsg = conv.lastMessageContent ?? '';
    final isAliasPreview =
        lastMsg.startsWith('sealed://alias?') ||
        lastMsg.startsWith('sealed://alias-envelope?');
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 100),
        opacity: _pressed ? 0.6 : 1.0,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 100),
          scale: _pressed ? 0.98 : 1.0,
          child: Material(
            color: Colors.transparent,
            child: Container(
              margin: EdgeInsets.symmetric(),
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),
              
            
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 20.w,
                    backgroundColor: primaryColor,
                    child: Text(
                      widget.avatarInitial,
                      style: const TextStyle(color: Colors.black),
                    ),
                  ),
                  Gap(16.w),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.displayName,
                          style: TextStyle(
                            fontSize: 14.sp,
                            fontWeight: FontWeight.w500,
                            height: 1.1,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        SizedBox(height: 2.h),
                        if (isAliasPreview)
                          Row(
                            children: [
                              Icon(
                                CupertinoIcons.lock_shield_fill,
                                color: primaryColor.withValues(alpha: 0.7),
                                size: 13,
                              ),
                              Gap(4.w),
                              Text(
                                conv.isLastMessageOutgoing
                                    ? 'Alias invite sent'
                                    : 'Alias chat invitation',
                                style: TextStyle(
                                  color: primaryColor.withValues(alpha: 0.7),
                                  fontSize: 13.sp,
                                  fontWeight: FontWeight.w500,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ],
                          )
                        else
                          Text(
                            lastMsg.replaceAll('\n', ' '),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 14.sp,
                              fontWeight: conv.unreadCount > 0
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
                        widget.timeLabel,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall!.copyWith(color: neutralColor),
                      ),
            
                      if (conv.unreadCount > 0) ...[
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
                            conv.unreadCount > 99 ? '99+' : '${conv.unreadCount}',
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
