import 'dart:convert';

import 'package:blockchain_utils/bip/address/algo_addr.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:messagepack/messagepack.dart';
import 'package:sealed_app/chain/algorand_wallet_client.dart';
import 'package:sealed_app/chain/chain_client.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/services/key_service.dart';

/// Algorand implementation of [ChainClient].
///
/// Uses direct REST calls to AlgoNode's public algod + indexer endpoints.
/// Transactions are built in the standard Algorand msgpack format and signed
/// with the wallet's Ed25519 key via [AlgorandWallet].
class AlgorandChainClient implements ChainClient {
  final Dio _dio;
  final AlgorandWallet _wallet;
  final KeyService? _keyService;

  /// Pre-computed SHA-256("global:send_message")[0..8] discriminator.
  static final Uint8List _sendMessageDiscriminator = Uint8List.fromList([
    0x39,
    0x28,
    0x22,
    0xb2,
    0xbd,
    0x0a,
    0x41,
    0x1a,
  ]);

  // ---------------------------------------------------------------------------
  // SealedMessage AppCall ABI method selectors (first 4 bytes of sha512/256
  // over the canonical ABI signature). These match the compiled TEAL at
  // programs/sealed_message/sealed_message_approval.teal.
  // ---------------------------------------------------------------------------

  /// sha512/256("send_message(byte[32],byte[])void")[0..4]
  static final Uint8List sendMessageSelector = Uint8List.fromList([
    0x2e,
    0x70,
    0xc3,
    0x11,
  ]);

  /// sha512/256("send_alias_message(byte[32],byte[32],byte[])void")[0..4]
  static final Uint8List sendAliasMessageSelector = Uint8List.fromList([
    0x89,
    0x40,
    0xd4,
    0x87,
  ]);

  /// sha512/256("set_username(byte[],byte[32],byte[32])void")[0..4]
  static final Uint8List setUsernameSelector = Uint8List.fromList([
    0xd2,
    0xfc,
    0xc8,
    0x3f,
  ]);

  /// sha512/256("publish_pq_key(byte[])void")[0..4]
  static final Uint8List publishPqKeySelector = Uint8List.fromList([
    0xb6,
    0xd4,
    0x97,
    0xa8,
  ]);

  /// ABI `byte[]` (dynamic bytes) encoding: 2-byte big-endian length prefix
  /// followed by the raw bytes.
  static Uint8List encodeAbiDynamicBytes(Uint8List data) {
    final out = Uint8List(2 + data.length);
    out[0] = (data.length >> 8) & 0xff;
    out[1] = data.length & 0xff;
    out.setRange(2, 2 + data.length, data);
    return out;
  }

  /// Test-only wrapper around [_buildAppCallTx]. Not intended for production
  /// callers — used by the Phase B.1 unit tests to assert msgpack shape
  /// without exercising the network.
  @visibleForTesting
  static Map<String, dynamic> debugBuildAppCallTx({
    required Uint8List senderPubkey,
    required int appId,
    required Uint8List methodSelector,
    required List<Uint8List> appArgs,
    required int fee,
    required int firstValid,
    required int lastValid,
    required String genesisId,
    required Uint8List genesisHash,
    Uint8List? note,
  }) {
    return _buildAppCallTxStatic(
      senderPubkey: senderPubkey,
      appId: appId,
      methodSelector: methodSelector,
      appArgs: appArgs,
      fee: fee,
      firstValid: firstValid,
      lastValid: lastValid,
      genesisId: genesisId,
      genesisHash: genesisHash,
      note: note,
    );
  }

  static Map<String, dynamic> _buildAppCallTxStatic({
    required Uint8List senderPubkey,
    required int appId,
    required Uint8List methodSelector,
    required List<Uint8List> appArgs,
    required int fee,
    required int firstValid,
    required int lastValid,
    required String genesisId,
    required Uint8List genesisHash,
    Uint8List? note,
  }) {
    final effectiveFee = fee < ALGO_TX_FEE ? ALGO_TX_FEE : fee;

    // apaa is the full application args array: [selector, arg0, arg1, ...]
    final apaa = <Uint8List>[methodSelector, ...appArgs];

    final fields = <String, dynamic>{
      'apid': appId,
      'apaa': apaa,
      'fee': effectiveFee,
      'fv': firstValid,
      'gen': genesisId,
      'gh': genesisHash,
      'lv': lastValid,
      'snd': senderPubkey,
      'type': 'appl',
    };

    if (note != null && note.isNotEmpty) fields['note'] = note;

    return fields;
  }

