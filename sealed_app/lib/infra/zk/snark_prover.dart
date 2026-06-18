// snark_prover.dart — Dart API + flutter_js binding for the snarkjs
// Groth16 prover used by the SNARK-per-redeem flow (SPEC-snark-redeem-B).
//
// The previous rapidsnark FFI backend was removed: it required a
// non-trivial native build (rapidsnark + circom-witnesscalc + GMP) that
// proved infeasible to ship. snarkjs in QuickJS via flutter_js is ~3x
// slower (3–10s on device) and ~3 MB heavier but ships as plain assets.
//
// Vendored asset: assets/snark/snarkjs.min.js  (snarkjs v0.7.6)
// Refresh with:
//   curl -L https://unpkg.com/snarkjs@<ver>/build/snarkjs.min.js \
//        -o sealed_app/assets/snark/snarkjs.min.js
//
// Public surface preserved verbatim from the FFI version so CreditsService
// and existing tests keep compiling:
//
//   final prover = SnarkProver.platform();
//   final cancel = CancelToken();
//   final result = await prover.generateProof(
//     zkeyBytes: ..., wasmBytes: ..., input: {...},
//     cancel: cancel,
//   );
//   // result.proof          : 256 bytes (A.x|A.y | B.x0|x1|y0|y1 | C.x|C.y) BE
//   // result.publicSignals  : [root, nullifier, recipient, denomination]
//
// Cancellation: QuickJS cannot interrupt a running fullProve, so cancel()
// is checked before the JS call returns and at coarse boundaries only —
// see CancelToken.cancel() doc. UI should show a determinate spinner.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_js/flutter_js.dart';

/// Result of a successful proof generation.
class ProofResult {
  ProofResult({required this.proof, required this.publicSignals});

  /// Groth16 proof, 256 bytes:
  /// `A.x | A.y | B.x0 | B.x1 | B.y0 | B.y1 | C.x | C.y`, each 32B big-endian.
  /// Matches `programs/sealed/src/__tests__/integration/redeem_with_proof.test.ts`
  /// `proofBytes()` exactly.
  final Uint8List proof;

  /// Public signals in circuit-emit order:
  /// `[root, nullifier, recipient, denomination]`.
  final List<BigInt> publicSignals;

  /// Convenience: nullifier == publicSignals[1].
  BigInt get nullifier => publicSignals[1];
}

/// Why a proof attempt failed.
enum SnarkProverErrorKind {
  generic,
  badInput,
  badZkey,
  cancelled,
  oom,
  witness,
  unavailable,
}

class SnarkProverException implements Exception {
  SnarkProverException(this.kind, this.message);
  final SnarkProverErrorKind kind;
  final String message;
  @override
  String toString() => 'SnarkProverException($kind): $message';
}

/// Cooperative cancellation. With the QuickJS backend cancel() is best
/// effort — snarkjs.groth16.fullProve is not interruptible mid-MSM. The
/// flag is checked before the proof starts; once it has started the
/// proof will run to completion and the result is discarded.
class CancelToken {
  CancelToken();

  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() {
    _cancelled = true;
  }
}

/// Prover API. Single implementation today (`_JsSnarkProver`); abstract
/// class lets tests swap in a fake without booting a JS runtime.
abstract class SnarkProver {
  Future<ProofResult> generateProof({
    required Uint8List zkeyBytes,
    Uint8List? wasmBytes,
    Uint8List? witnessDatBytes,
    required Map<String, dynamic> input,
    required CancelToken cancel,
  });

  /// Returns the platform binding.
  ///
  /// Android → [_WebViewSnarkProver]: flutter_js's Android QuickJS has no
  /// BigInt, so snarkjs.min.js fails to parse there. The system WebView
  /// (Chromium/V8) has BigInt + native WebAssembly and runs snarkjs unmodified.
  ///
  /// iOS / other → [_JsSnarkProver]: flutter_js uses JavaScriptCore there,
  /// which has BigInt — the in-process path is lighter and already proven.
  ///
  /// Throws [SnarkProverException] (kind=unavailable) if the chosen runtime
  /// can't initialise (e.g. pure-VM unit tests without the platform shim).
  factory SnarkProver.platform() =>
      Platform.isAndroid ? _WebViewSnarkProver() : _JsSnarkProver();
}

