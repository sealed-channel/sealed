#!/usr/bin/env -S npx ts-node
/* eslint-disable no-console */
/**
 * Direct APNs test sender — bypasses the indexer entirely.
 *
 * Sends a single visible-alert push to one device token using the SAME
 * .p8 / key id / team id / topic / host that the indexer uses, but
 * without OHTTP, without the chain watcher, without any registration
 * lookup. The point is to isolate whether the problem is "APNs config
 * is wrong" or "indexer logic is wrong".
 *
 * Usage:
 *   # 1. Grab the token printed by the iOS app (debug build):
 *   #    [AppDelegate] APNS_TOKEN_DEBUG=<64 hex chars>
 *   # 2. Run from the indexer repo root:
 *
 *   npx ts-node scripts/send_apns_test.ts <device-token-hex>
 *
 *   # Env (defaults match docker-compose.yml for sandbox):
 *   APNS_KEY_PATH=./apns_keys/dev.p8 \
 *   APNS_KEY_ID=ABCD123456 \
 *   APNS_TEAM_ID=U52YS2R8W2 \
 *   APNS_BUNDLE_ID=com.kamryy.sealed \
 *   APNS_HOST=api.sandbox.push.apple.com \
 *     npx ts-node scripts/send_apns_test.ts <token>
 *
 *   # For prod (TestFlight / App Store) flip to:
 *   APNS_KEY_PATH=./apns_keys/prod.p8 \
 *   APNS_HOST=api.push.apple.com \
 *     npx ts-node scripts/send_apns_test.ts <token>
 *
 * Exit codes:
 *   0   APNs accepted (HTTP 200)
 *   1   APNs rejected (4xx/5xx) — error reason printed
 *   2   Bad arguments / unreadable key
 */
import * as http2 from 'http2';
import * as fs from 'fs';
import * as path from 'path';
// eslint-disable-next-line @typescript-eslint/no-require-imports, @typescript-eslint/no-var-requires
const jwt = require('jsonwebtoken') as {
  sign: (
    payload: object,
    key: string,
    opts: { algorithm: string; header: { alg: string; kid: string } },
  ) => string;
};

function die(code: number, msg: string): never {
  console.error(`error: ${msg}`);
  process.exit(code);
}

const tokenArg = process.argv[2];
if (!tokenArg || !/^[0-9a-fA-F]+$/.test(tokenArg) || tokenArg.length !== 64) {
  die(
    2,
    'usage: send_apns_test.ts <64-hex-char-device-token>\n' +
      '  Token must be exactly 64 hex chars — what the iOS app prints as\n' +
      '  APNS_TOKEN_DEBUG in debug builds.',
  );
}
const deviceToken = tokenArg.toLowerCase();

const keyPath = process.env.APNS_KEY_PATH ?? path.resolve('./apns_keys/dev.p8');
const keyId = process.env.APNS_KEY_ID;
const teamId = process.env.APNS_TEAM_ID ?? 'U52YS2R8W2';
const topic = process.env.APNS_BUNDLE_ID ?? 'com.kamryy.sealed';
const apnsHost = process.env.APNS_HOST ?? 'api.sandbox.push.apple.com';

if (!keyId) die(2, 'APNS_KEY_ID env var required');

let privateKey: string;
try {
  privateKey = fs.readFileSync(keyPath, 'utf8');
} catch (err) {
  die(2, `cannot read APNS_KEY_PATH=${keyPath}: ${(err as Error).message}`);
}

console.log('=== APNs direct test ===');
console.log('host        :', apnsHost);
console.log('keyPath     :', keyPath);
console.log('keyId       :', keyId);
console.log('teamId      :', teamId);
console.log('topic       :', topic);
console.log('tokenPrefix :', deviceToken.slice(0, 8));
console.log();

// Sign provider JWT (ES256). Apple requires ≤60min TTL.
const now = Math.floor(Date.now() / 1000);
const providerJwt = jwt.sign(
  { iss: teamId, iat: now },
  privateKey,
  {
    algorithm: 'ES256',
    header: { alg: 'ES256', kid: keyId },
  },
);

const payload = Buffer.from(
  JSON.stringify({
    aps: {
      alert: { body: 'You got a new encrypted message' },
      sound: 'default',
    },
  }),
  'utf8',
);

const session = http2.connect(`https://${apnsHost}`);
session.on('error', (err) => {
  die(1, `http2 session error: ${err.message}`);
});

const req = session.request({
  ':method': 'POST',
  ':path': `/3/device/${deviceToken}`,
  'apns-push-type': 'alert',
  'apns-priority': '10',
  'apns-topic': topic,
  authorization: `bearer ${providerJwt}`,
  'content-type': 'application/json',
  'content-length': String(payload.length),
});

req.setTimeout(10_000, () => {
  console.error('timeout waiting for APNs');
  try { req.close(http2.constants.NGHTTP2_CANCEL); } catch { /* noop */ }
  session.close();
  process.exit(1);
});

let status = 0;
const chunks: Buffer[] = [];

req.on('response', (headers) => {
  const s = headers[':status'];
  if (typeof s === 'number') status = s;
  console.log('response status:', status);
  // apns-id header is useful when filing a support ticket with Apple.
  if (headers['apns-id']) console.log('apns-id        :', headers['apns-id']);
});
req.on('data', (c: Buffer) => chunks.push(c));
req.on('error', (err) => {
  console.error('stream error:', err.message);
  session.close();
  process.exit(1);
});
req.on('end', () => {
  const body = Buffer.concat(chunks).toString('utf8');
  if (body) console.log('response body  :', body);
  session.close();
  if (status >= 200 && status < 300) {
    console.log('✅ APNs accepted the push');
    process.exit(0);
  }
  // Common reasons documented at:
  // https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
  const hints: Record<string, string> = {
    BadDeviceToken:
      'Token is junk OR token belongs to the OTHER environment than APNS_HOST',
    BadEnvironmentKeyInToken:
      'Token vs APNS_HOST mismatch (sandbox token to prod host or vice versa)',
    Unregistered:
      'Token is no longer valid (app uninstalled / opted out). Re-register.',
    BadTopic:
      'apns-topic does not match the app bundle id / signing entitlements',
    InvalidProviderToken:
      'JWT key id, team id, or .p8 mismatch. Double-check APNS_KEY_ID matches the .p8 file.',
    ExpiredProviderToken:
      'Clock skew on the host running this script. Sync time and retry.',
    Forbidden:
      'Auth key revoked, or key belongs to a different team than APNS_TEAM_ID.',
  };
  try {
    const parsed = JSON.parse(body) as { reason?: string };
    if (parsed.reason && hints[parsed.reason]) {
      console.error('hint           :', hints[parsed.reason]);
    }
  } catch {
    /* body may be non-JSON for 5xx */
  }
  console.error('❌ APNs rejected the push');
  process.exit(1);
});

req.end(payload);
