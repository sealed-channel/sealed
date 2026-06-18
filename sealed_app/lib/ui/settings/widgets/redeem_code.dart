import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/core/errors.dart';
import 'package:sealed_app/features/wallet/credits_service.dart'
    hide RedeemPhase;
import 'package:sealed_app/infra/zk/snark_prover.dart';
import 'package:sealed_app/providers/redeem_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:sealed_app/ui/onboarding/widgets/termination_dialog.dart';
import 'package:sealed_app/ui/settings/screens/_redeem_error_strings.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';

/// Formats redeem-code input as `XXXX-XXXX-XXXX-XXXX` while typing:
/// uppercases, drops anything outside `[A-Z0-9]`, caps at 16 code chars, and
/// inserts a dash after every 4. Dashes are display-only —
/// [CreditsService.normalizeCode] strips them before validation/submit.
class _RedeemCodeFormatter extends TextInputFormatter {
  static const _groupSize = 4;
  static const _maxChars = CreditsService.codeLen;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text.toUpperCase();

    // Count code chars left of the cursor before reformatting, so the cursor
    // lands after the same character once dashes move around.
    var charsBeforeCursor = 0;
    final buffer = StringBuffer();
    for (var i = 0; i < raw.length && buffer.length < _maxChars; i++) {
      final c = raw[i];
      if (!RegExp(r'[A-Z0-9]').hasMatch(c)) continue;
      buffer.write(c);
      if (i < newValue.selection.end) charsBeforeCursor++;
    }
    final chars = buffer.toString();

    final formatted = StringBuffer();
    var cursor = 0;
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % _groupSize == 0) formatted.write('-');
      formatted.write(chars[i]);
      if (i < charsBeforeCursor) cursor = formatted.length;
    }

    return TextEditingValue(
      text: formatted.toString(),
      selection: TextSelection.collapsed(offset: cursor),
    );
  }
}

/// RedeemCodeDialog — redeem a 16-char Crockford-b32 credit code.
///
/// Same [SealedDialog] layout as [ChangeUsernameDialog], with a `#` display
/// prefix on the code input. Validates format on the fly via
/// [CreditsService.normalizeCode]; the Redeem button stays disabled until the
/// input normalizes to exactly 16 valid chars.
///
/// On success: pops, fires a haptic + balance refresh, and shows the same
/// [PinDialog.success] chrome used after PIN setup (redeem copy). On error:
/// shows [PinDialog.warning] with the mapped message and stays open so the
/// user can fix the code and retry.
///
/// All orchestration (redeem + post-redeem key republish + phase reporting)
/// lives in [redeemProvider] — this widget is a thin consumer of that state.
class RedeemCodeDialog extends ConsumerStatefulWidget {
  const RedeemCodeDialog({super.key, this.onRedeemed});

  /// Optional callback fired after a successful redeem (dialog already
  /// closed, success dialog dismissed).
  final VoidCallback? onRedeemed;

  /// Show inside the canonical [SealedDialog.show] chrome.
  static Future<void> show(BuildContext context, {VoidCallback? onRedeemed}) {
    return SealedDialog.show<void>(
      context: context,
      dialog: RedeemCodeDialog(onRedeemed: onRedeemed),
    );
  }

  @override
  ConsumerState<RedeemCodeDialog> createState() => _RedeemCodeDialogState();
}