// ---------------------------------------------------------------------------
// flutter_js / snarkjs binding
// ---------------------------------------------------------------------------

const String _kSnarkJsAsset = 'assets/snark/snarkjs.min.js';

/// Bootstrap shim: snarkjs.min.js is built as a UMD module that expects
/// `module`, `exports`, `process`, etc. QuickJS has none of these, so we
/// fabricate the minimum scaffolding and hoist `snarkjs` onto globalThis.
const String _kBootstrapJs = r'''
var module = { exports: {} };
var exports = module.exports;
var process = {
  env: {},
  browser: true,
  version: 'v0.0.0',
  nextTick: function (cb) { cb(); },
};
var window = globalThis;
var self = globalThis;
function require(_n) { throw new Error('require() not supported: ' + _n); }
function _b64ToU8(b64) {
  var bin = atob(b64);
  var len = bin.length;
  var out = new Uint8Array(len);
  for (var i = 0; i < len; i++) out[i] = bin.charCodeAt(i);
  return out;
}
// Minimal atob polyfill — QuickJS doesn't ship one.
if (typeof atob === 'undefined') {
  var _b64chars =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var _b64lookup = new Int8Array(128);
  for (var i = 0; i < _b64chars.length; i++) _b64lookup[_b64chars.charCodeAt(i)] = i;
  globalThis.atob = function (str) {
    str = String(str).replace(/=+$/, '');
    var out = '';
    var bc = 0, bs = 0;
    for (var i = 0; i < str.length; i++) {
      var c = _b64lookup[str.charCodeAt(i) & 0x7f];
      if (c < 0) continue;
      bs = (bc % 4) ? (bs * 64 + c) : c;
      if (bc++ % 4) out += String.fromCharCode(255 & (bs >> ((-2 * bc) & 6)));
    }
    return out;
  };
}
// Minimal btoa polyfill — QuickJS doesn't ship one. snarkjs uses it for
// base64-encoding Uint8Array data (e.g. logs, file blobs).
if (typeof btoa === 'undefined') {
  var _b64encChars =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  globalThis.btoa = function (str) {
    str = String(str);
    var out = '';
    var i = 0;
    while (i < str.length) {
      var c1 = str.charCodeAt(i++) & 0xff;
      var c2 = i < str.length ? str.charCodeAt(i++) & 0xff : NaN;
      var c3 = i < str.length ? str.charCodeAt(i++) & 0xff : NaN;
      var e1 = c1 >> 2;
      var e2 = ((c1 & 3) << 4) | (c2 >> 4);
      var e3 = isNaN(c2) ? 64 : (((c2 & 15) << 2) | (c3 >> 6));
      var e4 = isNaN(c3) ? 64 : (c3 & 63);
      out += _b64encChars.charAt(e1) + _b64encChars.charAt(e2) +
             (e3 === 64 ? '=' : _b64encChars.charAt(e3)) +
             (e4 === 64 ? '=' : _b64encChars.charAt(e4));
    }
    return out;
  };
}
''';

const String _kHoistJs = r'''
if (typeof snarkjs === 'undefined' && module && module.exports) {
  globalThis.snarkjs = module.exports;
}
(typeof snarkjs !== 'undefined' && snarkjs.groth16) ? 'ok' : 'missing';
''';

