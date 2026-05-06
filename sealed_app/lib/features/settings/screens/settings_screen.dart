import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/features/auth/screens/pin_confirm_screen.dart';
import 'package:sealed_app/features/qr/qr_display_screen.dart';
import 'package:sealed_app/features/settings/screens/change_pin_flow.dart';
import 'package:sealed_app/features/settings/screens/change_termination_flow.dart';
import 'package:sealed_app/features/settings/screens/topup_screen.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sealed_app/providers/app_providers.dart';
import 'package:sealed_app/providers/local_wallet_provider.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:sealed_app/services/logout_service.dart';
import 'package:sealed_app/core/snackbars.dart';
import 'package:sealed_app/services/message_service.dart';
import 'package:sealed_app/services/notification_service.dart';
import 'package:sealed_app/shared/widgets/styled_dialog.dart';
import 'package:sealed_app/shared/widgets/theme.dart';

/// Figma-aligned rewrite of the Settings screen.
///
/// Design ref: Figma node 2:1865 (Sealed / Settings).
/// Functionality intentionally mirrors [SettingsScreen] so the two can be
/// swapped behind a feature flag while the new visuals are validated.
///
/// Push notifications are conditionally available based on Tor status - they
/// require Tor to be fully embedded and connected since notifications depend
/// on the Tor indexer service for delivery.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Section card background — rgba(255,255,255,0.06) per Figma.
  static const Color _sectionBg = Color(0x0FFFFFFF);
  // Divider color — #262626 per Figma.
  static const Color _divider = Color(0xFF262626);
  // Destructive text color — matches Figma `--error-color` fallback #E57373.
  static const Color _errorColor = Color(0xFFE57373);

  bool _targetedPushEnabled = false;
  bool _realtimeEnabled = false;
  bool _isResyncing = false;
  bool _isSettingUsername = false;
  // Push registration runs over Tor + OHTTP, so it can take several seconds.
  // Surface a loading state on the toggle row while it's in flight so the
  // user knows something is happening.
  bool _isPushBusy = false;
  String? _pushBusyMessage;

  // PIN / termination — now inlined directly in Settings.
  bool _termSet = false;
  bool _pinBusy = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _refreshPinSecurity();
  }

  Future<void> _loadSettings() async {
    final settings = await ref.read(appSettingsServiceProvider.future);
    if (!mounted) return;
    setState(() {
      _targetedPushEnabled = settings.targetedPushEnabled;

    });
  }

  Future<void> _refreshPinSecurity() async {
    final term = ref.read(terminationServiceProvider);
    final isTerm = await term.isConfigured();
    if (!mounted) return;
    setState(() {
      _termSet = isTerm;
    });
  }

  Future<void> _changePin() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ChangePinFlow(),
        fullscreenDialog: true,
      ),
    );
    await _refreshPinSecurity();
  }

  Future<void> _manageTermination() async {
    // Tap goes straight into the change flow — no intermediate dialog.
    // Removal is handled inside the flow itself. See SPEC.md §2.
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ChangeTerminationFlow(terminationAlreadySet: _termSet),
        fullscreenDialog: true,
      ),
    );
    await _refreshPinSecurity();
  }

  @override
  Widget build(BuildContext context) {
    final walletState = ref.watch(localWalletProvider);
    final currentUser = ref.watch(currentUserProvider);
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: sealedBackgroundGradient),
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.only(
                  top: 0,
                  left: HORIZONTAL_PADDING,
                  right: HORIZONTAL_PADDING,
                  bottom: 40 + MediaQuery.of(context).padding.bottom,
                ),
                children: [
                  SizedBox(
                    height: topPadding,
                  ), // compensate for status bar overlap
                  _buildHeader(context),
                  const SizedBox(height: 16),
                  _Section(
                    title: 'Profile',
                    child: _buildProfileCard(walletState, currentUser),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: 'Privacy',
                    child: _buildPrivacyCard(),
                  ),
                  const SizedBox(height: 16),
                  _Section(title: 'Security', child: _buildSecurityCard()),
                  const SizedBox(height: 16),
                  _Section(title: 'Actions', child: _buildActionsCard()),
                  const SizedBox(height: 16),
                  _Section(title: 'About', child: _buildAboutCard()),
                  SizedBox(
                    height: topPadding,
                  ), // balance for bottom breathing room
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Settings',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              height: 22 / 16,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Profile card ──────────────────────────────────────────────────────────

  Widget _buildProfileCard(
    AsyncValue<LocalWalletState> walletState,
    UserProfile? currentUser,
  ) {
    final walletAddress = walletState.asData?.value.walletAddress;
    final balance = walletState.asData?.value.balanceSol ?? 0.0;
    // ~0.00132 ALGO per message (fee + min-balance amortization estimate).
    // Matches design "enough to send N Messages" affordance.
    final sendableMessages = balance > 0 ? (balance / 0.00132).floor() : 0;

    return _Card(
      children: [
        _ProfileRow(
          iconAsset: _SettingsIcons.user,
          title: 'Username',
          subtitle: currentUser?.username ?? 'Not set',
          trailing: _isSettingUsername
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : _GradientPill(
                  label: currentUser?.username != null ? 'Edit' : 'Set',
                  onTap: _setUsername,
                ),
        ),
        const _RowDivider(),
        GestureDetector(
          onTap: walletAddress == null
              ? null
              : () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const QrDisplayScreen()),
                  );
                },
          child: _ProfileRow(
            iconAsset: _SettingsIcons.creditCard,
            title: 'Wallet',
            subtitle: _truncateAddress(walletAddress ?? 'Not connected'),
            trailing: walletAddress == null
                ? null
                : Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      CupertinoIcons.qrcode,
                      size: 20,
                      color: primaryColor,
                    ),
                  ),
          ),
        ),
        const _RowDivider(),
        GestureDetector(
          onTap: () {
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const TopUpScreen()));
          },
          child: _BalanceRow(
            balance: balance,
            sendableMessages: sendableMessages,
            onTopUp: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const TopUpScreen()));
            },
          ),
        ),
      ],
    );
  }

  // ─── Privacy card ──────────────────────────────────────────────────────────

  Widget _buildPrivacyCard() {
    // Helper method to get appropriate subtitle text
    String _getPushSubtitle() {
      if (_isPushBusy) {
        return _pushBusyMessage ?? 'Working…';
      }

      return _targetedPushEnabled
          ? 'Indexer knows when you receive messages'
          : 'Trade privacy for richer alerts';
    }

    return _Card(
      children: [
        _ToggleRow(
          iconAsset: _SettingsIcons.bell,
          title: 'Push Notifications',
          subtitle: _getPushSubtitle(),
          value: _targetedPushEnabled,
          onChanged: !_isPushBusy ? _onTargetedPushToggle : null,
          isBusy: _isPushBusy,
        ),
        const _RowDivider(),
        // _ToggleRow(
        //   iconAsset: _SettingsIcons.link,
        //   title: 'Real-Time Messages',
        //   subtitle: _realtimeEnabled
        //       ? 'Indexer WebSocket (live)'
        //       : 'OHTTP blockchain poll every 5s',
        //   value: _realtimeEnabled,
        //   onChanged: _onRealtimeToggle,
        // ),
        // const _RowDivider(),
        _InfoRow(
          iconAsset: _SettingsIcons.mobile,
          title: 'IP Hidden - always on',
          subtitle: 'all network requests via OHTTP relay',
          trailing: const Icon(
            CupertinoIcons.checkmark_alt_circle_fill,
            size: 24,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  // ─── Actions card ──────────────────────────────────────────────────────────

  Widget _buildSecurityCard() {
    return _Card(
      children: [
        _ActionRow(
          icon: CupertinoIcons.lock_fill,
          title: 'Change PIN',
          subtitle: 'Update your unlock PIN',
          onTap: _pinBusy ? null : _changePin,
          useIconData: true,
          trailing: _pinBusy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
        const _RowDivider(),
        _ActionRow(
          icon: CupertinoIcons.flame_fill,
          title: 'Termination Code',
          subtitle: _termSet ? 'Change' : 'Not set',
          onTap: _pinBusy ? null : _manageTermination,
          useIconData: true,
        ),
      ],
    );
  }

  Widget _buildActionsCard() {
    return _Card(
      children: [
        _ActionRow(
          iconAsset: _SettingsIcons.reload,
          title: 'Reload Conversations',
          subtitle: _isResyncing ? 'Syncing…' : 'Reset memory and refresh',
          onTap: _isResyncing ? null : _forceResync,
          trailing: _isResyncing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
        const _RowDivider(),
        _ActionRow(
          icon: CupertinoIcons.square_arrow_right,
          title: 'Log Out',
          titleColor: _errorColor,
          iconColor: _errorColor,
          chevronColor: _errorColor,
          onTap: _logout,
          useIconData: true,
        ),
      ],
    );
  }

  // ─── About card ────────────────────────────────────────────────────────────

  Widget _buildAboutCard() {
    return _Card(
      children: [
        _ActionRow(
          icon: CupertinoIcons.info_circle_fill,
          title: 'Version',
          subtitle: '1.1.3',
          onTap: _showVersion,
          useIconData: true,
          trailing: const SizedBox.shrink(),
        ),
      ],
    );
  }

  Future<void> _showVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    await StyledDialog.show<void>(
      context: context,
      icon: CupertinoIcons.info_circle_fill,
      iconColor: Colors.white70,
      title: 'Version',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _VersionRow(label: 'App', value: info.appName),
          const SizedBox(height: 8),
          _VersionRow(label: 'Version', value: info.version),
          const SizedBox(height: 8),
          _VersionRow(label: 'Build', value: info.buildNumber),
          const SizedBox(height: 8),
          _VersionRow(label: 'Package', value: info.packageName),
        ],
      ),
      actions: [
        StyledDialogAction(
          label: 'Close',
          isPrimary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  // ─── Actions ───────────────────────────────────────────────────────────────

  Future<void> _onRealtimeToggle(bool value) async {
    final settings = await ref.read(appSettingsServiceProvider.future);
    await settings.setPreferredSyncLayer(
       SyncLayer.blockchain,
    );
    if (!mounted) return;
    setState(() => _realtimeEnabled = value);
    ref.invalidate(indexerInitializerProvider);
    ref.invalidate(messagesNotifierProvider);
  }

  // ─── Push Notifications (opt-in) ─────────────────────────────────────────────────

  Future<void> _onTargetedPushToggle(bool value) async {
    void setBusy(String? msg) {
      if (!mounted) return;
      setState(() {
        _isPushBusy = msg != null;
        _pushBusyMessage = msg;
      });
    }

    try {
      if (value) {
        final accepted = await _showTargetedPushDualDisclosure();
        if (accepted != true) return;

        // Make sure OS-level permission is granted before promising the indexer
        // we can deliver alerts. NotificationService internally registers the
        // platform token (APNs / UnifiedPush) so the indexer can fetch it.
        setBusy('Requesting notification permission…');
        final granted = await NotificationService()
            .requestPermissionAndGetToken();
        if (!granted) {
          if (!mounted) return;
          showWarningSnackBar(context, 'Notification permission denied');
          return;
        }

        // Indexer registration is OHTTP-wrapped through Tor — typically a
        // few seconds, sometimes longer on cold circuits.
        setBusy('Registering push token over relay…');
        final indexerService = await ref.read(indexerServiceProvider.future);
        final ok = await indexerService.registerTargetedPush();
        if (!ok) {
          if (!mounted) return;
          showErrorSnackBar(context, 'Push Notifications registration failed');
          return;
        }

        setBusy('Saving preference…');
        final settings = await ref.read(appSettingsServiceProvider.future);
        await settings.setTargetedPushEnabled(true);
        if (!mounted) return;
        setState(() => _targetedPushEnabled = true);
      } else {
        setBusy('Unregistering over relay…');
        final indexerService = await ref.read(indexerServiceProvider.future);
        await indexerService.unregisterTargetedPush();
        final settings = await ref.read(appSettingsServiceProvider.future);
        await settings.setTargetedPushEnabled(false);
        if (!mounted) return;
        setState(() => _targetedPushEnabled = false);
      }
    } finally {
      setBusy(null);
    }
  }

  /// Two-paragraph privacy disclosure required before opting in to targeted
  /// push. The "I understand" checkbox is required to enable Accept — no
  /// auto-dismiss, no default-yes — see tasks/targeted_push_followups.md #4.
  Future<bool?> _showTargetedPushDualDisclosure() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const _TargetedPushDisclosureDialog(),
    );
  }

  Future<void> _setUsername() async {
    const minBalanceAlgo = 0.1;

    final controller = TextEditingController();
    final currentUser = ref.read(userProvider).value?.profile;
    if (currentUser?.username != null) {
      controller.text = currentUser!.username!;
    }

    final username = await StyledDialog.show<String>(
      context: context,
      title: currentUser?.username != null ? 'Edit Username' : 'Set Username',
      icon: CupertinoIcons.at,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Choose a unique username for your Sealed identity. This will '
            'be published on-chain.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          StyledDialogTextField(
            controller: controller,
            hintText: 'Enter username (3–20 characters)',
          ),
        ],
      ),
      actions: [
        StyledDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context),
        ),
        StyledDialogAction(
          label: 'Publish',
          isPrimary: true,
          onPressed: () => Navigator.pop(context, controller.text.trim()),
        ),
      ],
    );

    if (username == null || username.isEmpty) return;

    if (username.length < 3 || username.length > 20) {
      if (!mounted) return;
      showWarningSnackBar(
        context,
        'Username must be between 3 and 20 characters',
      );
      return;
    }

    setState(() => _isSettingUsername = true);
    try {
      final balance = ref.read(localWalletProvider).value?.balanceSol ?? 0.0;
      if (balance < minBalanceAlgo) {
        if (!mounted) return;
        showWarningSnackBar(
          context,
          'You need at least 0.001 ALGO to set a username. Please top up first.',
        );
        return;
      }

      await ref.read(userProvider.notifier).setUsername(username: username);
      if (!mounted) return;
      showInfoSnackBar(context, 'Username updated successfully');
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'Failed to set username: $e');
    } finally {
      if (mounted) setState(() => _isSettingUsername = false);
    }
  }

  Future<void> _forceResync() async {
    final confirmed = await StyledDialog.show<bool>(
      context: context,
      icon: CupertinoIcons.arrow_2_circlepath,
      iconColor: primaryColor,
      title: 'Reload Conversations?',
      content: const Text(
        'This will clear your message cache and re-download all messages '
        'from the blockchain. This may take a while.',
        style: TextStyle(color: Colors.white70, fontSize: 14),
      ),
      actions: [
        StyledDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context, false),
        ),
        StyledDialogAction(
          label: 'Reload',
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
    if (confirmed != true) return;

    setState(() => _isResyncing = true);
    try {
      await ref.read(messagesNotifierProvider.notifier).forceResync();
      if (!mounted) return;
      showInfoSnackBar(context, 'Resync complete ✅');
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'Resync failed: $e');
    } finally {
      if (mounted) setState(() => _isResyncing = false);
    }
  }

  Future<void> _logout() async {
    final seedPhrase = await ref
        .read(localWalletProvider.notifier)
        .getSeedPhraseForBackup();

    if (seedPhrase == null) {
      // No mnemonic — simple confirm + wipe.
      final confirmed = await StyledDialog.show<bool>(
        context: context,
        icon: CupertinoIcons.square_arrow_right,
        iconColor: _errorColor,
        title: 'Log Out?',
        content: const Text(
          'Are you sure you want to log out?',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          StyledDialogAction(
            label: 'Cancel',
            onPressed: () => Navigator.pop(context, false),
          ),
          StyledDialogAction(
            label: 'Log Out',
            isDestructive: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      );
      if (confirmed != true) return;
      await _performLogoutAndPop();
      return;
    }

    // Mnemonic exists — three-way choice. The user may not want to see
    // the phrase before logging out (e.g. already backed up). See
    // SPEC.md §4.
    //
    // Returns: 'phrase' → PIN-gated mnemonic dialog; 'logout' → wipe
    // immediately; null → cancel.
    final action = await StyledDialog.show<String>(
      context: context,
      icon: CupertinoIcons.exclamationmark_shield_fill,
      iconColor: Colors.orange,
      title: 'Log Out?',
      content: const Text(
        'Logging out will wipe local data on this device. Make sure you '
        'have your recovery phrase backed up — you will need it to '
        'recover your account.',
        style: TextStyle(color: Colors.white70, fontSize: 14),
      ),
      actions: [
      
        StyledDialogAction(
          label: 'Show Recovery Phrase',
          onPressed: () => Navigator.pop(context, 'phrase'),
        ),
        StyledDialogAction(
          label: 'Log Out',
          isDestructive: true,
          onPressed: () => Navigator.pop(context, 'logout'),
        ),
      ],
    );
    if (!mounted || action == null) return;

    if (action == 'logout') {
      await _performLogoutAndPop();
      return;
    }

    // action == 'phrase' — PIN re-entry then mnemonic display.
    final pinOk = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const PinConfirmScreen(
          headline: 'Confirm PIN',
          subhead: 'Enter your PIN to view your recovery phrase',
        ),
        fullscreenDialog: true,
      ),
    );
    if (pinOk != true || !mounted) return;

    const backupLabel = 'Recovery Phrase';
    final confirmed = await StyledDialog.show<bool>(
      context: context,
      icon: CupertinoIcons.exclamationmark_shield_fill,
      iconColor: Colors.orange,
      title: 'Backup Your $backupLabel',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Save this ${backupLabel.toLowerCase()} before logging out. '
            'You will need it to recover your account.',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
            ),
            child: SelectableText(
              seedPhrase,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Colors.white,
                height: 1.5,
              ),
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
          label: "I've saved it",
          isDestructive: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;

    await _performLogoutAndPop();
  }

  Future<void> _performLogoutAndPop() async {
    final container = ProviderScope.containerOf(context);
    if (mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
    try {
      await performLogout(container);
    } catch (e) {
      debugPrint('⚠️ Logout error: $e');
    }
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  String _truncateAddress(String address) {
    if (address.length <= 12) return address;
    return '${address.substring(0, 6)}...${address.substring(address.length - 4)}';
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Design-system building blocks — private to this screen.
// ════════════════════════════════════════════════════════════════════════════

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 2),
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 22 / 14,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _SettingsScreenState._sectionBg,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Container(
        height: 1,
        decoration: BoxDecoration(
          color: _SettingsScreenState._divider,
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({required this.icon, this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }
}

/// Asset paths for the Figma-sourced settings icons. Keeps the file free of
/// loose string literals and makes asset renames a single-point change.
class _SettingsIcons {
  static const String user = 'assets/icons/settings/User_01.svg';
  static const String creditCard = 'assets/icons/settings/Credit_Card_01.svg';
  static const String bell = 'assets/icons/settings/Bell.svg';
  static const String link = 'assets/icons/settings/Link.svg';
  static const String mobile = 'assets/icons/settings/Mobile.svg';
  static const String reload = 'assets/icons/settings/Arrows_Reload_01.svg';
  static const String algorand = 'assets/icons/settings/algorand.svg';
}

class _LeadingSvg extends StatelessWidget {
  const _LeadingSvg({required this.asset, this.color, this.size = 24});

  final String asset;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color!, BlendMode.srcIn),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.iconAsset,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String iconAsset;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _LeadingSvg(asset: iconAsset, color: primaryColor),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 22 / 14,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 12,
                  height: 22 / 12,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.iconAsset,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.isBusy = false,
  });

  final String iconAsset;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _LeadingSvg(asset: iconAsset, color: primaryColor),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 22 / 14,
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 12,
                        height: 22 / 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (isBusy) ...[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ],
          ),
        ),
        CupertinoSwitch(
          value: value,
          activeTrackColor: primaryColor,
          onChanged: isBusy ? null : onChanged,
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.iconAsset,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String iconAsset;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _LeadingSvg(asset: iconAsset, color: primaryColor),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 22 / 14,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 12,
                  height: 22 / 12,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.title,
    this.iconAsset,
    this.icon,
    this.useIconData = false,
    this.subtitle,
    this.onTap,
    this.titleColor,
    this.iconColor,
    this.chevronColor,
    this.trailing,
  }) : assert(
         iconAsset != null || icon != null,
         'Provide either iconAsset (SVG) or icon (IconData).',
       );

  final String? iconAsset;
  final IconData? icon;
  final bool useIconData;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Color? titleColor;
  final Color? iconColor;
  final Color? chevronColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final Color resolvedIconColor = iconColor ?? primaryColor;
    final Widget leading = useIconData && icon != null
        ? Icon(icon, size: 24, color: resolvedIconColor)
        : _LeadingSvg(asset: iconAsset!, color: resolvedIconColor);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: titleColor ?? Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 22 / 14,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 12,
                        height: 22 / 12,
                      ),
                    ),
                ],
              ),
            ),
            trailing ??
                Icon(
                  CupertinoIcons.chevron_right,
                  size: 20,
                  color: chevronColor ?? Colors.white.withValues(alpha: 0.6),
                ),
          ],
        ),
      ),
    );
  }
}

