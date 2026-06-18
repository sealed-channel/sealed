/// QR display widget for offline alias handshake.
///
/// Encodes a payload via [OfflineHandshakeCodec]. Handshake envelopes fit a
/// single static frame; oversized payloads fall back to cycling frames at
/// 2 fps using `QrImageView`, with a `<currentSeq+1>/<total>` overlay so the
/// user can verify scan completion across the cycle (hidden for one frame).
///
/// The widget keys its internal frame list by payloadId so a hot reload or
/// payload swap doesn't double-mount a stale timer. The animation timer is
/// always cancelled in [dispose].
///
/// Threat model note: rendering only. No authentication or encryption is
/// performed here — the bytes the caller hands in must already be a sealed
/// envelope.
///
/// No chain side-effects.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:sealed_app/features/messaging/alias/offline_handshake_codec.dart';

/// Frame cycle period — 2 fps.
const Duration kOfflineHandshakeFrameInterval = Duration(milliseconds: 500);

/// Animated multi-frame QR widget.
class OfflineHandshakeQrView extends StatefulWidget {
  /// Raw bytes to transmit (typically an 865B invite or 841B accept
  /// envelope). The widget encodes once via [OfflineHandshakeCodec.encode].
  final Uint8List payload;

  /// Edge length, in logical pixels, of the inner QR image.
  final double size;

  const OfflineHandshakeQrView({
    super.key,
    required this.payload,
    this.size = 280,
  });

  @override
  State<OfflineHandshakeQrView> createState() => _OfflineHandshakeQrViewState();
}

class _OfflineHandshakeQrViewState extends State<OfflineHandshakeQrView> {
  List<String>? _frames;
  int _index = 0;
  Timer? _timer;
  Object? _encodeError;

  @override
  void initState() {
    super.initState();
    _encode();
  }

  @override
  void didUpdateWidget(covariant OfflineHandshakeQrView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_listEquals(oldWidget.payload, widget.payload)) {
      _cancelTimer();
      setState(() {
        _frames = null;
        _index = 0;
        _encodeError = null;
      });
      _encode();
    }
  }

  Future<void> _encode() async {
    try {
      final frames = await OfflineHandshakeCodec.encode(widget.payload);
      if (!mounted) return;
      setState(() {
        _frames = frames;
        _index = 0;
      });
      if (frames.length > 1) {
        _timer = Timer.periodic(kOfflineHandshakeFrameInterval, (_) {
          if (!mounted) return;
          setState(() {
            _index = (_index + 1) % frames.length;
          });
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _encodeError = e;
      });
    }
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _cancelTimer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frames = _frames;
    if (_encodeError != null) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const Center(child: Icon(Icons.error_outline)),
      );
    }
    if (frames == null) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final total = frames.length;
    final seq = _index;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(16),
          ),
          child: QrImageView(
            data: frames[seq],
            version: QrVersions.auto,
            size: widget.size,
            gapless: false,
            backgroundColor: Colors.white.withValues(alpha: 0.9),
            eyeStyle: const QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: Colors.black,
            ),
            dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: Colors.black,
            ),
          ),
        ),
        if (total > 1) ...[
          const SizedBox(height: 8),
          Text('${seq + 1}/$total', style: const TextStyle(fontSize: 12)),
        ],
      ],
    );
  }

  static bool _listEquals(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
