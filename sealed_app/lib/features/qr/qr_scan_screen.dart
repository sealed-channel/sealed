import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

import 'package:sealed_app/features/qr/qr_address_validator.dart';
import 'package:sealed_app/shared/widgets/theme.dart';
import 'package:sealed_app/core/snackbars.dart';

/// Settings → "Scan QR". Opens the camera, decodes QR codes, and pops with
/// the first valid Algorand wallet address it sees. Invalid scans show a
/// transient SnackBar and the camera keeps scanning.
///
/// The caller (T5 routing glue) is responsible for handling the returned
/// address: self-scan check, picker sheet, route to chat.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final GlobalKey _qrKey = GlobalKey(debugLabel: 'QR');
  bool _handled = false;
  DateTime _lastInvalidToast = DateTime.fromMillisecondsSinceEpoch(0);

  void _onQRViewCreated(QRViewController controller) {
    controller.scannedDataStream.listen((scanData) {
      if (_handled) return;
      final value = scanData.code;
      if (value == null) return;
      final trimmed = value.trim();
      if (isValidAlgorandAddress(trimmed)) {
        _handled = true;
        controller.pauseCamera();
        if (!mounted) return;
        Navigator.of(context).pop(trimmed);
        return;
      }
      _showInvalidToast();
    });
  }

  void _showInvalidToast() {
    final now = DateTime.now();
    // Throttle to one toast per ~1.5s — the camera fires detections rapidly.
    if (now.difference(_lastInvalidToast).inMilliseconds < 1500) return;
    _lastInvalidToast = now;
    if (!mounted) return;
    showWarningSnackBar(
      context,
      'Invalid QR — expected a wallet address.',
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          QRView(
            key: _qrKey,
            onQRViewCreated: _onQRViewCreated,
            overlay: QrScannerOverlayShape(
              borderColor: primaryColor,
              borderRadius: 12,
              borderLength: 28,
              borderWidth: 6,
              cutOutSize: 260,
            ),
          ),
          // Top app bar (translucent over camera preview)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      CupertinoIcons.back,
                      color: Colors.white,
                      size: 28,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Text(
                    'Scan QR',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Bottom hint
          Positioned(
            left: 0,
            right: 0,
            bottom: 32,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  "Point camera at a contact's QR code",
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
