/**
 * Generate a publishable HPKE golden vector for LP-INTEGRATION.md §4.6.
 *
 * The LP author pastes this into a unit test on their side; if their
 * `decryptDelivery` cannot open this wire, their construction has drifted from
 * the sidecar (wrong suite, info string, version byte, or wire layout) and
 * they would be unable to decrypt anything a real sale produces.
 *
 * The payload is SYNTHETIC — a fake code string. This vector is safe to commit
 * and publish precisely because it is NOT a real sold code. NEVER build a
 * golden vector from `smoke-buy.ts` output; those are bearer secrets.
 *
 * It seals with `sealForDelivery` (the exact sidecar path) and immediately
 * re-opens with `openForDelivery` to self-verify the roundtrip before printing.
 *
 * Usage:
 *   ts-node src/preimage-server/gen-golden-vector.ts
 *   ts-node src/preimage-server/gen-golden-vector.ts --code 0123-4567-89AB-CDEF --round 1000
 */

import { generateDeliveryKeypairForTest, openForDelivery, sealForDelivery } from './crypto';

function parseArgs(argv: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const k = a.slice(2);
    const next = argv[i + 1];
    out[k] = next && !next.startsWith('--') ? argv[++i] : 'true';
  }
  return out;
}

function toHex(b: Uint8Array): string {
  return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const code = args.code && args.code !== 'true' ? args.code : '0123-4567-89AB-CDEF';
  const round = BigInt(args.round && args.round !== 'true' ? args.round : '1000');

  const { publicKey, privateKey } = await generateDeliveryKeypairForTest();
  const payload = { codes: [code], purchasedAtRound: round };
  const wire = await sealForDelivery(payload, publicKey);

  // Self-verify before publishing — a vector that doesn't open is worse than none.
  const reopened = await openForDelivery(wire, privateKey);
  if (reopened.codes[0] !== code || reopened.purchasedAtRound !== round) {
    throw new Error('self-verify failed — refusing to emit a broken vector');
  }

  const vector = {
    note: 'SYNTHETIC payload — safe to publish. Suite: DHKEM(X25519,HKDF-SHA256)/HKDF-SHA256/ChaCha20Poly1305. info="sealed.codes.v1". version byte 0x01. aad empty.',
    deliveryPublicKeyHex: toHex(publicKey),
    deliveryPrivateKeyHex: toHex(privateKey),
    wireHex: toHex(wire),
    expectedPlaintext: { codes: [code], purchasedAtRound: round.toString() },
  };

  console.log(JSON.stringify(vector, null, 2));
}

main().catch((err: unknown) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
