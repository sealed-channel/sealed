import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';
import 'package:sealed_app/ui/shared/widgets/snackbars.dart';

enum _Phase { warning, creating, backup }

class LocalAccountScreen extends ConsumerStatefulWidget {
  const LocalAccountScreen({super.key});

  @override
  ConsumerState<LocalAccountScreen> createState() => _LocalAccountScreenState();
}

class _LocalAccountScreenState extends ConsumerState<LocalAccountScreen> {
  _Phase _phase = _Phase.warning;
  String? _seedPhrase;
  bool _confirmed = false;
  bool _finalizing = false;
  Timer? _clipboardClearTimer;

  static const _clipboardClearAfter = Duration(seconds: 60);

  @override
  void dispose() {
    _clipboardClearTimer?.cancel();
    super.dispose();
  }

  Future<void> _onCreate() async {
    setState(() => _phase = _Phase.creating);
    try {
      final seed = await ref.read(walletProvider.notifier).createWallet();
      if (!mounted) return;
      setState(() {
        _seedPhrase = seed;
        _phase = _Phase.backup;
      });
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'Failed to create wallet: $e');
      setState(() => _phase = _Phase.warning);
    }
  }

  Future<void> _onContinue() async {
    if (_finalizing) return; // guard double-tap
    // Keys are derived in the background while the user backs up their phrase
    // (see WalletNotifier.createWallet). Make sure they finished before leaving
    // onboarding so the app doesn't land on a keyless account.
    setState(() => _finalizing = true);
    try {
      await ref.read(walletProvider.notifier).ensureKeysReady();
    } catch (e) {
      if (!mounted) return;
      setState(() => _finalizing = false);
      showErrorSnackBar(context, 'Failed to finish setup: $e');
      return;
    }
    if (!mounted) return;
    ref.read(walletProvider.notifier).clearSeedPhraseFromState();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _copySeed() async {
    final seed = _seedPhrase;
    if (seed == null) return;
    await Clipboard.setData(ClipboardData(text: seed));
    HapticFeedback.lightImpact();

    // Auto-clear the clipboard so the phrase does not linger where another app
    // (or a clipboard-history tool) can read it later. Note: on iOS the system
    // may already have synced it to nearby devices via Universal Clipboard —
    // the only full mitigation is not copying at all, surfaced via the warning
    // shown next to the button.
    _clipboardClearTimer?.cancel();
    _clipboardClearTimer = Timer(_clipboardClearAfter, () async {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == seed) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });

    if (!mounted) return;
    showInfoSnackBar(
      context,
      'Copied — clears in ${_clipboardClearAfter.inSeconds}s. Never share it.',
    );
  }

  /// Confirm leaving the backup screen before the phrase is acknowledged.
  Future<bool> _confirmLeaveBackup() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave without saving?'),
        content: const Text(
          "You haven't confirmed saving your recovery phrase. If you leave now "
          'and lose it, your account cannot be recovered.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  @override
  Widget build(BuildContext context) {
    // Block back-navigation while a wallet is being created, and require an
    // explicit confirm before abandoning an unacknowledged seed-backup screen.
    // A wallet is already persisted by the time we reach `backup`, so silently
    // popping and re-entering create would otherwise overwrite it (now also
    // guarded in AlgorandWallet.createWallet).
    final canLeave =
        _phase == _Phase.warning || (_phase == _Phase.backup && _confirmed);

    return PopScope(
      canPop: canLeave,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_phase == _Phase.creating) return; // hard-block during creation
        if (_phase == _Phase.backup && !_confirmed) {
          final leave = await _confirmLeaveBackup();
          if (leave && mounted) {
            ref.read(walletProvider.notifier).clearSeedPhraseFromState();
            Navigator.of(context).maybePop();
          }
        }
      },
      child: SealedLayout(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _phase == _Phase.backup
            ? _backupBody(context)
            : _warningBody(context),
      ),
    );
  }

  List<Widget> _warningBody(BuildContext context) {
    final isCreating = _phase == _Phase.creating;
    return [
      Text('Local Account', style: Theme.of(context).textTheme.headlineMedium),
      Gap(8.h),
      Text(
        'App creates an Algorand wallet. Keys from that wallet will be used '
        'for secure messaging.',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium!.copyWith(color: neutralColor),
      ),
      Gap(24.h),
      Container(
        padding: EdgeInsets.symmetric(vertical: 12.h, horizontal: 12.h),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16.h),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SvgPicture.asset('assets/svg/alert.svg'),
                Gap(8.w),
                Text(
                  'Local Account Risk',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            Gap(8.h),
            Text(
              'Your account is created and stored locally on this device, '
              'which means only you control access to it. If you lose your '
              'phone, delete the app, or forget your recovery details, your '
              'account and messages may not be recoverable. Make sure to '
              'securely save your recovery information and protect your '
              'device with a strong passcode.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall!.copyWith(color: neutralColor),
            ),
            Gap(16.h),
            if (isCreating)
              Center(
                child: Container(
                  width: 24.w,
                  height: 24.w,
                  child: CircularProgressIndicator(
                    color: primaryColor,
                    strokeWidth: 1.5,
                  ),
                ),
              )
            else
              SealedCircularButton(label: 'Create account', onTap: _onCreate),
          ],
        ),
      ),
    ];
  }

  List<Widget> _backupBody(BuildContext context) {
    final words = _seedPhrase!
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();

    return [
      Text(
        'Backup your recovery phrase',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      Gap(8.h),
      Text(
        'Write it down and store it safely. Losing it means losing your '
        'account.',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium!.copyWith(color: neutralColor),
      ),
      Gap(24.h),
      Container(
        padding: EdgeInsets.all(16.h),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16.h),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                // Fixed 3-column grid: every cell is an equal slice of the
                // available width, so words align in clean columns instead of
                // the ragged rows a width-driven Wrap produces on wide screens.
                const columns = 3;
                final spacing = 8.w;
                final cellWidth =
                    (constraints.maxWidth - spacing * (columns - 1)) / columns;
                return Wrap(
                  spacing: spacing,
                  runSpacing: 8.h,
                  children: [
                    for (var i = 0; i < words.length; i++)
                      SizedBox(
                        width: cellWidth,
                        child: _SeedWordChip(index: i + 1, word: words[i]),
                      ),
                  ],
                );
              },
            ),
            Gap(12.h),
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: _copySeed,
                behavior: HitTestBehavior.opaque,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.copy, size: 16.w, color: primaryColor),
                    Gap(6.w),
                    Text(
                      'Copy',
                      style: Theme.of(context).textTheme.bodySmall!.copyWith(
                        color: primaryColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      Gap(8.h),
      Text(
        'Writing it down is safest. Copying may sync your phrase to other '
        'devices via cloud clipboard.',
        style: Theme.of(
          context,
        ).textTheme.bodySmall!.copyWith(color: neutralColor),
      ),
      Gap(16.h),
      GestureDetector(
        onTap: () => setState(() => _confirmed = !_confirmed),
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            Icon(
              _confirmed ? Icons.check_box : Icons.check_box_outline_blank,
              color: _confirmed ? primaryColor : neutralColor,
              size: 20.w,
            ),
            Gap(8.w),
            Expanded(
              child: Text(
                'I have saved my recovery phrase safely.',
                style: Theme.of(context).textTheme.bodySmall!.copyWith(
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
            ),
          ],
        ),
      ),
      const Spacer(),
      if (_finalizing)
        Center(
          child: SizedBox(
            width: 24.w,
            height: 24.w,
            child: CircularProgressIndicator(
              color: primaryColor,
              strokeWidth: 1.5,
            ),
          ),
        )
      else
        Opacity(
          opacity: _confirmed ? 1 : 0.4,
          child: AbsorbPointer(
            absorbing: !_confirmed,
            child: SealedCircularButton(label: 'Continue', onTap: _onContinue),
          ),
        ),
      Gap(16.h),
    ];
  }
}

class _SeedWordChip extends StatelessWidget {
  const _SeedWordChip({required this.index, required this.word});

  final int index;
  final String word;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Row(
        children: [
          Text(
            '$index.',
            style: TextStyle(color: neutralColor, fontSize: 11.sp),
          ),
          Gap(4.w),
          Expanded(
            child: Text(
              word,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 14,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