class _JsSnarkProver implements SnarkProver {
  @override
  Future<ProofResult> generateProof({
    required Uint8List zkeyBytes,
    Uint8List? wasmBytes,
    Uint8List? witnessDatBytes,
    required Map<String, dynamic> input,
    required CancelToken cancel,
  }) async {
    if (zkeyBytes.isEmpty) {
      throw SnarkProverException(
        SnarkProverErrorKind.badZkey,
        'zkeyBytes empty',
      );
    }
    if (wasmBytes == null || wasmBytes.isEmpty) {
      throw SnarkProverException(
        SnarkProverErrorKind.badInput,
        'wasmBytes required (witnessDatBytes is no longer supported — '
        'rapidsnark witness tape path was removed)',
      );
    }
    if (cancel.isCancelled) {
      throw SnarkProverException(SnarkProverErrorKind.cancelled, 'pre-call');
    }

    JavascriptRuntime? rt;
    try {
      rt = getJavascriptRuntime();
    } catch (e) {
      throw SnarkProverException(
        SnarkProverErrorKind.unavailable,
        'flutter_js init failed: $e',
      );
    }
    try {
      // 1. Load snarkjs.min.js from the Flutter asset bundle.
      final String snarkSrc;
      try {
        snarkSrc = await rootBundle.loadString(_kSnarkJsAsset, cache: true);
      } catch (e) {
        throw SnarkProverException(
          SnarkProverErrorKind.unavailable,
          'asset $_kSnarkJsAsset missing — '
          'run scripts/copy snark assets or refresh per file header',
        );
      }
      _eval(rt, _kBootstrapJs, 'bootstrap');
      _eval(rt, snarkSrc, 'snarkjs.min.js');
      final hoist = _eval(rt, _kHoistJs, 'hoist');
      if (hoist.stringResult != 'ok') {
        throw SnarkProverException(
          SnarkProverErrorKind.unavailable,
          'snarkjs.groth16 not found after load',
        );
      }

      // 2. Push the proving artifacts in as Uint8Array. base64 keeps the
      //    payload ASCII-safe across the platform channel and avoids any
      //    JSON-string escaping cost.
      final zkeyB64 = base64.encode(zkeyBytes);
      final wasmB64 = base64.encode(wasmBytes);
      _eval(
        rt,
        "globalThis.__sealed_zkey = _b64ToU8('$zkeyB64');",
        'load-zkey',
      );
      _eval(
        rt,
        "globalThis.__sealed_wasm = _b64ToU8('$wasmB64');",
        'load-wasm',
      );

      // 3. Push circuit input. Decimal strings only — circom signals are
      //    field elements and BigInt round-tripping through JSON is lossy
      //    for values > 2^53, so we encode every value as a string and
      //    let snarkjs/ffjavascript parse with BigInt.
      final inputJson = jsonEncode(_stringifyFr(input));
      _eval(rt, 'globalThis.__sealed_input = $inputJson;', 'load-input');

      if (cancel.isCancelled) {
        throw SnarkProverException(SnarkProverErrorKind.cancelled, 'pre-prove');
      }

      // 4. Call snarkjs.groth16.fullProve. It returns a Promise; flutter_js
      //    `handlePromise` awaits it for us. We serialise the result on the
      //    JS side so the result coming back is a plain JSON string.
      const proveScript = r'''
(async () => {
  const r = await snarkjs.groth16.fullProve(
    globalThis.__sealed_input,
    globalThis.__sealed_wasm,
    globalThis.__sealed_zkey,
  );
  // Free the big buffers right away — snarkjs keeps internal copies.
  globalThis.__sealed_zkey = null;
  globalThis.__sealed_wasm = null;
  globalThis.__sealed_input = null;
  return JSON.stringify(r);
})()
''';
      final raw = await rt.handlePromise(rt.evaluate(proveScript));
      if (raw.isError) {
        throw _jsErrorToException(raw.stringResult);
      }

      if (cancel.isCancelled) {
        throw SnarkProverException(
          SnarkProverErrorKind.cancelled,
          'post-prove',
        );
      }

      // 5. Decode {proof, publicSignals}. flutter_js may return either the
      //    raw JSON string from JS land OR an already-parsed Map (depends on
      //    platform impl). Normalise to Map<String, dynamic>.
      dynamic decodedAny = jsonDecode(raw.stringResult);
      if (decodedAny is String) {
        // Double-encoded — happens when JS-side JSON.stringify result gets
        // re-stringified by the platform channel.
        decodedAny = jsonDecode(decodedAny);
      }
      final decoded = decodedAny as Map<String, dynamic>;
      dynamic proofAny = decoded['proof'];
      if (proofAny is String) proofAny = jsonDecode(proofAny);
      final proofMap = proofAny as Map<String, dynamic>;
      dynamic pubAny = decoded['publicSignals'];
      if (pubAny is String) pubAny = jsonDecode(pubAny);
      final pubList = (pubAny as List<dynamic>)
          .map((e) => BigInt.parse(e as String))
          .toList(growable: false);

      final proofBytes = _encodeGroth16Proof(proofMap);
      return ProofResult(proof: proofBytes, publicSignals: pubList);
    } on SnarkProverException {
      rethrow;
    } catch (e) {
      throw SnarkProverException(SnarkProverErrorKind.generic, 'fullProve: $e');
    } finally {
      try {
        rt.dispose();
      } catch (_) {
        /* swallow — runtime cleanup best-effort */
      }
    }
  }
}

