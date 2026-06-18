// import 'dart:async';

// import 'package:flutter/cupertino.dart';
// import 'package:flutter/material.dart';
// import 'package:flutter/services.dart';
// import 'package:flutter_riverpod/flutter_riverpod.dart';
// import 'package:qr_flutter/qr_flutter.dart';

// import 'package:sealed_app/providers/message_provider.dart';
// import 'package:sealed_app/providers/wallet_provider.dart';
// import 'package:sealed_app/features/messaging/alias/alias_onboarding_service.dart';
// import 'package:sealed_app/ui/shared/theme.dart';
// import 'package:sealed_app/ui/shared/widgets/snackbars.dart';

// /// Settings → "My QR Code". Shows the user's wallet address as a single-frame
// /// QR so a contact can scan it to start a normal chat, plus the address as
// /// selectable monospaced text with a copy button.
// ///
// /// While mounted it also polls for incoming `sealed://alias?` invite URIs and
// /// auto-routes into [AcceptAliasChatScreen] — the legacy on-chain alias
// /// receiver path (dormant, retained for plain-address scans).
// ///
// /// The offline (camera-to-camera) alias handshake moved to the dedicated
// /// offline-connection screens (`ui/chats/screens/alias/`).
// class QrDisplayScreen extends ConsumerStatefulWidget {
//   /// Test seam: when false the periodic message poll is not started.
//   final bool enablePolling;

//   const QrDisplayScreen({super.key, this.enablePolling = true});

//   @override
//   ConsumerState<QrDisplayScreen> createState() => _QrDisplayScreenState();
// }

// class _QrDisplayScreenState extends ConsumerState<QrDisplayScreen> {
//   static const Duration _pollInterval = Duration(seconds: 3);
//   static const String _aliasUriPrefix = 'sealed://alias?';

//   Timer? _pollTimer;
//   bool _polling = false;
//   bool _navigated = false;
//   bool _baselineLoaded = false;
//   // URIs that already existed on screen open — never auto-accept these.
//   final Set<String> _baselineInvites = <String>{};
//   // URIs we've already routed (or decided to skip) this session.
//   final Set<String> _handledInvites = <String>{};

//   @override
//   void initState() {
//     super.initState();
//     if (widget.enablePolling) {
//       _pollTimer = Timer.periodic(_pollInterval, (_) => _pollOnce());
//       // Kick off an immediate sync so we don't wait the full interval on open.
//       WidgetsBinding.instance.addPostFrameCallback((_) => _pollOnce());
//     }
//   }

//   @override
//   void dispose() {
//     _pollTimer?.cancel();
//     _pollTimer = null;
//     super.dispose();
//   }

//   Future<void> _pollOnce() async {
//     if (_polling || _navigated || !mounted) return;
//     _polling = true;
//     try {
//       await ref.read(messagesNotifierProvider.notifier).syncMessages();
//       if (!mounted || _navigated) return;

//       final conversations = ref.read(messagesNotifierProvider).asData?.value;
//       if (conversations == null) return;

//       // First successful poll → snapshot the existing alias URIs as the
//       // baseline. Anything in this set predates the screen opening and
//       // must not auto-accept.
//       if (!_baselineLoaded) {
//         for (final c in conversations) {
//           final preview = c.lastMessageContent ?? '';
//           if (!c.isLastMessageOutgoing && preview.startsWith(_aliasUriPrefix)) {
//             _baselineInvites.add(preview);
//           }
//         }
//         _baselineLoaded = true;
//         return;
//       }

//       for (final c in conversations) {
//         final preview = c.lastMessageContent ?? '';
//         if (c.isLastMessageOutgoing) continue;
//         if (!preview.startsWith(_aliasUriPrefix)) continue;
//         if (_baselineInvites.contains(preview)) continue;
//         if (_handledInvites.contains(preview)) continue;

//         // Skip invites already accepted (contact exists in repo).
//         final parsedUri = AliasOnboardingService.parseInviteUri(preview);
//         if (parsedUri != null) {
//           final existingId = await ref.read(
//             aliasContactIdByInviteSecretProvider(parsedUri.inviteSecret).future,
//           );
//           if (existingId != null) {
//             _handledInvites.add(preview);
//             continue;
//           }
//         }

//         _handledInvites.add(preview);
//         _navigated = true;
//         _pollTimer?.cancel();
//         _pollTimer = null;

