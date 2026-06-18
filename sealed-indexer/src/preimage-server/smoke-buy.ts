/**
 * End-to-end smoke buy for monetization-v1 — the reference buyer flow.
 *
 * This is the canonical client the LP frontend mirrors.
 *
 *   MIRROR THIS (the load-bearing logic): the 2-txn group shape, the box
 *   references (incl. `appIndex: 0` for own-app boxes), the delivery-key =
 *   sha256(pub) derivation, and the HPKE open of the wire bytes.
 *
 *   DO NOT MIRROR (admin-only shortcuts): this tool talks to algod and the
 *   /delivery endpoint DIRECTLY. The LP is privacy-critical (LP-INTEGRATION.md
 *   §4.5) — it MUST route algod + /delivery through its own OHTTP-relayed Next
 *   route handlers, never direct fetch/algod from the browser. It also signs
 *   with a connected wallet (Pera / Defly / Lute via use-wallet) instead of a
 *   mnemonic, and generates the delivery keypair in-browser.
 *
 * Flow (matches LP-INTEGRATION.md §4.3):
 *   1. Read app globals: price, poolHead, poolTail.
 *   2. Read the `p:<head+i>` pool boxes to learn the commitment hashes being
 *      bought (needed to attach the `c:<hash>` box refs).
 *   3. Generate an X25519 delivery keypair.
 *   4. Build [Pay(buyer→app, qty×price), AppCall purchaseCodes(qty, pub)] with
 *      box refs [p:<head+i>, c:<hash_i>] for each code. Sign both, submit.
 *   5. Poll <DELIVERY_BASE_URL>/delivery/<sha256(pub) hex> until 200 or timeout.
 *   6. HPKE-open the ciphertext with the delivery privkey → print the codes.
 *
 * Prereqs for a *successful* run (else the buy strands inventory — see the
 * stranding warning in LP-INTEGRATION.md): the preimage-server must be running
 * with the bought commitments' preimages loaded (`npm run load-codes`), and
 * DELIVERY_BASE_URL must reach its `/delivery/:hex` (directly or via the
 * indexer proxy / OHTTP relay).
 *
 * Usage:
 *   ALGOD_URL=https://testnet-api.algonode.cloud \
 *   SEALED_APP_ID=763452863 \
 *   BUYER_MNEMONIC="word1 ... word25" \
 *   DELIVERY_BASE_URL=http://localhost:4100 \
 *   ts-node src/preimage-server/smoke-buy.ts --qty 1
 *
 * Flags:
 *   --qty <1..4>     codes to buy (contract caps at 4 per call). Default 1.
 *   --timeout <s>    delivery poll timeout seconds. Default 60.
 *   --no-deliver     submit the buy only; skip delivery poll (use when the
 *                    sidecar isn't up yet and you just want chain confirmation).
 *
 * SECURITY: the codes printed are real bearer secrets. Do not paste them into
 * any doc, log, or ticket. For the publishable §4.6 golden vector use
 * `gen-golden-vector.ts` (synthetic payload), never this tool's output.
 */

import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';

import algosdk from 'algosdk';

import { generateDeliveryKeypairForTest, openForDelivery } from './crypto';

function sha256(b: Uint8Array): Uint8Array {
  return new Uint8Array(createHash('sha256').update(b).digest());
}

const MAX_PURCHASE_QTY = 4; // mirrors the contract constant
const PURCHASE_METHOD = new algosdk.ABIMethod({
  name: 'purchaseCodes',
  args: [
    { type: 'uint64', name: 'qty' },
    { type: 'byte[32]', name: 'deliveryPubkey' },
  ],
  returns: { type: 'void' },
});

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

function boxName(prefix: string, body: Uint8Array): Uint8Array {
  const pre = new TextEncoder().encode(prefix);
  const out = new Uint8Array(pre.length + body.length);
  out.set(pre, 0);
  out.set(body, pre.length);
  return out;
}

