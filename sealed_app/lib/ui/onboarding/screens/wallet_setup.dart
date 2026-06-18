import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/svg.dart';
import 'package:sealed_app/ui/onboarding/screens/local_account.dart';
import 'package:sealed_app/ui/onboarding/screens/mnemonic_account.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';

enum _WalletKind { create, restore }

class WalletSetup extends StatelessWidget {
  const WalletSetup({super.key});

  @override
  Widget build(BuildContext context) {
    return SealedLayout(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Create an account\nor recover an existing one',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        Gap(8.h),
        Text(
          'Select how you want to proceed.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium!.copyWith(color: neutralColor),
        ),
        Gap(24.h),
        _WalletTypeButton(
          kind: _WalletKind.create,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const LocalAccountScreen())),
        ),
        Gap(16.h),
        _WalletTypeButton(
          kind: _WalletKind.restore,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const MnemonicAccountScreen()),
          ),
        ),
      ],
    );
  }
}

class _WalletTypeButton extends StatefulWidget {
  const _WalletTypeButton({required this.kind, required this.onTap});

  final _WalletKind kind;
  final VoidCallback onTap;

  @override
  State<_WalletTypeButton> createState() => _WalletTypeButtonState();
}

class _WalletTypeButtonState extends State<_WalletTypeButton> {
  bool _isPressed = false;

  String get _asset => switch (widget.kind) {
    _WalletKind.create => 'assets/svg/phone.svg',
    _WalletKind.restore => 'assets/svg/key.svg',
  };

  String get _title => switch (widget.kind) {
    _WalletKind.create => 'Create new wallet',
    _WalletKind.restore => 'Restore wallet',
  };

  String get _subtitle => switch (widget.kind) {
    _WalletKind.create => 'Keys never leave device.',
    _WalletKind.restore => 'Restore with mnemonic phrase.',
  };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _isPressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedOpacity(
          opacity: _isPressed ? 0.85 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16.r),
            ),
            child: Row(
              children: [
                Container(
                  width: 40.w,
                  height: 40.h,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: SvgPicture.asset(
                    _asset,
                    width: 20.w,
                    height: 20.w,
                    fit: BoxFit.contain,
                  ),
                ),
                Gap(12.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        _subtitle,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall!.copyWith(color: neutralColor),
                      ),
                    ],
                  ),
                ),
                Icon(
                  CupertinoIcons.chevron_right,
                  color: neutralColor,
                  size: 14.w,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
