import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/features/identity/username_validator.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:sealed_app/ui/onboarding/widgets/pin_dots_row.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/dialogs.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';
import 'package:sealed_app/ui/shared/widgets/snackbars.dart';

/// ChangeUsernameDialog — claim a unique on-chain username.
///
/// Wires the input to [usernameControllerProvider] for debounced on-chain
/// availability checking. The "Set" button stays disabled until the current
/// input resolves to [NameAvailable]; a spinner shows while the chain probe is
/// in flight or the claim is being submitted. On success it calls
/// `userProvider.setUsername` and pops.
class ChangeUsernameDialog extends ConsumerStatefulWidget {
  const ChangeUsernameDialog({super.key});

  @override
  ConsumerState<ChangeUsernameDialog> createState() =>
      _ChangeUsernameDialogState();
}

class _ChangeUsernameDialogState extends ConsumerState<ChangeUsernameDialog> {
  late final TextEditingController _usernameController;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController();
    // Reset availability state once the first frame is mounted. Doing this
    // synchronously in initState mutates the provider while the widget tree is
    // still building, which Riverpod rejects ("Tried to modify a provider
    // while the widget tree was building").
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(usernameControllerProvider.notifier).onInputChanged('');
      }
    });
  }

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;

    final state = ref.read(usernameControllerProvider).value;
    if (state?.availabilityResult is! NameAvailable) return;

    // Submit the controller's normalized (trim + lowercase) input, not the
    // raw TextField text — the leading `@` is a display-only prefix.
    final name = state!.input;

    setState(() => _isSubmitting = true);
    try {
      await ref.read(userProvider.notifier).setUsername(username: name);
      if (!mounted) return;
      showInfoSnackBar(context, '@$name claimed successfully');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      if (e is NoCreditsError) {
        await CreditsRequiredDialog.show(context);
      } else {
        showErrorSnackBar(context, 'Failed to claim username: $e');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final checkState = ref.watch(usernameControllerProvider).value;
    final result = checkState?.availabilityResult;
    final isChecking = checkState?.isChecking ?? false;
    final canClaim = result is NameAvailable;
    final busy = isChecking || _isSubmitting;

    return SealedDialog(
      title: "Change username",
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
                  controller: _usernameController,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textInputAction: TextInputAction.done,
                  onChanged: (v) {
                    final lower = v.toLowerCase();
                    if (lower != v) {
                      _usernameController.value = _usernameController.value
                          .copyWith(
                            text: lower,
                            selection: TextSelection.collapsed(
                              offset: lower.length,
                            ),
                          );
                    }
                    ref
                        .read(usernameControllerProvider.notifier)
                        .onInputChanged(lower);
                  },
                  onSubmitted: (_) {
                    if (canClaim) _submit();
                  },
                  decoration: InputDecoration(
                    prefix: Text(
                      "@",
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium!.copyWith(color: primaryColor),
                    ),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      vertical: 4.h,
                      horizontal: 4.w,
                    ),
                    border: InputBorder.none,
                    errorText: _errorText(result, checkState?.input),
                    helperText: _helperText(result),
                    helperStyle: TextStyle(
                      color: canClaim
                          ? primaryColor
                          : result is AvailabilityUnknown
                          ? kPinErrorColor
                          : null,
                    ),
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
                  loading: busy,
                  onTap: (canClaim && !busy) ? _submit : () {},
                  backgroundColor: canClaim
                      ? null
                      : Colors.white.withValues(alpha: 0.08),
                  textColor: canClaim
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

  String? _errorText(AvailabilityResult? result, String? input) {
    if (result is NameTaken) return '@${input ?? ''} is taken';
    if (result is! NameInvalid) return null;
    return switch (result.code) {
      UsernameErrorCode.empty => null, // pristine input, not an error
      UsernameErrorCode.badLen => '3–20 characters',
      UsernameErrorCode.badChar ||
      UsernameErrorCode.notAscii => 'Only a–z, 0–9 and _',
      UsernameErrorCode.leadingUnderscore => "Can't start with _",
      UsernameErrorCode.trailingUnderscore => "Can't end with _",
      UsernameErrorCode.reserved => 'This name is reserved',
    };
  }

  String? _helperText(AvailabilityResult? result) {
    if (result is NameAvailable) return '✓ Available';
    if (result is AvailabilityUnknown) {
      return '⚠ Could not verify — check your connection';
    }
    return null;
  }
}