//         if (!mounted) return;
//         AcceptAliasChatScreen.handleInviteUri(
//           context,
//           preview,
//           senderUsername: c.contactUsername,
//         );
//         break;
//       }
//     } catch (_) {
//       // Swallow: polling is best-effort. Next tick will retry.
//     } finally {
//       _polling = false;
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     final walletState = ref.watch(walletProvider);

//     return Scaffold(
//       body: Container(
//         decoration: BoxDecoration(gradient: sealedBackgroundGradient),
//         child: SafeArea(
//           child: Column(
//             children: [
//               _buildAppBar(context),
//               Expanded(
//                 child: walletState.when(
//                   data: (state) {
//                     final address = state.walletAddress;
//                     if (address == null || address.isEmpty) {
//                       return const _Message(
//                         text: 'No wallet address available.',
//                       );
//                     }
//                     return _buildQrBody(address);
//                   },
//                   loading: () =>
//                       const Center(child: CircularProgressIndicator()),
//                   error: (e, _) => _Message(text: 'Error loading wallet: $e'),
//                 ),
//               ),
//             ],
//           ),
//         ),
//       ),
//     );
//   }

//   Widget _buildAppBar(BuildContext context) {
//     return SizedBox(
//       height: 56,
//       child: Row(
//         children: [
//           IconButton(
//             icon: const Icon(CupertinoIcons.back, color: Colors.white),
//             onPressed: () => Navigator.of(context).pop(),
//           ),
//           const Text(
//             'My QR Code',
//             style: TextStyle(
//               color: Colors.white.withValues(alpha: 0.9),
//               fontSize: 16,
//               fontWeight: FontWeight.w600,
//               height: 22 / 16,
//             ),
//           ),
//         ],
//       ),
//     );
//   }

//   Widget _buildQrBody(String address) {
//     return SingleChildScrollView(
//       padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
//       child: Column(
//         mainAxisAlignment: MainAxisAlignment.center,
//         children: [
//           Container(
//             padding: const EdgeInsets.all(16),
//             decoration: BoxDecoration(
//               color: Colors.white.withValues(alpha: 0.9),
//               borderRadius: BorderRadius.circular(16),
//             ),
//             child: QrImageView(
//               data: address,
//               version: QrVersions.auto,
//               size: 240,
//               gapless: false,
//               backgroundColor: Colors.white.withValues(alpha: 0.9),
//               eyeStyle: const QrEyeStyle(
//                 eyeShape: QrEyeShape.square,
//                 color: Colors.black,
//               ),
//               dataModuleStyle: const QrDataModuleStyle(
//                 dataModuleShape: QrDataModuleShape.square,
//                 color: Colors.black,
//               ),
//             ),
//           ),
//           const SizedBox(height: 24),
//           Container(
//             padding: const EdgeInsets.all(12),
//             decoration: BoxDecoration(
//               color: cardColor,
//               borderRadius: BorderRadius.circular(12),
//             ),
//             child: SelectableText(
//               address,
//               textAlign: TextAlign.center,
//               style: const TextStyle(
//                 color: Colors.white.withValues(alpha: 0.9),
//                 fontFamily: 'monospace',
//                 fontSize: 12,
//                 height: 1.4,
//               ),
//             ),
//           ),
//           const SizedBox(height: 16),
//           TextButton.icon(
//             icon: Icon(CupertinoIcons.doc_on_doc, color: primaryColor),
//             label: Text('Copy address', style: TextStyle(color: primaryColor)),
//             onPressed: () async {
//               await Clipboard.setData(ClipboardData(text: address));
//               if (!mounted) return;
//               showInfoSnackBar(context, 'Address copied');
//             },
//           ),
//           const SizedBox(height: 16),
//           Text(
//             'Have a contact scan this to start a chat.',
//             textAlign: TextAlign.center,
//             style: TextStyle(
//               color: Colors.white.withValues(alpha: 0.6),
//               fontSize: 13,
//             ),
//           ),
//         ],
//       ),
//     );
//   }
// }

// class _Message extends StatelessWidget {
//   const _Message({required this.text});

//   final String text;

//   @override
//   Widget build(BuildContext context) {
//     return Center(
//       child: Padding(
//         padding: const EdgeInsets.all(24),
//         child: Text(
//           text,
//           textAlign: TextAlign.center,
//           style: const TextStyle(color: Colors.white),
//         ),
//       ),
//     );
//   }
// }
