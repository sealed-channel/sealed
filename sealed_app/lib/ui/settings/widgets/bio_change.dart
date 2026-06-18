import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/features/identity/bio_validator.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_dots_row.dart'
    show kPinErrorColor;
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/dialogs.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';
import 'package:sealed_app/ui/shared/widgets/snackbars.dart';

/// ChangeBioDialog — set or clear the public on-chain profile bio.
///
/// Figma node 12:11936. Pre-fills with the current bio (edit-in-place); a
/// live byte counter tracks the 160-BYTE UTF-8 cap (multibyte chars count as
/// encoded width, so the counter can move faster than the char count). "Set"
/// stays disabled while the input is unchanged, over cap, or contains control
/// characters. Submitting calls `userProvider.setBio` (1 credit) and pops.
class ChangeBioDialog extends ConsumerStatefulWidget {
  const ChangeBioDialog({super.key});

  @override
  ConsumerState<ChangeBioDialog> createState() => _ChangeBioDialogState();
}

class _ChangeBioDialogState extends ConsumerState<ChangeBioDialog> {
  late final TextEditingController _bioController;
  late final String _initialBio;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _initialBio = ref.read(userProvider).value?.profile?.bio ?? '';
    _bioController = TextEditingController(text: _initialBio)
      ..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _bioController.dispose();
    super.dispose();
  }

  String get _input => _bioController.text.trim();

  bool get _isChanged => _input != _initialBio;

  BioValidation get _validation => validateBio(_input);

  bool get _canSet => _isChanged && _validation.isValid && !_isSubmitting;

  Future<void> _submit() async {
    if (!_canSet) return;

    setState(() => _isSubmitting = true);
    try {
      await ref.read(userProvider.notifier).setBio(bio: _input);
      if (!mounted) return;
      showInfoSnackBar(context, _input.isEmpty ? 'Bio cleared' : 'Bio updated');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      if (e is NoCreditsError) {
        await CreditsRequiredDialog.show(context);
      } else {
        showErrorSnackBar(context, 'Failed to update bio: $e');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = bioByteLength(_input);
    final overCap = bytes > kBioMaxBytes;
    final hasControlChars = _validation.code == BioErrorCode.controlChars;

    return SealedDialog(
      title: "Change Bio",
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
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        "Bio",
                        style: Theme.of(context).textTheme.bodySmall!.copyWith(
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    Text(
                      "$bytes/$kBioMaxBytes",
                      style: Theme.of(context).textTheme.bodySmall!.copyWith(
                        color: overCap
                            ? kPinErrorColor
                            : Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
                TextField(
                  controller: _bioController,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.multiline,
                  minLines: 3,
                  maxLines: 6,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      vertical: 4.h,
                      horizontal: 4.w,
                    ),
                    border: InputBorder.none,
                    hintText: 'Tell people about yourself',
                    hintStyle: Theme.of(context).textTheme.bodyMedium!.copyWith(
                      color: Colors.white.withValues(alpha: 0.3),
                    ),
                    errorText: overCap
                        ? 'Bio is too long — max $kBioMaxBytes bytes'
                        : hasControlChars
                        ? 'Bio contains unsupported characters'
                        : null,
                    helperText: 'Your bio is public',
                    helperStyle: Theme.of(context).textTheme.bodySmall!
                        .copyWith(color: Colors.white.withValues(alpha: 0.4)),
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
                child: SealedCircularButton(
                  label: "Set",
                  loading: _isSubmitting,
                  onTap: _canSet ? _submit : () {},
                  backgroundColor: _canSet
                      ? null
                      : Colors.white.withValues(alpha: 0.08),
                  textColor: _canSet
                      ? null
                      : Colors.white.withValues(alpha: 0.9),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