  AlgorandChainClient({
    required AlgorandWallet wallet,
    required KeyService keyService,
    Dio? dio,
  }) : _wallet = wallet,
       _keyService = keyService,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 30),
               responseType: ResponseType.json,
               headers: {'Accept': 'application/json'},
             ),
           );

  /// Lightweight constructor for payment-only flows (e.g. the in-app faucet).
  /// Skips KeyService since it is only used by message-encryption code paths,
  /// not by [sendPayment] / [getWalletBalance] / [waitForConfirmation].
  AlgorandChainClient.paymentOnly({required AlgorandWallet wallet, Dio? dio})
    : _wallet = wallet,
      _keyService = null,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              responseType: ResponseType.json,
              headers: {'Accept': 'application/json'},
            ),
          );

  @override
  String get chainId => 'algorand';

  @override
  String? get activeWalletAddress => _wallet.walletAddress;

  // ===========================================================================
  // ChainClient interface
  // ===========================================================================

  @override
  Future<int> getWalletBalance(String walletAddress) async {
    try {
      final resp = await _dio.get('$ALGO_ALGOD_URL/v2/accounts/$walletAddress');
      final data = resp.data is String
          ? jsonDecode(resp.data as String) as Map<String, dynamic>
          : resp.data as Map<String, dynamic>;
      final amount = (data['amount'] as num?)?.toInt() ?? 0;
      return amount;
    } catch (e, st) {
      print(
        '⚠️ AlgorandChainClient.getWalletBalance failed for '
        '$walletAddress: $e',
      );
      print(st);
      return 0;
    }
  }

  @override
  Future<String> sendMessage({
    required Uint8List recipientTag,
    required Uint8List ciphertext,
    required Uint8List senderEncryptionPubkey,
    required String recipientWallet,
  }) async {
    _assertWalletLoaded();

    if (USE_APPCALL_FOR_MESSAGES) {
      // Route through the SealedMessage smart contract so the event-stream
      // subscriber can filter on apid. recipient_tag is a first-class ABI arg
      // (byte[32], no length prefix); ciphertext is byte[] (length-prefixed).
      //
      // Wire format for ciphertext arg: [senderEphemeralPubkey(32) || ciphertext].
      // The contract treats ciphertext as opaque bytes and emits Log(ciphertext),
      // so receivers can recover the ephemeral pubkey on-chain (the AppCall ABI
      // does not carry it as a separate arg). Receivers split the first 32 bytes
      // back off before AEAD decapsulation.
      assert(recipientTag.length == 32);
      assert(senderEncryptionPubkey.length == 32);
      final framedCiphertext =
          Uint8List(senderEncryptionPubkey.length + ciphertext.length)
            ..setRange(0, 32, senderEncryptionPubkey)
            ..setRange(32, 32 + ciphertext.length, ciphertext);
      return _submitAppCall(
        methodSelector: sendMessageSelector,
        appArgs: [recipientTag, encodeAbiDynamicBytes(framedCiphertext)],
      );
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final note = _buildSendMessageNote(
      recipientTag,
      ciphertext,
      senderEncryptionPubkey,
      timestamp,
    );

    return sendRawNote(recipientWallet: recipientWallet, note: note);
  }

  @override
  Future<String> setUsernameViaMemo({required String username}) async {
    _assertWalletLoaded();

    final keys = await _keyService!.loadKeys();
    if (keys == null) throw StateError('Keys not loaded');

    if (USE_APPCALL_FOR_MESSAGES) {
      // set_username(byte[] username, byte[32] encryption_pubkey,
      //              byte[32] scan_pubkey) void
      final usernameBytes = Uint8List.fromList(utf8.encode(username));
      final encPubkey = base64Decode(keys.encryptionPubkeyBase64);
      final scanPubkey = base64Decode(keys.scanPubkeyBase64);
      assert(encPubkey.length == 32);
      assert(scanPubkey.length == 32);
      return _submitAppCall(
        methodSelector: setUsernameSelector,
        appArgs: [encodeAbiDynamicBytes(usernameBytes), encPubkey, scanPubkey],
      );
    }

    final memoText =
        'SEALED_USERNAME:v1:$username:${keys.encryptionPubkeyBase64}:${keys.scanPubkeyBase64}';
    final note = Uint8List.fromList(utf8.encode(memoText));

    return sendRawNote(recipientWallet: _wallet.walletAddress!, note: note);
  }

  @override
  Future<String> publishPqPublicKey(Uint8List pqPubkey) async {
    _assertWalletLoaded();

    if (USE_APPCALL_FOR_MESSAGES) {
      // publish_pq_key(byte[] pq_pubkey) void
      return _submitAppCall(
        methodSelector: publishPqKeySelector,
        appArgs: [encodeAbiDynamicBytes(pqPubkey)],
      );
    }

    // Format: "SEALED_PQ:v1:" prefix + raw PQ pubkey (800 bytes) = 813 bytes ≤ 1024
    final prefix = utf8.encode('SEALED_PQ:v1:');
    final note = Uint8List.fromList([...prefix, ...pqPubkey]);
    return sendRawNote(recipientWallet: _wallet.walletAddress!, note: note);
  }

  @override
  Future<String?> fetchLatestUsernameForWallet(String walletAddress) async {
    // Query the public Algorand indexer for application-call transactions
    // sent by this wallet to SEALED_MESSAGE_APP_ID. We then scan from newest
    // to oldest for one whose first app-arg matches `setUsernameSelector`,
    // and decode the second arg as ABI dynamic bytes (utf8 username).
    try {
      final resp = await _dio.get(
        '$ALGO_INDEXER_URL/v2/accounts/$walletAddress/transactions',
        queryParameters: {
          'application-id': SEALED_MESSAGE_APP_ID,
          'tx-type': 'appl',
          'limit': 50,
        },
      );

      final txList = (resp.data['transactions'] as List?) ?? const [];
      // Indexer returns newest-first by default, but be defensive: sort by
      // round-time descending so we always pick the most recent claim.
      final sorted = txList.whereType<Map<String, dynamic>>().toList()
        ..sort((a, b) {
          final ta = (a['round-time'] as int?) ?? 0;
          final tb = (b['round-time'] as int?) ?? 0;
          return tb.compareTo(ta);
        });

      final selectorB64 = base64Encode(setUsernameSelector);
      for (final tx in sorted) {
        final appTx = tx['application-transaction'] as Map<String, dynamic>?;
        if (appTx == null) continue;
        final args = (appTx['application-args'] as List?) ?? const [];
        if (args.isEmpty) continue;
        if (args[0] != selectorB64) continue;
        if (args.length < 2) continue;

        try {
          final usernameArgBytes = base64Decode(args[1] as String);
          // ABI dynamic bytes = 2-byte big-endian length + payload.
          if (usernameArgBytes.length < 2) continue;
          final len = (usernameArgBytes[0] << 8) | usernameArgBytes[1];
          if (usernameArgBytes.length < 2 + len) continue;
          final usernameBytes = usernameArgBytes.sublist(2, 2 + len);
          return utf8.decode(usernameBytes);
        } catch (_) {
          continue;
        }
      }
      // App-call scan found nothing — fall back to legacy memo-note format
      // ("SEALED_USERNAME:v1:<username>:..."). Pre-USE_APPCALL_FOR_MESSAGES
      // claims live as payment-tx notes, not application calls.
      return await _findUsernameByWalletMemo(walletAddress);
    } catch (e) {
      print('[AlgorandChainClient] fetchLatestUsernameForWallet error: $e');
      return null;
    }
  }

  /// Legacy memo-note scan: find the most recent
  /// `SEALED_USERNAME:v1:<username>:...` note sent by [walletAddress] and
  /// return the embedded username. Returns null if none found.
  Future<String?> _findUsernameByWalletMemo(String walletAddress) async {
    try {
      const prefix = 'SEALED_USERNAME:v1:';
      final notePrefixB64 = base64Url
          .encode(utf8.encode(prefix))
          .replaceAll('=', '');
      final resp = await _dio.get(
        '$ALGO_INDEXER_URL/v2/accounts/$walletAddress/transactions',
        queryParameters: {'note-prefix': notePrefixB64, 'limit': 50},
        options: Options(
          receiveTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 15),
        ),
      );
      final txList = (resp.data['transactions'] as List?) ?? const [];
      final sorted = txList.whereType<Map<String, dynamic>>().toList()
        ..sort((a, b) {
          final ta = (a['round-time'] as int?) ?? 0;
          final tb = (b['round-time'] as int?) ?? 0;
          return tb.compareTo(ta);
        });
      for (final tx in sorted) {
        final noteB64 = tx['note'] as String?;
        if (noteB64 == null) continue;
        try {
          final noteBytes = base64Decode(noteB64);
          final noteText = utf8.decode(noteBytes, allowMalformed: true);
          if (!noteText.startsWith(prefix)) continue;
          // Format: SEALED_USERNAME:v1:<username>:<encB64>:<scanB64>
          final parts = noteText.split(':');
          if (parts.length < 3) continue;
          final username = parts[2];
          if (username.isNotEmpty) return username;
        } catch (_) {
          continue;
        }
      }
      return null;
    } catch (e) {
      print('[AlgorandChainClient] _findUsernameByWalletMemo error: $e');
      return null;
    }
  }

  @override
  Future<String?> fetchWalletForUsername(String username) async {
    // Inverse of fetchLatestUsernameForWallet: scan recent set_username app
    // calls on SEALED_MESSAGE_APP_ID and return the sender wallet of the
    // first match (newest first). The Algorand public indexer cannot filter
    // by application-arg content, so we paginate and decode locally.
    final query = username.trim();
    if (query.isEmpty) return null;
    final wantBytes = utf8.encode(query);

    // Path 1 — legacy memo format ("SEALED_USERNAME:v1:<username>:..."):
    // use the indexer's note-prefix filter for an exact, server-side match.
    // This catches usernames published before USE_APPCALL_FOR_MESSAGES rolled
    // out, which the app-call scan below would never see.
    final memoMatch = await _findWalletByUsernameMemo(query);
    if (memoMatch != null) return memoMatch;

    // Path 2 — current app-call format. Scan recent set_username app calls
    // and decode args[1] as ABI dynamic bytes. Note: the indexer's nested
    // path /v2/applications/{id}/transactions returns 404 on algonode; the
    // working filter is /v2/transactions?application-id=<id>.
    try {
      final resp = await _dio.get(
        '$ALGO_INDEXER_URL/v2/transactions',
        queryParameters: {
          'application-id': SEALED_MESSAGE_APP_ID,
          'tx-type': 'appl',
          'limit': 200,
        },
        options: Options(
          receiveTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 15),
        ),
      );
      final txList = (resp.data['transactions'] as List?) ?? const [];
      final sorted = txList.whereType<Map<String, dynamic>>().toList()
        ..sort((a, b) {
          final ta = (a['round-time'] as int?) ?? 0;
          final tb = (b['round-time'] as int?) ?? 0;
          return tb.compareTo(ta);
        });
      final selectorB64 = base64Encode(setUsernameSelector);
      for (final tx in sorted) {
        final appTx = tx['application-transaction'] as Map<String, dynamic>?;
        if (appTx == null) continue;
        final args = (appTx['application-args'] as List?) ?? const [];
        if (args.length < 2) continue;
        if (args[0] != selectorB64) continue;
        try {
          final usernameArgBytes = base64Decode(args[1] as String);
          if (usernameArgBytes.length < 2) continue;
          final len = (usernameArgBytes[0] << 8) | usernameArgBytes[1];
          if (usernameArgBytes.length < 2 + len) continue;
          final usernameBytes = usernameArgBytes.sublist(2, 2 + len);
          if (usernameBytes.length != wantBytes.length) continue;
          var equal = true;
          for (var i = 0; i < usernameBytes.length; i++) {
            if (usernameBytes[i] != wantBytes[i]) {
              equal = false;
              break;
            }
          }
          if (!equal) continue;
          final sender = tx['sender'] as String?;
          if (sender != null && sender.isNotEmpty) return sender;
        } catch (_) {
          continue;
        }
      }
      return null;
    } catch (e) {
      print('[AlgorandChainClient] fetchWalletForUsername error: $e');
      return null;
    }
  }

  /// Look up a wallet by scanning legacy `SEALED_USERNAME:v1:<username>:...`
  /// memo notes. Uses the Algorand indexer's `note-prefix` parameter so the
  /// filter happens server-side. Returns the most recent matching tx sender.
  Future<String?> _findWalletByUsernameMemo(String username) async {
    try {
      final prefix = 'SEALED_USERNAME:v1:$username:';
      final notePrefixB64 = base64Url
          .encode(utf8.encode(prefix))
          .replaceAll('=', '');
      final resp = await _dio.get(
        '$ALGO_INDEXER_URL/v2/transactions',
        queryParameters: {'note-prefix': notePrefixB64, 'limit': 50},
        options: Options(
          receiveTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 15),
        ),
      );
      final txList = (resp.data['transactions'] as List?) ?? const [];
      final sorted = txList.whereType<Map<String, dynamic>>().toList()
        ..sort((a, b) {
          final ta = (a['round-time'] as int?) ?? 0;
          final tb = (b['round-time'] as int?) ?? 0;
          return tb.compareTo(ta);
        });
      for (final tx in sorted) {
        // Defensive: re-verify the note actually starts with our prefix
        // (note-prefix is a server-side hint, not a strict equality).
        final noteB64 = tx['note'] as String?;
        if (noteB64 == null) continue;
        try {
          final noteBytes = base64Decode(noteB64);
          final noteText = utf8.decode(noteBytes, allowMalformed: true);
          if (!noteText.startsWith('SEALED_USERNAME:v1:$username:')) continue;
        } catch (_) {
          continue;
        }
        final sender = tx['sender'] as String?;
        if (sender != null && sender.isNotEmpty) return sender;
      }
      return null;
    } catch (e) {
      print('[AlgorandChainClient] _findWalletByUsernameMemo error: $e');
      return null;
    }
  }

  /// Build, sign, and submit a SealedMessage AppCall. Returns the txId.
  /// Used by sendMessage / setUsernameViaMemo / publishPqPublicKey
  /// when [USE_APPCALL_FOR_MESSAGES] is true.
  Future<String> _submitAppCall({
    required Uint8List methodSelector,
    required List<Uint8List> appArgs,
  }) async {
    final params = await _getSuggestedParams();
    final senderPubkey = _decodeAddress(_wallet.walletAddress!);

    final txFields = _buildAppCallTx(
      senderPubkey: senderPubkey,
      appId: SEALED_MESSAGE_APP_ID,
      methodSelector: methodSelector,
      appArgs: appArgs,
      fee: params.fee,
      firstValid: params.firstValid,
      lastValid: params.lastValid,
      genesisId: params.genesisId,
      genesisHash: params.genesisHash,
    );

    final msgpackForSigning = _encodeTxForSigning(txFields);
    final signature = await _wallet.signTransactionBytes(msgpackForSigning);
    final signedTxBytes = _encodeSignedTx(txFields, signature);

    return _submitTransaction(signedTxBytes);
  }

  @override
  Future<String> sendRawNote({
    required String recipientWallet,
    required Uint8List note,
  }) async {
    _assertWalletLoaded();

    final params = await _getSuggestedParams();
    final senderPubkey = _decodeAddress(_wallet.walletAddress!);
    final receiverPubkey = _decodeAddress(recipientWallet);

    final txFields = _buildTxFields(
      senderPubkey: senderPubkey,
      receiverPubkey: receiverPubkey,
      fee: params.fee,
      firstValid: params.firstValid,
      lastValid: params.lastValid,
      genesisId: params.genesisId,
      genesisHash: params.genesisHash,
      note: note,
    );

    final msgpackForSigning = _encodeTxForSigning(txFields);
    final signature = await _wallet.signTransactionBytes(msgpackForSigning);
    final signedTxBytes = _encodeSignedTx(txFields, signature);

    return _submitTransaction(signedTxBytes);
  }

  /// Send a payment transaction with a non-zero ALGO amount (in microALGOs).
  /// Used by the in-app faucet to send 1 ALGO to a user's wallet.
  Future<String> sendPayment({
    required String recipientWallet,
    required int microAlgos,
    Uint8List? note,
  }) async {
    _assertWalletLoaded();

    final params = await _getSuggestedParams();
    final senderPubkey = _decodeAddress(_wallet.walletAddress!);
    final receiverPubkey = _decodeAddress(recipientWallet);

    final txFields = _buildTxFields(
      senderPubkey: senderPubkey,
      receiverPubkey: receiverPubkey,
      fee: params.fee,
      firstValid: params.firstValid,
      lastValid: params.lastValid,
      genesisId: params.genesisId,
      genesisHash: params.genesisHash,
      note: note ?? Uint8List(0),
      amount: microAlgos,
    );

    final msgpackForSigning = _encodeTxForSigning(txFields);
    final signature = await _wallet.signTransactionBytes(msgpackForSigning);
    final signedTxBytes = _encodeSignedTx(txFields, signature);

    return _submitTransaction(signedTxBytes);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRawNotes({
    int? sinceTimestamp,
    int limit = 200,
  }) async {
    if (_wallet.walletAddress == null) return [];

    try {
      final queryParams = <String, dynamic>{'limit': limit};
      if (sinceTimestamp != null && sinceTimestamp > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(
          sinceTimestamp * 1000,
          isUtc: true,
        );
        queryParams['after-time'] = dt.toIso8601String();
      }

      final resp = await _dio.get(
        '$ALGO_INDEXER_URL/v2/accounts/${_wallet.walletAddress}/transactions',
        queryParameters: queryParams,
      );

      final txList = resp.data['transactions'] as List? ?? [];
      final results = <Map<String, dynamic>>[];

      for (final tx in txList) {
        final txMap = tx as Map<String, dynamic>;
        final noteB64 = txMap['note'] as String?;
        if (noteB64 == null) continue;
        try {
          final noteBytes = base64Decode(noteB64);
          final txId = txMap['id'] as String? ?? '';
          final senderAddr = (txMap['sender'] as String?) ?? '';
          final roundTime = txMap['round-time'] as int? ?? 0;
          results.add({
            'noteBytes': noteBytes,
            'senderAddress': senderAddr,
            'txId': txId,
            'timestamp': roundTime,
          });
        } catch (_) {
          continue;
        }
      }

      return results;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> waitForConfirmation(
    String txId, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final resp = await _dio.get(
          '$ALGO_ALGOD_URL/v2/transactions/pending/$txId',
        );
        final confirmedRound = resp.data['confirmed-round'] as int?;
        if (confirmedRound != null && confirmedRound > 0) return;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 1500));
    }
    throw Exception('Transaction $txId not confirmed within $timeout');
  }

  @override
  Future<Map<String, dynamic>?> getMessageByAccount(String txId) async {
    try {
      final resp = await _dio.get('$ALGO_INDEXER_URL/v2/transactions/$txId');
      final tx = resp.data['transaction'] as Map<String, dynamic>?;
      if (tx == null) return null;
      final noteB64 = tx['note'] as String?;
      if (noteB64 == null) return null;
      final noteBytes = base64Decode(noteB64);
      final parsed = _parseMemoData(noteBytes, txId);
      if (parsed == null) return null;
      parsed['senderAddress'] = (tx['sender'] as String?) ?? '';
      return parsed;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRecentMemoMessages({
    int? sinceTimestamp,
    int limit = 200,
  }) async {
    if (_wallet.walletAddress == null) return [];

    if (USE_APPCALL_FOR_MESSAGES) {
      return _fetchAppCallMessagesForAddress(
        _wallet.walletAddress!,
        sinceTimestamp: sinceTimestamp,
        limit: limit,
      );
    }

    try {
      final queryParams = <String, dynamic>{'limit': limit};
      if (sinceTimestamp != null && sinceTimestamp > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(
          sinceTimestamp * 1000,
          isUtc: true,
        );
        queryParams['after-time'] = dt.toIso8601String();
      }

      final resp = await _dio.get(
        '$ALGO_INDEXER_URL/v2/accounts/${_wallet.walletAddress}/transactions',
        queryParameters: queryParams,
      );

      final txList = resp.data['transactions'] as List? ?? [];
      final messages = <Map<String, dynamic>>[];

      for (final tx in txList) {
        final txMap = tx as Map<String, dynamic>;
        final noteB64 = txMap['note'] as String?;
        if (noteB64 == null) continue;
        final txId = txMap['id'] as String? ?? '';
        try {
          final noteBytes = base64Decode(noteB64);
          final parsed = _parseMemoData(noteBytes, txId);
          if (parsed != null) {
            parsed['senderAddress'] = (txMap['sender'] as String?) ?? '';
            messages.add(parsed);
          }
        } catch (_) {
          continue;
        }
      }

      messages.sort(
        (a, b) => (b['timestamp'] as int).compareTo(a['timestamp'] as int),
      );
      return messages;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchMemoMessagesForAddress(
    String address, {
    int? sinceTimestamp,
    int limit = 200,
  }) async {
    if (USE_APPCALL_FOR_MESSAGES) {
      return _fetchAppCallMessagesForAddress(
        address,
        sinceTimestamp: sinceTimestamp,
        limit: limit,
      );
    }

    try {
      final queryParams = <String, dynamic>{'limit': limit};
      if (sinceTimestamp != null && sinceTimestamp > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(
          sinceTimestamp * 1000,
          isUtc: true,
        );
        queryParams['after-time'] = dt.toIso8601String();
      }

      final resp = await _dio.get(
        '$ALGO_INDEXER_URL/v2/accounts/$address/transactions',
        queryParameters: queryParams,
      );

      final txList = resp.data['transactions'] as List? ?? [];
      final messages = <Map<String, dynamic>>[];

      for (final tx in txList) {
        final txMap = tx as Map<String, dynamic>;
        final noteB64 = txMap['note'] as String?;
        if (noteB64 == null) continue;
        final txId = txMap['id'] as String? ?? '';
        try {
          final noteBytes = base64Decode(noteB64);
          final parsed = _parseMemoData(noteBytes, txId);
          if (parsed != null) {
            parsed['senderAddress'] = (txMap['sender'] as String?) ?? '';
            messages.add(parsed);
          }
        } catch (_) {
          continue;
        }
      }

      messages.sort(
        (a, b) => (b['timestamp'] as int).compareTo(a['timestamp'] as int),
      );
      return messages;
    } catch (_) {
      return [];
    }
  }

  // ===========================================================================
  // Binary note format helpers
  // ===========================================================================

  /// Build the same binary layout as Solana memo messages.
  Uint8List _buildSendMessageNote(
    Uint8List recipientTag,
    Uint8List ciphertext,
    Uint8List senderEncryptionPubkey,
    int timestampSeconds,
  ) {
    assert(recipientTag.length == 32);
    assert(senderEncryptionPubkey.length == 32);

    final totalSize = 8 + 32 + 4 + ciphertext.length + 32 + 8;
    final result = Uint8List(totalSize);
    final view = ByteData.view(result.buffer);
    int offset = 0;

    result.setRange(offset, offset + 8, _sendMessageDiscriminator);
    offset += 8;

    result.setRange(offset, offset + 32, recipientTag);
    offset += 32;

    view.setUint32(offset, ciphertext.length, Endian.little);
    offset += 4;
    result.setRange(offset, offset + ciphertext.length, ciphertext);
    offset += ciphertext.length;

    result.setRange(offset, offset + 32, senderEncryptionPubkey);
    offset += 32;

    view.setInt64(offset, timestampSeconds, Endian.little);

    return result;
  }

  /// Parse a raw note blob into a message map, or return null if invalid.
  Map<String, dynamic>? _parseMemoData(Uint8List data, String txId) {
    // Minimum length: 8 (disc) + 32 (tag) + 4 (len) + 0 (ct) + 32 (pubkey) + 8 (ts) = 84
    if (data.length < 84) return null;

    // Check discriminator
    for (int i = 0; i < 8; i++) {
      if (data[i] != _sendMessageDiscriminator[i]) return null;
    }

    final view = ByteData.view(data.buffer, data.offsetInBytes);
    int offset = 8;

    final recipientTag = Uint8List.fromList(data.sublist(offset, offset + 32));
    offset += 32;

    final ciphertextLen = view.getUint32(offset, Endian.little);
    offset += 4;

    if (offset + ciphertextLen + 32 + 8 > data.length) return null;

    final ciphertext = Uint8List.fromList(
      data.sublist(offset, offset + ciphertextLen),
    );
    offset += ciphertextLen;

    final senderEncPubkey = Uint8List.fromList(
      data.sublist(offset, offset + 32),
    );
    offset += 32;

    final timestamp = view.getInt64(offset, Endian.little);

    return {
      'accountPubkey': txId,
      'recipient_tag': recipientTag,
      'ciphertext': ciphertext,
      'sender_encryption_pubkey': senderEncPubkey,
      'timestamp': timestamp,
    };
  }

  /// Fetch recent SealedMessage AppCall transactions for [address] and parse
  /// each into the same map shape as [_parseMemoData], so existing sync code
  /// (incoming + outgoing) works unchanged.
  ///
  /// Wire format of `application-args[1]` (after base64 + ABI dynamic-bytes
  /// length-prefix strip): `[senderEphemeralPubkey(32) || ciphertext]`.
  ///
  /// Query the GLOBAL transactions endpoint filtered by application-id rather
  /// than `/v2/accounts/{addr}/transactions`. AppCall recipients are not
  /// participants on-chain (only the sender signs/pays), so the address-scoped
  /// endpoint returns nothing for the receiver. The recipient is identified
  /// later via `recipient_tag` checks in MessageService.
  Future<List<Map<String, dynamic>>> _fetchAppCallMessagesForAddress(
    String address, {
    int? sinceTimestamp,
    int limit = 200,
  }) async {
    try {
      final queryParams = <String, dynamic>{
        'application-id': SEALED_MESSAGE_APP_ID,
        'tx-type': 'appl',
        'limit': limit,
      };
      if (sinceTimestamp != null && sinceTimestamp > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(
          sinceTimestamp * 1000,
          isUtc: true,
        );
        queryParams['after-time'] = dt.toIso8601String();
      }

      final resp = await _dio.get(
        '$ALGO_INDEXER_URL/v2/transactions',
        queryParameters: queryParams,
      );

      final txList = (resp.data['transactions'] as List?) ?? const [];
      final selectorB64 = base64Encode(sendMessageSelector);
      final messages = <Map<String, dynamic>>[];

      for (final tx in txList.whereType<Map<String, dynamic>>()) {
        final appTx = tx['application-transaction'] as Map<String, dynamic>?;
        if (appTx == null) continue;
        final args = (appTx['application-args'] as List?) ?? const [];
        if (args.length < 3) continue;
        if (args[0] != selectorB64) continue;

        try {
          final recipientTag = base64Decode(args[1] as String);
          if (recipientTag.length != 32) continue;

          // ABI dynamic bytes: 2-byte big-endian length prefix + payload.
          final framedArg = base64Decode(args[2] as String);
          if (framedArg.length < 2) continue;
          final payloadLen = (framedArg[0] << 8) | framedArg[1];
          if (framedArg.length < 2 + payloadLen) continue;
          final framed = framedArg.sublist(2, 2 + payloadLen);
          // Wire layout: [senderEphemeralPubkey(32) || ciphertext]
          if (framed.length < 32) continue;
          final senderEncPubkey = Uint8List.fromList(framed.sublist(0, 32));
          final ciphertext = Uint8List.fromList(framed.sublist(32));

          final timestamp = (tx['round-time'] as int?) ?? 0;
          final txId = (tx['id'] as String?) ?? '';

          messages.add({
            'accountPubkey': txId,
            'recipient_tag': Uint8List.fromList(recipientTag),
            'ciphertext': ciphertext,
            'sender_encryption_pubkey': senderEncPubkey,
            'timestamp': timestamp,
            'senderAddress': (tx['sender'] as String?) ?? '',
          });
        } catch (_) {
          continue;
        }
      }

      messages.sort(
        (a, b) => (b['timestamp'] as int).compareTo(a['timestamp'] as int),
      );
      return messages;
    } catch (_) {
      return [];
    }
  }

  // ===========================================================================
  // Algorand transaction building (msgpack)
  // ===========================================================================

  /// Get suggested transaction parameters from algod.
  Future<_AlgoParams> _getSuggestedParams() async {
    final resp = await _dio.get('$ALGO_ALGOD_URL/v2/transactions/params');
    final data = resp.data as Map<String, dynamic>;
    return _AlgoParams(
      fee: (data['fee'] as int?) ?? ALGO_TX_FEE,
      firstValid: data['last-round'] as int,
      lastValid: (data['last-round'] as int) + 1000,
      genesisId: data['genesis-id'] as String,
      genesisHash: base64Decode(data['genesis-hash'] as String),
      minFee: (data['min-fee'] as int?) ?? ALGO_TX_FEE,
    );
  }

  /// Decode an Algorand address to its raw 32-byte public key.
  Uint8List _decodeAddress(String address) {
    return Uint8List.fromList(AlgoAddrDecoder().decodeAddr(address));
  }

  /// Build the transaction fields map (keys in canonical alphabetical order).
  Map<String, dynamic> _buildTxFields({
    required Uint8List senderPubkey,
    required Uint8List receiverPubkey,
    required int fee,
    required int firstValid,
    required int lastValid,
    required String genesisId,
    required Uint8List genesisHash,
    Uint8List? note,
    int amount = 0,
  }) {
    // Make sure fee is at least the minimum
    final effectiveFee = fee < ALGO_TX_FEE ? ALGO_TX_FEE : fee;

    final fields = <String, dynamic>{
      'fee': effectiveFee,
      'fv': firstValid,
      'gen': genesisId,
      'gh': genesisHash,
      'lv': lastValid,
      'rcv': receiverPubkey,
      'snd': senderPubkey,
      'type': 'pay',
    };

    if (amount > 0) fields['amt'] = amount;
    if (note != null && note.isNotEmpty) fields['note'] = note;

    return fields;
  }

  /// Build an Application Call transaction targeting [appId] with the given
  /// [methodSelector] and [appArgs]. The selector is prepended to `apaa`
  /// automatically — pass only the ABI-encoded arguments after it.
  ///
  /// OnCompletion defaults to NoOp (apan=0, stripped by canonical encoding).
  Map<String, dynamic> _buildAppCallTx({
    required Uint8List senderPubkey,
    required int appId,
    required Uint8List methodSelector,
    required List<Uint8List> appArgs,
    required int fee,
    required int firstValid,
    required int lastValid,
    required String genesisId,
    required Uint8List genesisHash,
    Uint8List? note,
  }) {
    return _buildAppCallTxStatic(
      senderPubkey: senderPubkey,
      appId: appId,
      methodSelector: methodSelector,
      appArgs: appArgs,
      fee: fee,
      firstValid: firstValid,
      lastValid: lastValid,
      genesisId: genesisId,
      genesisHash: genesisHash,
      note: note,
    );
  }

  /// Encode transaction fields to msgpack with "TX" prefix for signing.
  Uint8List _encodeTxForSigning(Map<String, dynamic> fields) {
    final txPrefix = utf8.encode('TX');
    final p = Packer();
    _writeMapFields(p, fields);
    final txMsgpack = p.takeBytes();
    return Uint8List.fromList([...txPrefix, ...txMsgpack]);
  }

  /// Encode the signed transaction ({"sig": ..., "txn": ...}) to msgpack.
  Uint8List _encodeSignedTx(Map<String, dynamic> txFields, Uint8List sig) {
    // "sig" sorts before "txn" alphabetically — correct canonical order
    final p = Packer();
    p.packMapLength(2);
    p.packString('sig');
    p.packBinary(sig);
    p.packString('txn');
    _writeMapFields(p, txFields);
    return p.takeBytes();
  }

  /// Write a sorted map to a [Packer], filtering out zero/empty values.
  /// Algorand's canonical encoding omits ALL zero-value fields (including
  /// apan=0 NoOp, amt=0, etc.). Only non-zero values are serialized.
  void _writeMapFields(Packer p, Map<String, dynamic> fields) {
    final sortedKeys = fields.keys.toList()..sort();
    final validKeys = sortedKeys.where((k) {
      final v = fields[k];
      if (v == null) return false;
      if (v is int && v == 0) return false;
      if (v is String && v.isEmpty) return false;
      if (v is List && v.isEmpty) return false;
      return true;
    }).toList();

    p.packMapLength(validKeys.length);
    for (final key in validKeys) {
      p.packString(key);
      final v = fields[key];
      if (v is int) {
        p.packInt(v);
      } else if (v is String) {
        p.packString(v);
      } else if (v is Uint8List) {
        p.packBinary(v);
      } else if (v is List<Uint8List>) {
        // Application args (apaa): array of byte arrays
        p.packListLength(v.length);
        for (final item in v) {
          p.packBinary(item);
        }
      } else if (v is List<Map<String, dynamic>>) {
        // Box references (apbx): array of {i: int, n: bytes} maps
        // Must NOT filter zero ints — i=0 means "this app's own boxes"
        p.packListLength(v.length);
        for (final item in v) {
          _writeBoxRef(p, item);
        }
      } else if (v is List<int>) {
        p.packBinary(Uint8List.fromList(v));
      }
    }
  }

  /// Write a box reference map.
  /// Canonical Algorand encoding omits 'i' when it's 0 (this app's own boxes).
  void _writeBoxRef(Packer p, Map<String, dynamic> ref) {
    // Filter zero-int values (i=0 must be omitted in canonical encoding)
    final sortedKeys = ref.keys.toList()..sort();
    final validKeys = sortedKeys.where((k) {
      final v = ref[k];
      if (v == null) return false;
      if (v is int && v == 0) return false;
      return true;
    }).toList();
    p.packMapLength(validKeys.length);
    for (final key in validKeys) {
      p.packString(key);
      final v = ref[key];
      if (v is int) {
        p.packInt(v);
      } else if (v is Uint8List) {
        p.packBinary(v);
      }
    }
  }

  // ===========================================================================
  // Algod submission
  // ===========================================================================

  Future<String> _submitTransaction(Uint8List signedTxBytes) async {
    debugPrint(
      '[ALIAS-DEBUG] _submitTransaction: sending ${signedTxBytes.length} bytes to $ALGO_ALGOD_URL/v2/transactions',
    );
    try {
      final resp = await _dio.post(
        '$ALGO_ALGOD_URL/v2/transactions',
        data: signedTxBytes,
        options: Options(
          contentType: 'application/x-binary',
          headers: {'Accept': 'application/json'},
        ),
      );
      debugPrint(
        '[ALIAS-DEBUG] _submitTransaction SUCCESS: txId=${resp.data['txId']}',
      );
      return resp.data['txId'] as String;
    } on DioException catch (e) {
      debugPrint(
        '[ALIAS-DEBUG] _submitTransaction FAILED: status=${e.response?.statusCode}',
      );
      debugPrint(
        '[ALIAS-DEBUG] _submitTransaction response body: ${e.response?.data}',
      );
      debugPrint(
        '[ALIAS-DEBUG] _submitTransaction request URL: ${e.requestOptions.uri}',
      );
      rethrow;
    }
  }

  // ===========================================================================
  // Utilities
  // ===========================================================================

  void _assertWalletLoaded() {
    if (_wallet.walletAddress == null) throw StateError('Wallet not loaded');
  }

  bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}

/// Algorand suggested transaction parameters.
class _AlgoParams {
  final int fee;
  final int firstValid;
  final int lastValid;
  final String genesisId;
  final Uint8List genesisHash;
  final int minFee;

  const _AlgoParams({
    required this.fee,
    required this.firstValid,
    required this.lastValid,
    required this.genesisId,
    required this.genesisHash,
    required this.minFee,
  });
}
