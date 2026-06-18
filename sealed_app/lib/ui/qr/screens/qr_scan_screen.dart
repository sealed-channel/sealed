import 'package:flutter/material.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

import 'package:sealed_app/features/messaging/alias/offline_handshake_codec.dart';
import 'package:sealed_app/ui/qr/screens/scan_classifier.dart';
import 'package:sealed_app/ui/qr/widgets/qr_camera_view.dart';
import 'package:sealed_app/ui/shared/widgets/snackbars.dart';

/// Settings → "Scan QR". Opens the camera (shared [QrCameraView] chrome),
/// decodes QR codes, and pops with a [ScannedQrResult] for the first payload it
/// can classify — either a legacy single-frame wallet address, or a combined
/// multi-frame QR (address + alias invite envelope) from the *My QR Code*
/// screen. Mid-stream handshake frames accumulate silently; unrecognized
/// payloads show a transient SnackBar and the camera keeps scanning.
///
/// The caller (routing glue) handles the returned result: self-scan check,
/// username resolution, route to chat.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final OfflineHandshakeAccumulator _acc = OfflineHandshakeCodec.decoder();
  QRViewController? _controller;
  bool _handled = false;
  DateTime _lastInvalidToast = DateTime.fromMillisecondsSinceEpoch(0);

  void _onScan(String value) {
    if (_handled) return;
    switch (classifyScan(value, _acc)) {
      case ScanAddress(:final address):
        _finish(ScannedQrResult(address: address));
      case ScanCombined(:final address, :final inviteEnvelope):
        _finish(
          ScannedQrResult(address: address, inviteEnvelope: inviteEnvelope),
        );
      case ScanAccumulating():
        // Mid-stream handshake frame — keep scanning, stay silent.
        break;
      case ScanInvalid():
        _showInvalidToast();
    }
  }

  void _finish(ScannedQrResult result) {
    _handled = true;
    _controller?.pauseCamera();
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  void _showInvalidToast() {
    final now = DateTime.now();
    // Throttle to one toast per ~1.5s — the camera fires detections rapidly.
    if (now.difference(_lastInvalidToast).inMilliseconds < 1500) return;
    _lastInvalidToast = now;
    if (!mounted) return;
    showWarningSnackBar(
      context,
      "Invalid QR — expected a contact's QR code.",
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    return QrCameraView(
      topBarLabel: 'Scan QR',
      hint: "Point camera at a contact's QR code",
      onControllerReady: (c) => _controller = c,
      onScan: _onScan,
    );
  }
}
