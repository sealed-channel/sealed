import 'package:flutter/material.dart';

const MAX_MESSAGE_SIZE = 1024;
const MAX_MESSAGE_CHARS = 300;

double topPadding(BuildContext context) {
  final mediaQuery = MediaQuery.of(context);
  return mediaQuery.padding.top;
}

double bottomPadding(BuildContext context) {
  final mediaQuery = MediaQuery.of(context);
  return mediaQuery.padding.bottom;
}

const HORIZONTAL_PADDING = 18.0;

// Algorand TestNet
const ALGO_ALGOD_URL = 'https://testnet-api.algonode.cloud';
const ALGO_ALGOD_TOKEN = ''; // AlgoNode is public, no token
const ALGO_INDEXER_URL = 'https://testnet-idx.algonode.cloud';
const ALGO_MIN_BALANCE = 100000; // 0.1 ALGO in microAlgos
const ALGO_TX_FEE = 1000; // 0.001 ALGO min fee

// Active chain selection
const PRIMARY_CHAIN = 'algorand';

// Alias Channel AVM App ID (TestNet — update after deployment)
const ALIAS_CHANNEL_APP_ID = 761304750;

// SealedMessage AVM App ID (TestNet).
// Single discriminator for all default Sealed message traffic:
//   send_message, send_alias_message, set_username, publish_pq_key.
// An event-stream subscriber filters `txn.apid == SEALED_MESSAGE_APP_ID` to
// isolate Sealed traffic without parsing payload bytes.
const SEALED_MESSAGE_APP_ID = 761304827;

// Feature flag: route on-chain actions through SealedMessage AppCall instead
// of plain payment-tx-with-note. Fee is unchanged (0.001 ALGO). When false,
// the legacy payment-tx path is used (kept for migration-window rollback).
const USE_APPCALL_FOR_MESSAGES = true;

// Global wallet address that receives all alias chat transactions.
// This is a service-controlled address funded with minimum balance (0.1 ALGO).
// Set to your deployed global wallet address before going to production.
const ALIAS_GLOBAL_WALLET =
    'PEUKRNEW4PG7ONIZDCUR4PJARNI7PUIXNRNAQUQMI7MOTIYZZXOLNEOYEU';

// HMAC label strings for alias key-exchange tag derivation.
// The inviteSecret is the shared secret; these labels make invite/accept tags
// distinct from each other while keeping notes indistinguishable from regular
// message traffic on-chain.
const ALIAS_INVITE_TAG_LABEL = 'alias-invite-tag-v1';
const ALIAS_ACCEPT_TAG_LABEL = 'alias-accept-tag-v1';

// OHTTP (Oblivious HTTP) — Anonymous RPC routing
// Gateway publishes its HPKE public key config at this URL
const OHTTP_GATEWAY_CONFIG_URL = 'https://ohttp.nodely.io/ohttp-configs';
// Relay forwards encrypted requests without seeing content
const OHTTP_RELAY_URL = 'https://relay.oblivious.network/great-apple-60';
// Target RPC server (gateway proxies to this after decryption)
const OHTTP_TARGET_RPC_URL = 'https://testnet-api.4160.nodely.dev';
// Target indexer server reachable through the same OHTTP gateway. Used by
// the OhttpInterceptor to rewrite Algorand public-indexer requests
// (testnet-idx.algonode.cloud) so they flow through the great-apple relay
// alongside algod traffic.
const OHTTP_TARGET_INDEXER_URL = 'https://testnet-idx.4160.nodely.dev';

// Indexer base URL — reached via OHTTP gateway running on the operator's Pi,
// fronted by Tailscale Funnel. The relay (oblivious.network) sees ciphertext +
// client IP; the gateway sees plaintext request but not client IP.
const INDEXER_BASE_URL = 'https://sealed-pi.taile8602b.ts.net';

// Pi OHTTP channel — distinct from Algorand OHTTP channel above.
// Gateway runs Cloudflare privacy-gateway-server on the Pi; relay slug is
// pinned to this gateway by Oblivious.Network. Do NOT reuse the Algonode
// gateway/relay constants — that gateway pins to Nodely upstreams and
// would route indexer requests to the wrong target.
//
// The PQ-hybrid config endpoint (`/.well-known/ohttp-gateway`) advertises
// KEM_X25519_KYBER768_DRAFT00 (0xc901), which our HPKE encapsulator does
// NOT support. We use the LEGACY config endpoint (`/ohttp-configs`)
// served by the same gateway binary — it advertises KEM_X25519 (0x0020),
// matching `OhttpEncapsulator`. Switch back to the PQ endpoint once the
// encapsulator gains Kyber768 support.
const PI_OHTTP_GATEWAY_CONFIG_URL = String.fromEnvironment(
  'PI_OHTTP_GATEWAY_CONFIG_URL',
  defaultValue: 'https://sealed-pi.taile8602b.ts.net/ohttp-configs',
);
const PI_OHTTP_RELAY_URL = String.fromEnvironment(
  'PI_OHTTP_RELAY_URL',
  defaultValue: 'https://relay.oblivious.network/groovy-guide-67',
);
const PI_OHTTP_GATEWAY_REQUEST_PATH = '/gateway';

// =============================================================================
// INDEXER DEPRECATION CONFIGURATION
// =============================================================================

/// Legacy indexer deprecation flag. When true, shows migration warnings
/// and disables legacy indexer features in favor of blockchain-only sync.
/// Set to true to begin deprecation process.
const bool INDEXER_LEGACY_DEPRECATED = true;

/// End-of-life date for legacy indexer service (ISO 8601 format)
const String INDEXER_SUNSET_DATE = '2024-12-31';

/// URL for indexer migration documentation
const String INDEXER_MIGRATION_GUIDE_URL =
    'https://github.com/sealed-channel/sealed/blob/main/docs/INDEXER_MIGRATION.md';

const bool kDebugPollingFallback = false;