// ---------------------------------------------------------------------------
// WebView / snarkjs binding (Android)
// ---------------------------------------------------------------------------

/// Android prover: runs snarkjs inside a HEADLESS system WebView
/// (Chromium/V8 — full BigInt + native WebAssembly). flutter_js's Android
/// QuickJS has no BigInt, so snarkjs.min.js can't parse there.
///
/// The WebView is never attached to the widget tree — no UI, nothing renders,
/// nothing pops up. It is created per-proof, runs `assets/snark/prover.html`,
/// and is disposed in `finally`. Same `ProofResult` shape as [_JsSnarkProver].
class _WebViewSnarkProver implements SnarkProver {
  static const String _proverAsset = 'assets/snark/prover.html';

  @override
  Future<ProofResult> generateProof({
    required Uint8List zkeyBytes,
    Uint8List? wasmBytes,
    Uint8List? witnessDatBytes,
    required Map<String, dynamic> input,
    required CancelToken cancel,
  }) async {
    if (zkeyBytes.isEmpty) {
      throw SnarkProverException(SnarkProverErrorKind.badZkey, 'zkeyBytes empty');
    }
    if (wasmBytes == null || wasmBytes.isEmpty) {
      throw SnarkProverException(
        SnarkProverErrorKind.badInput,
        'wasmBytes required',
      );
    }
    if (cancel.isCancelled) {
      throw SnarkProverException(SnarkProverErrorKind.cancelled, 'pre-call');
    }

    final loaded = Completer<void>();
    String? loadError;
    HeadlessInAppWebView? headless;
    try {
      headless = HeadlessInAppWebView(
        initialFile: _proverAsset,
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          // Allow the file-origin page to load its sibling snarkjs.min.js asset.
          allowFileAccessFromFileURLs: true,
          allowUniversalAccessFromFileURLs: true,
          transparentBackground: true,
        ),
        onLoadStop: (controller, url) {
          if (!loaded.isCompleted) loaded.complete();
        },
        onReceivedError: (controller, request, error) {
          loadError = '${error.type}: ${error.description}';
          if (!loaded.isCompleted) loaded.complete();
        },
      );
      await headless.run();
      await loaded.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw SnarkProverException(
          SnarkProverErrorKind.unavailable,
          'webview load timeout',
        ),
      );

      final controller = headless.webViewController;
      if (controller == null) {
        throw SnarkProverException(
          SnarkProverErrorKind.unavailable,
          'webview controller null${loadError != null ? ' ($loadError)' : ''}',
        );
      }

      // snarkjs must have parsed + self-attached before we prove.
      final ready = await controller.evaluateJavascript(
        source: 'window.sealedProverReady && window.sealedProverReady()',
      );
      if (ready != 'ok') {
        throw SnarkProverException(
          SnarkProverErrorKind.unavailable,
          'snarkjs not ready in webview: $ready'
          '${loadError != null ? ' ($loadError)' : ''}',
        );
      }

      if (cancel.isCancelled) {
        throw SnarkProverException(SnarkProverErrorKind.cancelled, 'pre-prove');
      }

      final inputJson = jsonEncode(_stringifyFr(input));
      final zkeyB64 = base64.encode(zkeyBytes);
      final wasmB64 = base64.encode(wasmBytes);

      final res = await controller.callAsyncJavaScript(
        functionBody:
            'return await window.sealedProve(inputJson, zkeyB64, wasmB64);',
        arguments: {
          'inputJson': inputJson,
          'zkeyB64': zkeyB64,
          'wasmB64': wasmB64,
        },
      );
      if (res == null) {
        throw SnarkProverException(
          SnarkProverErrorKind.generic,
          'callAsyncJavaScript returned null',
        );
      }
      if (res.error != null) {
        throw _jsErrorToException(res.error.toString());
      }
      if (cancel.isCancelled) {
        throw SnarkProverException(SnarkProverErrorKind.cancelled, 'post-prove');
      }

