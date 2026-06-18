import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:sealed_app/ui/contacts/contact_profile.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_dialog.dart';

class WalletAddressDialog extends ConsumerWidget {
  const WalletAddressDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final walletAddress = ref.watch(walletProvider).asData?.value.walletAddress;

    return SealedDialog(
      title: "My Wallet Address",
      child: Column(
        children: [
          if (walletAddress == null)
            const Text("Wallet not connected")
          else
            QRContainer(qrCode: walletAddress),
        ],
      ),
    );
  }
}
