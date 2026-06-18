import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:sealed_app/features/auth/wipe.dart';
import 'package:sealed_app/ui/onboarding/screens/lock.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';
import 'package:sealed_app/ui/shared/widgets/snackbars.dart';

/// Logout flow per Figma nodes 1:18496 (collapsed) + 1:18523 (revealed).
///
/// Caller guarantees [seedPhrase] is non-null — the no-mnemonic branch is
/// handled separately in Settings (simple confirm + wipe).
class LogoutScreen extends ConsumerStatefulWidget {
  const LogoutScreen({super.key, required this.seedPhrase});

  final String seedPhrase;

  @override
  ConsumerState<LogoutScreen> createState() => _LogoutScreenState();
}

class _LogoutScreenState extends ConsumerState<LogoutScreen> {
  static const Color _destructiveText = Color(0xFFD31737);
  static const Color _destructiveBg = Color(0x1AD31737); // 10% red
  static const Color _phraseBoxBorder = Color(0xFF2E2E2E);

  bool _phraseRevealed = false;
  bool _busy = false;

  Future<void> _onRevealTap() async {
    if (_busy) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const LockScreenV2(
          reauth: true,
          subtitle: 'Confirm your passcode to reveal your recovery phrase.',
        ),
      ),
    );
    if (ok == true && mounted) {
      setState(() => _phraseRevealed = true);
    }
  }

  Future<void> _copyPhrase() async {
    await Clipboard.setData(ClipboardData(text: widget.seedPhrase));
    if (!mounted) return;
    showInfoSnackBar(context, 'Recovery phrase copied');
  }

  Future<void> _onLogoutAnyway() async {
    if (_busy) return;
    setState(() => _busy = true);
    final container = ProviderScope.containerOf(context);
    // Run wipe FIRST so AppShell swaps `main` to WelcomeScreen behind this
    // route before we pop. Popping first would briefly reveal the settings
    // tab while the async wipe ran, then snap to Welcome.
    try {
      await performLogout(container);
    } catch (e) {
      debugPrint('⚠️ Logout error: $e');
    }
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return SealedLayout(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BackRow(onTap: _busy ? null : () => Navigator.of(context).pop()),
        Gap(8.h),
        Text('Logout', style: Theme.of(context).textTheme.headlineMedium),
        Gap(8.h),
        Text(
          'Logging out wipes local data on this device — alias chat history '
          'and conversation history will be lost. Back up your recovery '
          'phrase first.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium!.copyWith(color: neutralColor, height: 1.4),
        ),
        Gap(24.h),
        _phraseRevealed
            ? _RevealedCard(
                phrase: widget.seedPhrase,
                borderColor: _phraseBoxBorder,
                onCopy: _copyPhrase,
              )
            : _CollapsedRow(onTap: _onRevealTap),
        const Spacer(),
        _LogoutPillButton(
          label: 'Logout anyway',
          fillColor: _destructiveBg,
          textColor: _destructiveText,
          busy: _busy,
          onTap: _onLogoutAnyway,
        ),
        Gap(8.h),
      ],
    );
  }
}

// ─── Subwidgets ─────────────────────────────────────────────────────────────

class _BackRow extends StatelessWidget {
  const _BackRow({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40.h,
      child: Row(children: [SealedBackButton(onTap: onTap)]),
    );
  }
}

class _CollapsedRow extends StatelessWidget {
  const _CollapsedRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(12.h),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Show recovery code',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w500,
                      height: 24 / 14,
                    ),
                  ),
                  Text(
                    'copy the code to recover data',
                    style: TextStyle(
                      color: neutralColor,
                      fontSize: 12.sp,
                      height: 20 / 12,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: 8.w),
            SizedBox(
              width: 32.w,
              height: 32.w,
              child: Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RevealedCard extends StatelessWidget {
  const _RevealedCard({
    required this.phrase,
    required this.borderColor,
    required this.onCopy,
  });

  final String phrase;
  final Color borderColor;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(12.h),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Recovery Phrase',
            style: TextStyle(
              color: primaryColor,
              fontSize: 14.sp,
              fontWeight: FontWeight.w500,
              height: 24 / 14,
            ),
          ),
          Text(
            'copy the code to recover data',
            style: TextStyle(
              color: neutralColor,
              fontSize: 12.sp,
              height: 20 / 12,
            ),
          ),
          Gap(8.h),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor, width: 1.2),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 12.w,
                      vertical: 8.h,
                    ),
                    child: SelectableText(
                      phrase,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 10.sp,
                        height: 1.4,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8.w),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onCopy,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child:  Icon(
                        CupertinoIcons.doc_on_doc,
                        size: 16,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LogoutPillButton extends StatelessWidget {
  const _LogoutPillButton({
    required this.label,
    required this.fillColor,
    required this.textColor,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final Color fillColor;
  final Color textColor;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: busy ? null : onTap,
      child: AnimatedOpacity(
        opacity: busy ? 0.6 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(vertical: 12.h, horizontal: 16.w),
          decoration: BoxDecoration(
            color: fillColor,
            borderRadius: BorderRadius.circular(9999),
          ),
          alignment: Alignment.center,
          child: busy
              ? SizedBox(
                  width: 18.w,
                  height: 18.w,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(textColor),
                  ),
                )
              : Text(
                  label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w500,
                    height: 24 / 14,
                    letterSpacing: 0.336,
                  ),
                ),
        ),
      ),
    );
  }
}
