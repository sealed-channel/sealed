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

// Algorand MainNet (testnet values kept below for revert)
const ALGO_ALGOD_URL = 'https://mainnet-api.algonode.cloud';
const ALGO_ALGOD_TOKEN = ''; // AlgoNode is public, no token
const ALGO_INDEXER_URL = 'https://mainnet-idx.algonode.cloud';
// TESTNET: 'https://testnet-api.algonode.cloud' / 'https://testnet-idx.algonode.cloud'
const ALGO_MIN_BALANCE = 100000; // 0.1 ALGO in microAlgos
const ALGO_TX_FEE = 1000; // 0.001 ALGO min fee

// Active chain selection
const PRIMARY_CHAIN = 'algorand';

const SEALED_APP_ID = 3604741332; // mainnet (testnet: 764688742)

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
const OHTTP_TARGET_RPC_URL = 'https://mainnet-api.4160.nodely.dev'; // testnet: testnet-api.4160.nodely.dev
// Target indexer server reachable through the same OHTTP gateway. Used by
// the OhttpInterceptor to rewrite Algorand public-indexer requests
// (testnet-idx.algonode.cloud) so they flow through the great-apple relay
// alongside algod traffic.
const OHTTP_TARGET_INDEXER_URL = 'https://mainnet-idx.4160.nodely.dev'; // testnet: testnet-idx.4160.nodely.dev

// Indexer base URL — reached via the OHTTP gateway on the Hetzner VPS, fronted
// by Caddy at gw.sealed.channel. The relay (oblivious.network) sees ciphertext +
// client IP; the gateway sees plaintext request but not client IP. Overridable
// via --dart-define for smoke tests against another gateway (e.g. the Pi).
const INDEXER_BASE_URL = String.fromEnvironment(
  'INDEXER_BASE_URL',
  defaultValue: 'https://gw.sealed.channel',
);

// Indexer OHTTP channel — distinct from the Algorand OHTTP channel above.
// Cloudflare app-gateway-go on the VPS; relay slug alter-ball-33 is pinned to
// gw.sealed.channel/gateway by Oblivious.Network. Do NOT reuse the Algonode
// gateway/relay constants — that gateway pins to Nodely upstreams and would
// route indexer requests to the wrong target.
//
// The PQ-hybrid config endpoint (`/.well-known/ohttp-gateway`) advertises
// KEM_X25519_KYBER768_DRAFT00 (0xc901), which our HPKE encapsulator does
// NOT support. We use the LEGACY config endpoint (`/ohttp-configs`)
// served by the same gateway binary — it advertises KEM_X25519 (0x0020),
// matching `OhttpEncapsulator`. Switch back to the PQ endpoint once the
// encapsulator gains Kyber768 support.
const PI_OHTTP_GATEWAY_CONFIG_URL = String.fromEnvironment(
  'PI_OHTTP_GATEWAY_CONFIG_URL',
  defaultValue: 'https://gw.sealed.channel/ohttp-configs',
);
const PI_OHTTP_RELAY_URL = String.fromEnvironment(
  'PI_OHTTP_RELAY_URL',
  defaultValue: 'https://relay.oblivious.network/alter-ball-33',
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

/// Sealed website top-up page, opened in the external browser.
const String SEALED_TOPUP_URL = 'https://sealed.channel/top-up';