class _BalanceRow extends StatelessWidget {
  const _BalanceRow({
    required this.balance,
    required this.sendableMessages,
    required this.onTopUp,
  });

  final double balance;
  final int sendableMessages;
  final VoidCallback onTopUp;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              // Algorand mark — Figma-sourced SVG.
              SizedBox(
                width: 24,
                height: 24,
                child: SvgPicture.asset(_SettingsIcons.algorand),
              ),
              const SizedBox(width: 8),
              Text(
                balance.toStringAsFixed(2),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  height: 22 / 12,
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  'enough to send $sendableMessages Messages',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                    height: 22 / 12,
                  ),
                ),
              ),
            ],
          ),
        ),
        _GradientPill(label: 'Top Up', onTap: onTopUp, glow: true),
      ],
    );
  }
}

class _GradientPill extends StatelessWidget {
  const _GradientPill({
    required this.label,
    required this.onTap,
    this.glow = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF006857), Color(0xFF00332B)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: BorderRadius.circular(8),
          boxShadow: glow
              ? [
                  BoxShadow(
                    color: const Color(0xFF00937B).withValues(alpha: 0.24),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            height: 22 / 12,
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Targeted-push dual-disclosure consent dialog.
//
// Two paragraphs the user MUST read before opting in:
//   1. The indexer learns *which* on-chain messages are yours (it gets
//      view_priv and trial-decrypts each event).
//   2. Apple/Google see one wake-up per matched message — that's per-message
//      timing metadata leaked to the OS push provider.
//
// "I understand" is unchecked by default; Accept stays disabled until it is
// ticked. No auto-dismiss, no barrier-tap dismiss.
// ════════════════════════════════════════════════════════════════════════════
class _TargetedPushDisclosureDialog extends StatefulWidget {
  const _TargetedPushDisclosureDialog();

  @override
  State<_TargetedPushDisclosureDialog> createState() =>
      _TargetedPushDisclosureDialogState();
}

class _TargetedPushDisclosureDialogState
    extends State<_TargetedPushDisclosureDialog> {
  bool _understood = false;

  @override
  Widget build(BuildContext context) {
    return StyledDialog(
      
      icon: CupertinoIcons.exclamationmark_shield_fill,
      iconColor: Colors.orange,
      title: 'Enable Push Notifications?',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(0),
           
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                _DisclosureSection(
                  emoji: '📡',
                  title: 'Sealed Relay Server',
                  sees: ['When you receive a message'],
                  cantSee: [
                    'Message contents',
                    'Who sent the message',
                    'Your IP address (Tor + OHTTP)',
                  ],
                ),
                SizedBox(height: 16),
                _DisclosureSection(
                  emoji: '📱',
                  title: 'Apple / Google Push',
                  sees: ['Per-message wake timing'],
                  cantSee: ['Message contents', 'Sender or conversation'],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: () => setState(() => _understood = !_understood),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _understood
                        ? CupertinoIcons.checkmark_square_fill
                        : CupertinoIcons.square,
                    size: 22,
                    color: _understood ? primaryColor : Colors.white70,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'I understand both privacy trade-offs.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
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
          label: 'Accept',
          isPrimary: true,
          onPressed: _understood ? () => Navigator.pop(context, true) : null,
        ),
      ],
    );
  }
}

/// One section inside the shared targeted-push disclosure card. Shows what a
/// given party (Tor indexer / OS push provider) sees and can't see, as short
/// bullet lists. Multiple sections are stacked inside a single outer card.
class _DisclosureSection extends StatelessWidget {
  const _DisclosureSection({
    required this.emoji,
    required this.title,
    required this.sees,
    required this.cantSee,
  });

  final String emoji;
  final String title;
  final List<String> sees;
  final List<String> cantSee;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _BulletGroup(
          label: 'Sees',
          labelColor: Colors.orange,
          icon: CupertinoIcons.eye_fill,
          items: sees,
        ),
        const SizedBox(height: 8),
        _BulletGroup(
          label: 'Can\'t see',
          labelColor: primaryColor,
          icon: CupertinoIcons.eye_slash_fill,
          items: cantSee,
        ),
      ],
    );
  }
}

class _BulletGroup extends StatelessWidget {
  const _BulletGroup({
    required this.label,
    required this.labelColor,
    required this.icon,
    required this.items,
  });

  final String label;
  final Color labelColor;
  final IconData icon;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, size: 13, color: labelColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: labelColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 19),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '•  ',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          item,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// Spinning onion animation removed - replaced with standard progress indicator

class _VersionRow extends StatelessWidget {
  const _VersionRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 13),
        ),
        Flexible(
          child: SelectableText(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