      // sealedProve returns a JSON string {proof, publicSignals}. The bridge
      // may hand it back as a String or (re)parsed — normalise either way.
      dynamic decodedAny = res.value;
      if (decodedAny is String) decodedAny = jsonDecode(decodedAny);
      if (decodedAny is String) decodedAny = jsonDecode(decodedAny);
      final decoded = (decodedAny as Map).cast<String, dynamic>();
      dynamic proofAny = decoded['proof'];
      if (proofAny is String) proofAny = jsonDecode(proofAny);
      final proofMap = (proofAny as Map).cast<String, dynamic>();
      dynamic pubAny = decoded['publicSignals'];
      if (pubAny is String) pubAny = jsonDecode(pubAny);
      final pubList = (pubAny as List)
          .map((e) => BigInt.parse(e as String))
          .toList(growable: false);

      final proofBytes = _encodeGroth16Proof(proofMap);
      return ProofResult(proof: proofBytes, publicSignals: pubList);
    } on SnarkProverException {
      rethrow;
    } catch (e) {
      throw SnarkProverException(
        SnarkProverErrorKind.generic,
        'webview fullProve: $e',
      );
    } finally {
      try {
        await headless?.dispose();
      } catch (_) {
        /* best-effort cleanup */
      }
    }
  }
}

/// `snarkjs.groth16.fullProve` returns:
///   { pi_a: [x,y,'1'], pi_b: [[x0,x1],[y0,y1],['1','0']], pi_c: [x,y,'1'],
///     protocol: 'groth16', curve: 'bn128' }
/// All values are decimal strings in Fq. The on-chain verifier expects
/// `A.x|A.y | B.x0|B.x1|B.y0|B.y1 | C.x|C.y`, each as 32B big-endian.
/// Matches `proofBytes()` in redeem_with_proof.test.ts.
Uint8List _encodeGroth16Proof(Map<String, dynamic> p) {
  final out = Uint8List(256);
  final a = (p['pi_a'] as List).cast<dynamic>();
  final b = (p['pi_b'] as List).cast<dynamic>();
  final c = (p['pi_c'] as List).cast<dynamic>();

  _writeFqBE32(out, 0, a[0] as String);
  _writeFqBE32(out, 32, a[1] as String);

  final b0 = (b[0] as List).cast<dynamic>();
  final b1 = (b[1] as List).cast<dynamic>();
  _writeFqBE32(out, 64, b0[0] as String);
  _writeFqBE32(out, 96, b0[1] as String);
  _writeFqBE32(out, 128, b1[0] as String);
  _writeFqBE32(out, 160, b1[1] as String);

  _writeFqBE32(out, 192, c[0] as String);
  _writeFqBE32(out, 224, c[1] as String);
  return out;
}

void _writeFqBE32(Uint8List out, int offset, String decimal) {
  var v = BigInt.parse(decimal);
  for (var i = 31; i >= 0; i--) {
    out[offset + i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
}

/// Convert any non-string scalar in the input map into a decimal string —
/// snarkjs/ffjavascript wants string-encoded field elements once they
/// exceed JS-safe int range. Lists are recursed.
dynamic _stringifyFr(dynamic v) {
  if (v is BigInt) return v.toString();
  if (v is int) return v.toString();
  if (v is String) return v;
  if (v is List) return [for (final e in v) _stringifyFr(e)];
  if (v is Map) {
    return {
      for (final entry in v.entries) entry.key: _stringifyFr(entry.value),
    };
  }
  return v;
}

JsEvalResult _eval(JavascriptRuntime rt, String src, String tag) {
  final r = rt.evaluate(src, sourceUrl: tag);
  if (r.isError) {
    throw SnarkProverException(
      SnarkProverErrorKind.generic,
      '$tag: ${r.stringResult}',
    );
  }
  return r;
}

SnarkProverException _jsErrorToException(String msg) {
  final lower = msg.toLowerCase();
  if (lower.contains('out of memory') || lower.contains('oom')) {
    return SnarkProverException(SnarkProverErrorKind.oom, msg);
  }
  if (lower.contains('zkey') || lower.contains('proving key')) {
    return SnarkProverException(SnarkProverErrorKind.badZkey, msg);
  }
  if (lower.contains('witness') || lower.contains('wasm')) {
    return SnarkProverException(SnarkProverErrorKind.witness, msg);
  }
  if (lower.contains('assert') || lower.contains('input')) {
    return SnarkProverException(SnarkProverErrorKind.badInput, msg);
  }
  return SnarkProverException(SnarkProverErrorKind.generic, msg);
}
