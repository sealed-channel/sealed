import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/providers/app_providers.dart';
import 'package:sealed_app/providers/local_wallet_provider.dart';
import 'package:sealed_app/shared/widgets/styled_dialog.dart';
import 'package:sealed_app/shared/widgets/theme.dart';
import 'package:sealed_app/core/snackbars.dart';
import 'package:url_launcher/url_launcher.dart';

/// Wallet top-up screen with balance polling
/// Shows wallet address and polls for incoming transactions every 3 seconds
class TopUpScreen extends ConsumerStatefulWidget {
  const TopUpScreen({super.key});

  @override
  ConsumerState<TopUpScreen> createState() => _TopUpScreenState();
}

class _TopUpScreenState extends ConsumerState<TopUpScreen> {
  Timer? _pollingTimer;
  double? _previousBalance;
  bool _transactionDetected = false;
  bool _isPolling = false;

  // Faucet state
  bool _isClaimingFaucet = false;
  Duration? _faucetCooldown;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    _startPolling();
    // Refresh cooldown once the wallet address is available.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshFaucetCooldown();
    });
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    // Initial balance fetch
    _fetchBalance();

    // Poll every 3 seconds
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _fetchBalance();
    });
  }

  Future<void> _fetchBalance() async {
    if (_isPolling || _transactionDetected) return;

    setState(() => _isPolling = true);

    try {
      await ref.read(localWalletProvider.notifier).refreshBalance();

      final walletState = ref.read(localWalletProvider).value;
      final currentBalance = walletState?.balanceSol ?? 0.0;

      // Check if balance increased (incoming transaction detected)
      if (_previousBalance != null && currentBalance > _previousBalance!) {
        setState(() => _transactionDetected = true);
        _pollingTimer?.cancel();

        // Show success feedback
        if (mounted) {
          HapticFeedback.heavyImpact();
        }
      }

      _previousBalance = currentBalance;
    } catch (e) {
      print('⚠️ TopUpScreen: Failed to fetch balance: $e');
    } finally {
      if (mounted) {
        setState(() => _isPolling = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final walletState = ref.watch(localWalletProvider);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: sealedBackgroundGradient),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: HORIZONTAL_PADDING),
            child: Column(
              children: [
                // Header
                _buildHeader(context),

                // Main content
                Expanded(
                  child: walletState.when(
                    data: (state) => _buildContent(state),
                    loading: () => Center(
                      child: CircularProgressIndicator(color: primaryColor),
                    ),
                    error: (e, _) => Center(
                      child: Text(
                        'Error: $e',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ),
                ),

                // Done button
                _buildDoneButton(context),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,

      children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Icon(CupertinoIcons.back, color: Colors.white, size: 24),
        ),

        Text(
          'Top Up',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            height: 22 / 16,
          ),
        ),

        SizedBox(width: 24),
      ],
    );
  }

  Widget _buildContent(LocalWalletState state) {
    final address = state.walletAddress ?? '';
    return SingleChildScrollView(
      child: Column(
        children: [
          SvgPicture.asset('assets/algorand_full.svg', width: 130, height: 130),
          // Success indicator
          if (_transactionDetected) ...[
            _buildSuccessCard(),
            const SizedBox(height: 24),
          ],

          // Balance card
          _buildBalanceCard(state),

          const SizedBox(height: 24),

          // Testnet Faucet Card (in-app claim + external faucet link)
          _buildTestnetFaucetCard(address),

          const SizedBox(height: 24),

          // Polling indicator
          if (!_transactionDetected) _buildPollingIndicator(),
        ],
      ),
    );
  }

  Widget _buildSuccessCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.green.withValues(alpha: 0.3),
            Colors.green.withValues(alpha: 0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.check_circle, color: Colors.green, size: 32),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Transaction Detected! 🎉',
                  style: TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Your wallet has been topped up successfully.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBalanceCard(LocalWalletState state) {
    final address = state.walletAddress ?? 'Loading...';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(
            'Current Balance',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '${state.balanceSol?.toStringAsFixed(4) ?? '0.0000'} ALGO',
            style: TextStyle(
              color: _transactionDetected ? Colors.green : Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Container(
              width: double.infinity,
              height: 1,
              color: Colors.white.withValues(alpha: 0.1),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Your Wallet Address',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    address,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: address));
                    HapticFeedback.lightImpact();
                    showInfoSnackBar(context, 'Address copied! ✅');
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: primaryColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.copy, color: primaryColor, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTestnetFaucetCard(String address) {
    final canClaim = !_isClaimingFaucet && _faucetCooldown == null;
    final hasAddress = address.isNotEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            primaryColor.withValues(alpha: 0.18),
            primaryColor.withValues(alpha: 0.06),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: primaryColor.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: primaryGradient,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withValues(alpha: 0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  CupertinoIcons.gift_fill,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Daily Free ALGO',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Claim 1 ALGO every 24 hours',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Primary claim button
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: (canClaim && hasAddress)
                  ? () => _onClaimTap(address)
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  gradient: (canClaim && hasAddress) ? primaryGradient : null,
                  color: (canClaim && hasAddress)
                      ? null
                      : Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: (canClaim && hasAddress)
                      ? [
                          BoxShadow(
                            color: primaryColor.withValues(alpha: 0.35),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isClaimingFaucet)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    else
                      Icon(
                        _faucetCooldown != null
                            ? CupertinoIcons.clock
                            : CupertinoIcons.gift,
                        color: Colors.white,
                        size: 18,
                      ),
                    const SizedBox(width: 8),
                    Text(
                      _isClaimingFaucet
                          ? 'Sending...'
                          : _faucetCooldown != null
                          ? 'Next claim in ${_formatCooldown(_faucetCooldown!)}'
                          : 'Claim 1 ALGO',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Secondary external faucet link
          GestureDetector(
            onTap: () => _openTestnetFaucet(address),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.launch,
                    size: 13,
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Or open external faucet',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12,
                      decoration: TextDecoration.underline,
                      decorationColor: Colors.white.withValues(alpha: 0.3),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Faucet logic ────────────────────────────────────────────────────────

  Future<void> _refreshFaucetCooldown() async {
    final address = ref.read(localWalletProvider).value?.walletAddress;
    if (address == null) return;
    final faucet = ref.read(faucetServiceProvider);
    final remaining = await faucet.timeUntilNextClaim(address);
    if (!mounted) return;
    setState(() => _faucetCooldown = remaining);

    _cooldownTimer?.cancel();
    if (remaining != null) {
      _cooldownTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
        final r = await faucet.timeUntilNextClaim(address);
        if (!mounted) return;
        setState(() => _faucetCooldown = r);
        if (r == null) {
          _cooldownTimer?.cancel();
          _cooldownTimer = null;
        }
      });
    }
  }

  String _formatCooldown(Duration d) {
    if (d.inHours >= 1) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    if (d.inMinutes >= 1) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }

  Future<void> _onClaimTap(String address) async {
    final confirmed = await _showClaimConfirmDialog(address);
    if (confirmed != true) return;

    setState(() => _isClaimingFaucet = true);
    try {
      final faucet = ref.read(faucetServiceProvider);
      final result = await faucet.claim(address);
      if (!mounted) return;

      if (result.isSuccess) {
        HapticFeedback.heavyImpact();
        // Trigger background balance refresh; polling will also catch it.
        // ignore: unawaited_futures
        ref.read(localWalletProvider.notifier).refreshBalance();
        await _refreshFaucetCooldown();
        if (!mounted) return;
        await _showClaimSuccessDialog(result.txId ?? '');
      } else if (result.isCooldown) {
        await _refreshFaucetCooldown();
        if (!mounted) return;
        showWarningSnackBar(
          context,
          result.message ?? 'Cooldown active — try again later.',
        );
      } else {
        showErrorSnackBar(context, result.message ?? 'Faucet claim failed.');
      }
    } finally {
      if (mounted) setState(() => _isClaimingFaucet = false);
    }
  }

  Future<bool?> _showClaimConfirmDialog(String address) {
    return StyledDialog.show<bool>(
      context: context,
      icon: CupertinoIcons.gift_fill,
      iconColor: primaryColor,
      title: 'Claim 1 Free ALGO?',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Get 1 testnet ALGO sent directly to your wallet — '
            'enough to send around 750 messages.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: primaryColor.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _kvRow('Amount', '1.00 ALGO'),
                const SizedBox(height: 6),
                _kvRow('To', _truncateAddr(address), monospace: true),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Available once every 24 hours · TestNet only',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
        ],
      ),
      actions: [
        StyledDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context, false),
        ),
        StyledDialogAction(
          label: 'Claim',
          isPrimary: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
  }

  Future<void> _showClaimSuccessDialog(String txId) async {
    await StyledDialog.show<void>(
      context: context,
      icon: CupertinoIcons.checkmark_seal_fill,
      iconColor: Colors.green,
      title: '1 ALGO Claimed! 🎉',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Your wallet has been topped up. The transaction may take a few '
            'seconds to confirm on-chain.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 14,
              height: 1.45,
            ),
          ),
          if (txId.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              'Transaction ID',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _truncateTxId(txId),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: txId));
                      HapticFeedback.lightImpact();
                      showInfoSnackBar(context, 'Tx ID copied');
                    },
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(Icons.copy, size: 14, color: primaryColor),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      actions: [
        StyledDialogAction(
          label: 'Done',
          isPrimary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  Widget _kvRow(String key, String value, {bool monospace = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          key,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 13,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            fontFamily: monospace ? 'monospace' : null,
          ),
        ),
      ],
    );
  }

  String _truncateAddr(String s) {
    if (s.length <= 12) return s;
    return '${s.substring(0, 6)}…${s.substring(s.length - 4)}';
  }

  String _truncateTxId(String s) {
    if (s.length <= 24) return s;
    return '${s.substring(0, 12)}…${s.substring(s.length - 8)}';
  }

  Future<void> _openTestnetFaucet(String address) async {
    final url = 'https://lora.algokit.io/testnet/fund?address=$address';
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) {
          showInfoSnackBar(context, 'Opened faucet in browser');
        }
      } else {
        if (mounted) {
          showErrorSnackBar(context, 'Could not open faucet URL');
        }
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(context, 'Failed to open faucet: $e');
      }
    }
  }

  void _copyFaucetUrl() {
    const faucetUrl = 'https://lora.algokit.io/testnet/fund';
    Clipboard.setData(const ClipboardData(text: faucetUrl));
    HapticFeedback.lightImpact();
    showInfoSnackBar(context, 'Faucet URL copied! ✅');
  }

  Widget _buildInstructions() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                color: Colors.white.withValues(alpha: 0.6),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Alternative Ways to Top Up',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildInstructionStep('1', 'Copy your wallet address above'),
          _buildInstructionStep('2', 'Send ALGO from any wallet or exchange'),
          _buildInstructionStep('3', 'Wait for the transaction to confirm'),
        ],
      ),
    );
  }

  Widget _buildInstructionStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: TextStyle(
                  color: primaryColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPollingIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white.withValues(alpha: 0.4),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'Checking for incoming transactions...',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildDoneButton(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            gradient: _transactionDetected ? primaryGradient : null,
            color: _transactionDetected ? null : cardColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text(
              _transactionDetected ? 'Done 🎉' : 'Close',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