interface Globals {
  price: bigint;
  poolHead: bigint;
  poolTail: bigint;
}

async function readGlobals(algod: algosdk.Algodv2, appId: bigint): Promise<Globals> {
  const info = await algod.getApplicationByID(appId).do();
  const gs = info.params.globalState ?? [];
  const read = (k: string): bigint => {
    for (const kv of gs) {
      const keyBytes = kv.key instanceof Uint8Array ? kv.key : Buffer.from(String(kv.key), 'base64');
      if (Buffer.from(keyBytes).toString('utf-8') === k) return BigInt(kv.value.uint ?? 0);
    }
    return 0n;
  };
  return { price: read('pr'), poolHead: read('ph'), poolTail: read('pt') };
}

async function readPoolHashes(
  algod: algosdk.Algodv2,
  appId: bigint,
  head: bigint,
  qty: number,
): Promise<Uint8Array[]> {
  const hashes: Uint8Array[] = [];
  for (let i = 0; i < qty; i++) {
    const name = boxName('p:', algosdk.encodeUint64(head + BigInt(i)));
    const box = await algod.getApplicationBoxByName(appId, name).do();
    if (box.value.length !== 32) {
      throw new Error(`pool box p:${head + BigInt(i)} has bad length ${box.value.length}`);
    }
    hashes.push(box.value);
  }
  return hashes;
}

