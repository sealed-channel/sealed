import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:sealed_app/ui/shared/theme.dart';

/// Informational dialog shown exactly once after a successful 12-word
/// (legacy BIP39) mnemonic restore.
///
/// Why this exists: Sealed migrated to a new Algorand smart-contract
/// `app id`. Every chain transaction now lives under that contract, so
/// usernames previously registered on the old contract no longer exist.
/// Users coming back via legacy backup phrases need to know their handle
/// has been wiped and that they can claim a new one.
///
/// Usage:
///   await showLegacyMigrationDialog(context);
///
/// The dialog is non-dismissable on barrier tap — only the explicit
/// "Got it" button closes it. Caller is responsible for marking the
/// notice as shown via [MigrationNoticeService.markShown] after the
/// returned future completes.
Future<void> showLegacyMigrationDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.65),
    builder: (_) => const _LegacyMigrationDialog(),
  );
}

class _LegacyMigrationDialog extends StatelessWidget {
  const _LegacyMigrationDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(20),
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
        decoration: BoxDecoration(
          color: const Color(0xFF101013),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    CupertinoIcons.exclamationmark_circle,
                    color: primaryColor,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                 Expanded(
                  child: Text(
                    'Usernames have been reset',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Sealed migrated to a new on-chain contract (a new Algorand '
              'app id). Every transaction now lives under that contract, so '
              'previously registered usernames no longer exist. Head to '
              'Settings → Profile to claim a new one when you are ready.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerRight,
              child: CupertinoButton(
                key: const Key('legacy_migration_dialog_got_it'),
                color: primaryColor,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 10,
                ),
                borderRadius: BorderRadius.circular(12),
                onPressed: () => Navigator.of(context).pop(),
                child:  Text(
                  'Got it',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
