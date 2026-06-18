import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';

/// Rename an alias conversation. Shown via [showDialog]; pops the trimmed new
/// name on "Set", or null on Cancel/close.
class AliasChangeDialog extends StatefulWidget {
  const AliasChangeDialog({super.key, this.initialAlias = ''});

  final String initialAlias;

  @override
  State<AliasChangeDialog> createState() => _AliasChangeDialogState();
}

class _AliasChangeDialogState extends State<AliasChangeDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialAlias,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    Navigator.of(context).pop(name.isEmpty ? null : name);
  }

  @override
  Widget build(BuildContext context) {
    return SealedDialog(
      title: "Change Alias",
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.symmetric(vertical: 12.h, horizontal: 16.w),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16.r),
              color: Colors.white.withValues(alpha: 0.08),
            ),
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Alias",
                  style: Theme.of(context).textTheme.bodySmall!.copyWith(
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      vertical: 4.h,
                      horizontal: 4.w,
                    ),
                    border: InputBorder.none,
                  ),
                ),
              ],
            ),
          ),
          Gap(24.h),
          Row(
            children: [
              Expanded(
                child: SealedCircularButton(
                  label: "Cancel",
                  onTap: () => Navigator.of(context).pop(),
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  textColor: Colors.white.withValues(alpha: 0.9),
                ),
              ),
              Gap(12.w),
              Expanded(
                child: SealedCircularButton(label: "Set", onTap: _submit),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
