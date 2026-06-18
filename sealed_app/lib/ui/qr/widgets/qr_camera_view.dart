import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_gap/flutter_gap.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:sealed_app/ui/shared/theme.dart';
import 'package:sealed_app/ui/shared/widgets/sealed_layout.dart';
import 'package:sealed_app/ui/shared/widgets/topbar.dart';

/// Shared camera-scanner chrome for the QR screens.
///
/// Owns the camera lifecycle and app-consistent layout only — it does NOT
/// classify payloads or navigate. Each scanned QR string is forwarded raw to
/// [onScan]; the host screen decides what a payload means (classify, assemble
/// handshake frames, pop a result, …) and owns its own busy/error states.
///
/// The host receives the [QRViewController] via [onControllerReady] so it can
/// pause/resume the camera (e.g. on a one-shot detection) without this widget
/// knowing anything about the host's flow.
class QrCameraView extends StatefulWidget {
  const QrCameraView({
    super.key,
    required this.topBarLabel,
    required this.onScan,
    this.onControllerReady,
    this.onBackTap,
    this.hint = 'Place the QR code within the frame',
  });

  /// [TopBar] label, e.g. "Scan QR" / "Scan Key".
  final String topBarLabel;

  /// Called for each non-empty decoded QR payload.
  final void Function(String code) onScan;

  /// Handed the controller once the camera is created, for pause/resume.
  final void Function(QRViewController controller)? onControllerReady;

  /// Optional back-button override (defaults to `Navigator.pop`).
  final VoidCallback? onBackTap;

  /// Caption under the camera frame.
  final String hint;

  @override
  State<QrCameraView> createState() => _QrCameraViewState();
}

class _QrCameraViewState extends State<QrCameraView> {
  final GlobalKey _qrKey = GlobalKey(debugLabel: 'QrCameraView');
  QRViewController? _controller;

  // iOS Simulator has no camera — QRView hard-crashes there. Detect it via the
  // app binary path (sandbox strips SIMULATOR_* env vars) and show a
  // placeholder so the layout stays viewable.
  bool get _noCamera =>
      Platform.isIOS && Platform.resolvedExecutable.contains('CoreSimulator');

  void _onQRViewCreated(QRViewController controller) {
    _controller = controller;
    widget.onControllerReady?.call(controller);
    controller.scannedDataStream.listen((scanData) {
      final value = scanData.code;
      if (value == null || value.isEmpty) return;
      widget.onScan(value);
    });
  }

  // qr_code_scanner_plus needs the camera paused/resumed on hot reload.
  @override
  void reassemble() {
    super.reassemble();
    if (Platform.isAndroid) {
      _controller?.pauseCamera();
    }
    _controller?.resumeCamera();
  }

  @override
  Widget build(BuildContext context) {
    return SealedLayout(
      crossAxisAlignment: CrossAxisAlignment.start,
      topBar: TopBar(label: widget.topBarLabel, onBackTap: widget.onBackTap),
      expandedBody: Padding(
        padding: EdgeInsets.only(top: 12.h),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16.r),
            border: Border.all(color: primaryColor, width: 1.w),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16.r),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _noCamera
                    ? _cameraPlaceholder()
                    : QRView(key: _qrKey, onQRViewCreated: _onQRViewCreated),
                // Center target box — shows where to place the QR.
                Center(
                  child: Container(
                    width: 200.w,
                    height: 200.w,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8.r),
                      border: Border.all(color: primaryColor, width: 1.w),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      children: [
        Text(
          widget.hint,
          style: Theme.of(
            context,
          ).textTheme.labelMedium!.copyWith(color: primaryColor),
        ),
      ],
    );
  }

  Widget _cameraPlaceholder() {
    return Container(
      color: Colors.white.withValues(alpha: 0.04),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.no_photography_outlined,
            size: 40.w,
            color: Colors.white.withValues(alpha: 0.4),
          ),
          Gap(12.h),
          Text(
            "Camera unavailable on Simulator",
            style: Theme.of(
              context,
            ).textTheme.bodyMedium!.copyWith(color: neutralColor),
          ),
        ],
      ),
    );
  }
}