async function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function pollDelivery(baseUrl: string, hex: string, timeoutSec: number): Promise<Uint8Array> {
  const url = `${baseUrl.replace(/\/$/, '')}/delivery/${hex}`;
  const deadline = Date.now() + timeoutSec * 1000;
  let lastStatus = 0;
  while (Date.now() < deadline) {
    const res = await fetch(url);
    lastStatus = res.status;
    if (res.status === 200) {
      return new Uint8Array(await res.arrayBuffer());
    }
    await sleep(2000);
  }
  throw new Error(`delivery poll timed out after ${timeoutSec}s (last status ${lastStatus}) — is the sidecar up + preimages loaded?`);
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const qty = Number.parseInt(args.qty ?? '1', 10);
  if (!(qty >= 1 && qty <= MAX_PURCHASE_QTY)) {
    throw new Error(`--qty must be 1..${MAX_PURCHASE_QTY} (contract cap)`);
  }
  const timeoutSec = Number.parseInt(args.timeout ?? '60', 10);
  const deliver = args['no-deliver'] !== 'true';

  const algodUrl = process.env.ALGOD_URL ?? 'https://testnet-api.algonode.cloud';
  const appId = BigInt(process.env.SEALED_APP_ID ?? '0');
  if (appId === 0n) throw new Error('SEALED_APP_ID not set');
  const buyerMnemonic = process.env.BUYER_MNEMONIC;
  if (!buyerMnemonic) throw new Error('BUYER_MNEMONIC not set');
  const deliveryBase = process.env.DELIVERY_BASE_URL ?? 'http://localhost:4100';

  const algod = new algosdk.Algodv2('', algodUrl, '');
  const buyer = algosdk.mnemonicToSecretKey(buyerMnemonic.trim());
  const appAddress = algosdk.getApplicationAddress(appId);

  const { price, poolHead, poolTail } = await readGlobals(algod, appId);
  console.log(`app=${appId} price=${price} µA poolHead=${poolHead} poolTail=${poolTail} buyer=${buyer.addr.toString()}`);
  if (poolTail - poolHead < BigInt(qty)) {
    throw new Error(`pool too shallow: size ${poolTail - poolHead}, need ${qty}`);
  }

  const hashes = await readPoolHashes(algod, appId, poolHead, qty);
  const total = price * BigInt(qty);

  const { publicKey: deliveryPub, privateKey: deliveryPriv } = await generateDeliveryKeypairForTest();
  const deliveryKeyHex = toHex(sha256(deliveryPub));

  // Persist the keypair BEFORE submitting. The buy stamps `soldAtRound`
  // on-chain irreversibly; if we lost the privkey (timeout, crash,
  // --no-deliver) the code would be undecryptable AND unrecoverable
  // (unseedSalePool refuses sold commitments). This file is the recovery key.
  const keyFile = `delivery-${deliveryKeyHex.slice(0, 12)}.json`;
  writeFileSync(
    keyFile,
    JSON.stringify(
      {
        deliveryPublicKeyHex: toHex(deliveryPub),
        deliveryPrivateKeyHex: toHex(deliveryPriv),
        deliveryKeySha256Hex: deliveryKeyHex,
      },
      null,
      2,
    ),
  );
  console.log(`delivery keypair saved to ${keyFile} (gitignored — required to decrypt; delete after success)`);

  // Box refs: every code needs its p:<idx> (read+delete) and c:<hash> (stamp).
  // 2×qty ≤ 8 — within the single-app-call box-ref budget that caps qty at 4.
  // appIndex 0 = "this app's own box" (version-independent; never needs the
  // app in a foreign-apps array). The LP must use the same convention.
  const boxes: algosdk.BoxReference[] = [];
  for (let i = 0; i < qty; i++) {
    boxes.push({ appIndex: 0, name: boxName('p:', algosdk.encodeUint64(poolHead + BigInt(i))) });
    boxes.push({ appIndex: 0, name: boxName('c:', hashes[i]) });
  }

  const sp = await algod.getTransactionParams().do();

  const payTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: buyer.addr,
    receiver: appAddress,
    amount: total,
    suggestedParams: { ...sp, fee: 1000n, flatFee: true },
  });

  const appArgs = [
    PURCHASE_METHOD.getSelector(),
    new algosdk.ABIUintType(64).encode(BigInt(qty)),
    deliveryPub, // byte[32] static array encodes as the raw 32 bytes
  ];
  const appCallTxn = algosdk.makeApplicationNoOpTxnFromObject({
    sender: buyer.addr,
    appIndex: appId,
    appArgs,
    boxes,
    // OpUp inner-appls are paid from the app account; outer call needs minFee.
    // Bump to 2×minFee for headroom against the box-ref-heavy program.
    suggestedParams: { ...sp, fee: 2000n, flatFee: true },
  });

  algosdk.assignGroupID([payTxn, appCallTxn]);
  const signed = [payTxn.signTxn(buyer.sk), appCallTxn.signTxn(buyer.sk)];

  console.log(`submitting purchaseCodes(qty=${qty}) — paying ${total} µA (${Number(total) / 1e6} ALGO)`);
  const { txid } = await algod.sendRawTransaction(signed).do();
  const confirmed = await algosdk.waitForConfirmation(algod, txid, 8);
  console.log(`confirmed in round ${confirmed.confirmedRound} txid=${txid}`);
  console.log(`bought commitments: ${hashes.map((h) => toHex(h).slice(0, 12) + '…').join(', ')}`);

  if (!deliver) {
    console.log(`\n--no-deliver: buy confirmed, delivery skipped.`);
    console.log(`  delivery key (sha256 of pub): ${deliveryKeyHex}`);
    console.log(`  privkey saved in ${keyFile} — decrypt later by fetching`);
    console.log(`  ${deliveryBase}/delivery/${deliveryKeyHex} and openForDelivery(wire, privkey).`);
    return;
  }

  console.log(`polling ${deliveryBase}/delivery/${deliveryKeyHex} …`);
  const wire = await pollDelivery(deliveryBase, deliveryKeyHex, timeoutSec);
  const payload = await openForDelivery(wire, deliveryPriv);

  console.log(`\n✅ delivered + decrypted. purchasedAtRound=${payload.purchasedAtRound}`);
  console.log('CODES (bearer secrets — do not share/log/paste):');
  for (const c of payload.codes) console.log(`  ${c}`);
  console.log('\nChain → delivery → decrypt all verified. LP can integrate against this.');
}

main().catch((err: unknown) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