class _RedeemCodeDialogState extends ConsumerState<RedeemCodeDialog>
    with WidgetsBindingObserver {
  final _ctrl = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _submitting) {
      // Cancel any in-flight SNARK prove. Notifier's CancelToken handling
      // makes this a no-op when nothing is in flight; the redeem call then
      // completes with SnarkProverException(cancelled) and surfaces through
      // the normal error dialog path.
      ref.read(redeemProvider.notifier).cancel();
    }
  }

  bool get _normalizedValid {
    try {
      CreditsService.normalizeCode(_ctrl.text);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Map [RedeemState.lastException] to a user-visible string using the same
  /// table the redeem sheet used, so localized copy doesn't regress.
  String _messageForException(Object? e, String fallback) {
    if (e is BadRedeemCodeError) return e.message;
    if (e is RedeemSpentError) return e.message;
    if (e is RedeemContractError) return redeemMessageForCode(e.code);
    if (e is SnarkProverException) return redeemMessageForProverKind(e.kind);
    if (e is NoCreditsError) return e.message;
    if (e is MbrShortfallError) return e.message;
    if (e is SealedException) return e.message;
    return fallback;
  }

  Future<void> _showError(String message) {
    return showDialog<void>(
      context: context,
      builder: (dialogCtx) => PinDialog.warning(
        title: 'Redeem failed',
        body: message,
        buttonText: 'I understand',
        onPressed: () => Navigator.of(dialogCtx).pop(),
      ),
    );
  }

  Future<void> _onSubmit() async {
    if (_submitting) return;

    // Pre-flight: format check, surfaced via the warning dialog without
    // dispatching through the notifier at all.
    final String normalized;
    try {
      normalized = CreditsService.normalizeCode(_ctrl.text);
    } on CreditsServiceException {
      // Keep the raw service message (char/length jargon) out of the UI —
      // show one plain, actionable line regardless of which check tripped.
      await _showError(
        "That code doesn't look right. Redeem codes are 16 characters — "
        'check for typos and try again.',
      );
      return;
    }

    setState(() => _submitting = true);

    await ref.read(redeemProvider.notifier).redeem(normalized);

    final result = ref.read(redeemProvider);
    if (!mounted) return;
    setState(() => _submitting = false);

    if (result.phase == RedeemPhase.done) {
      HapticFeedback.heavyImpact();
      // Best-effort balance refresh — wallet UI concern, stays in the widget.
      // ignore: unawaited_futures
      ref.read(walletProvider.notifier).refreshBalance();
      final nav = Navigator.of(context);
      nav.pop();
      await showDialog<void>(
        context: nav.context,
        builder: (dialogCtx) => PinDialog.success(
          bannerText: 'Code redeemed successfully',
          title: 'All set',
          body: 'Credits have been added to your balance',
          buttonText: 'Continue',
          onPressed: () => Navigator.of(dialogCtx).pop(),
        ),
      );
      widget.onRedeemed?.call();
    } else {
      await _showError(
        _messageForException(
          result.lastException,
          result.lastError ?? 'Redeem failed.',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _normalizedValid && !_submitting;

    return SealedDialog(
      title: 'Redeem Code',
      closeEnabled: !_submitting,
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
                  'Code',
                  style: Theme.of(context).textTheme.bodySmall!.copyWith(
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
                TextField(
                  key: const Key('redeem_code_input'),
                  controller: _ctrl,
                  autofocus: true,
                  enabled: !_submitting,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [_RedeemCodeFormatter()],
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                    fontFamily: 'monospace',
                    letterSpacing: 1.5,
                  ),
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (canSubmit) _onSubmit();
                  },
                  decoration: InputDecoration(
                    prefix: Text(
                      '#',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium!.copyWith(color: primaryColor),
                    ),
                    hintText: 'XXXX-XXXX-XXXX-XXXX',
                    hintStyle: Theme.of(context).textTheme.bodyMedium!.copyWith(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontFamily: 'monospace',
                      letterSpacing: 1.5,
                    ),
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
                  label: 'Cancel',
                  onTap: () {
                    if (!_submitting) Navigator.of(context).pop();
                  },
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  textColor: Colors.white.withValues(alpha: 0.9),
                ),
              ),
              Gap(12.w),
              Expanded(
                child: SealedCircularButton(
                  key: const Key('redeem_code_submit'),
                  label: 'Redeem',
                  loading: _submitting,
                  onTap: canSubmit ? _onSubmit : () {},
                  backgroundColor: canSubmit
                      ? null
                      : Colors.white.withValues(alpha: 0.08),
                  textColor: canSubmit
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
