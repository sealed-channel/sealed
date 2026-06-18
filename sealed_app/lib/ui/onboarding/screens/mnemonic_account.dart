import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/buttons.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';

class MnemonicAccountScreen extends ConsumerStatefulWidget {
  const MnemonicAccountScreen({super.key});

  @override
  ConsumerState<MnemonicAccountScreen> createState() =>
      _MnemonicAccountScreenState();
}

class _MnemonicAccountScreenState extends ConsumerState<MnemonicAccountScreen> {
  static const _allowedCounts = {12, 24, 25};
  static const Color _errorColor = Color(0xFFE57373);

  final _ctrl = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _obscure = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    if (_busy) return;

    final words = _ctrl.text
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final phrase = words.join(' ');

    if (!_allowedCounts.contains(words.length)) {
      setState(() => _error = 'Phrase must be 24 words.');
      return;
    }

    // BIP39 checksum for legacy 12-word path. 24/25 rely on
    // AlgorandWallet.restoreWallet to fail loudly on bad input.
    if (words.length == 12 && !bip39.validateMnemonic(phrase)) {
      setState(() => _error = 'Invalid recovery phrase.');
      return;
    }

    setState(() {
      _error = null;
      _busy = true;
    });

    try {
      await ref
          .read(walletProvider.notifier)
          .restoreFromMnemonic(phrase, wordCount: words.length);
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SealedLayout(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Mnemonic phrase account',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        Gap(8.h),
        Text(
          'Enter your 24-word recovery phrase.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium!.copyWith(color: neutralColor),
        ),
        Gap(24.h),
        Container(
          padding: EdgeInsets.symmetric(vertical: 12.h, horizontal: 16.h),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16.h),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  enabled: !_busy,
                  maxLines: _obscure ? 1 : 3,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                    color: Colors.white.withValues(alpha: 0.9),
                    height: 1.2,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    hintText: 'word1 word2 word3 …',
                    hintStyle: Theme.of(context).textTheme.bodyMedium!.copyWith(
                      color: neutralColor,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
              Gap(8.w),
              GestureDetector(
                onTap: () => setState(() => _obscure = !_obscure),
                child: SvgPicture.asset(
                  _obscure
                      ? 'assets/svg/eye_closed.svg'
                      : 'assets/svg/eye_open.svg',
                  width: _obscure ? 18.w : 20.w,
                ),
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          Gap(8.h),
          Text(
            _error!,
            style: Theme.of(
              context,
            ).textTheme.bodySmall!.copyWith(color: _errorColor),
          ),
        ],
        const Spacer(),
        if (_busy)
          Center(child: CircularProgressIndicator(color: primaryColor))
        else
          SealedCircularButton(label: 'Start messaging', onTap: _onSubmit),
        Gap(16.h),
      ],
    );
  }
}
