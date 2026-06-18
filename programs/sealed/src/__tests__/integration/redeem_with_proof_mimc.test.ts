/**
 * On-chain MiMC Tornado redeem (`redeemWithProofMimc`, SPEC-onchain-mimc-tornado).
 *
 *   (a) valid proof → getCredits(sender)==500 + nb:<nullifier> exists
 *   (b) replay same proof → DOUBLE_SPEND
 *   (c) bogus rootRef never deposited → STALE_ROOT
 *   (d) wrong sender → BAD_RECIPIENT
 *   (e) tampered proof (splice another vector's on-curve C_G1) → BAD_PROOF
 *   (f) username co-claim → n:<sha256(name)> box written
 *
 * Each happy/adversarial test first DEPOSITs the vector's leaf so the on-chain
 * root == vector root and lands in the recent-roots ring, then redeems from a
 * FRESH, unlinked wallet (the vector's seeded sender) via the escrow group
 * [escrowSelfPay(fee), appCall(fee 0)] — exactly the legacy redeem harness.
 *
 * Vector ships the seeded ed25519 sender (`meta.senderSeedHex`) whose pubkey
 * mod Fr_MOD equals the proof's `recipient` public input.
 *
 * Requires `algokit localnet start`. Skips automatically if LocalNet is down.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import { AlgoAmount } from "@algorandfoundation/algokit-utils/types/amount";
import algosdk from "algosdk";
import { createHash, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import nacl from "tweetnacl";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { type LoadedEscrow } from "../../lib/escrow.js";
import { deploySealed, type DeployedSealed } from "./_deploy.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const ARC56_PATH = resolve(HERE, "..", "..", "..", "out", "Sealed.arc56.json");
const VECTORS_DIR = resolve(HERE, "..", "..", "..", "test", "snark-vectors");

const Q =
  21888242871839275222246405745257275088696311157297823662689037894645226208583n;
const PRICE = 10_000n;
const DENOM = 500n;

let algorand: AlgorandClient;
let dispenser: algosdk.Account;
let app: DeployedSealed;
let escrow: LoadedEscrow;
let localNetUp = false;

// ---------- proof / fr byte helpers (parity with verifier.test.ts) ----------
function feBytes32(decStr: string): Uint8Array {
  const n = BigInt(decStr);
  if (n < 0n || n >= Q) throw new Error(`fe out of range: ${decStr}`);
  const hex = n.toString(16).padStart(64, "0");
  return Buffer.from(hex, "hex");
}
function frBytes32(decStr: string): Uint8Array {
  const n = BigInt(decStr);
  const hex = n.toString(16).padStart(64, "0");
  return Buffer.from(hex, "hex");
}
const fr32 = frBytes32;
function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((s, p) => s + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}
interface VectorProof {
  pi_a: [string, string, string];
  pi_b: [[string, string], [string, string], [string, string]];
  pi_c: [string, string, string];
  protocol: string;
  curve: string;
}
function g1Bytes(pt: [string, string, string]): Uint8Array {
  return concat(feBytes32(pt[0]), feBytes32(pt[1]));
}
function g2Bytes(
  pt: [[string, string], [string, string], [string, string]],
): Uint8Array {
  return concat(
    feBytes32(pt[0][0]),
    feBytes32(pt[0][1]),
    feBytes32(pt[1][0]),
    feBytes32(pt[1][1]),
  );
}
function proofBytes(p: VectorProof): Uint8Array {
  return concat(g1Bytes(p.pi_a), g2Bytes(p.pi_b), g1Bytes(p.pi_c));
}

interface Vector {
  leaf: string;
  publicInputs: {
    root: string;
    nullifier: string;
    recipient: string;
    denomination: string;
  };
  proof: VectorProof;
  meta: { senderSeedHex: string; senderPubkeyHex: string };
}
function loadVector(name: string): Vector {
  return JSON.parse(
    readFileSync(resolve(VECTORS_DIR, name), "utf-8"),
  ) as Vector;
}
function senderFromVector(v: Vector): algosdk.Account {
  const seed = Buffer.from(v.meta.senderSeedHex, "hex");
  const kp = nacl.sign.keyPair.fromSeed(seed);
  return {
    addr: new algosdk.Address(kp.publicKey),
    sk: kp.secretKey, // 64B = seed || pubkey (nacl convention, algosdk-compatible)
  } as unknown as algosdk.Account;
}
function pubFromVector(v: Vector): Uint8Array {
  return concat(
    fr32(v.publicInputs.root),
    fr32(v.publicInputs.nullifier),
    fr32(v.publicInputs.recipient),
    fr32(v.publicInputs.denomination),
  );
}

function boxName(prefix: string): Uint8Array {
  return new TextEncoder().encode(prefix);
}

// ---------- deposit a vector's leaf so its root lands in the ring ----------
async function depositLeaf(leaf: Uint8Array): Promise<void> {
  const buyer = algosdk.generateAccount();
  await fundAccount(buyer.addr.toString(), 5_000_000n);

  const selector = new Uint8Array(
    algosdk.ABIMethod.fromSignature("deposit(byte[32])void").getSelector(),
  );
  const sp = await algorand.client.algod.getTransactionParams().do();
  const payTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: buyer.addr,
    receiver: app.appAddress,
    amount: Number(PRICE),
    suggestedParams: { ...sp, fee: 1000, flatFee: true },
  });
  const appCallTxn = algosdk.makeApplicationNoOpTxnFromObject({
    sender: buyer.addr,
    appIndex: Number(app.appId),
    appArgs: [selector, leaf],
    boxes: [
      { appIndex: Number(app.appId), name: boxName("mfs") },
      { appIndex: Number(app.appId), name: boxName("mqr") },
    ],
    suggestedParams: { ...sp, fee: 40_000, flatFee: true },
    note: new Uint8Array(randomBytes(8)),
  });
  algosdk.assignGroupID([payTxn, appCallTxn]);
  const signedPay = payTxn.signTxn(buyer.sk);
  const signedCall = appCallTxn.signTxn(buyer.sk);
  const { txid } = await algorand.client.algod
    .sendRawTransaction([signedPay, signedCall])
    .do();
  await algosdk.waitForConfirmation(algorand.client.algod, txid, 4);
}

// ---------- escrow redeem group [escrowSelfPay(fee), appCall(fee 0)] ----------
interface RedeemMimcParams {
  user: algosdk.Account;
  rootRef: Uint8Array; // 32B
  nullifier: Uint8Array; // 32B
  proof: Uint8Array; // 256B
  publicInputs: Uint8Array; // 128B
  username?: string;
}
async function redeemWithProofMimc(p: RedeemMimcParams): Promise<string> {
  const selector = new Uint8Array(
    algosdk.ABIMethod.fromSignature(
      "redeemWithProofMimc(byte[32],byte[32],byte[],byte[],byte[])void",
    ).getSelector(),
  );
  function encodeBytes(b: Uint8Array): Uint8Array {
    const out = new Uint8Array(2 + b.length);
    new DataView(out.buffer).setUint16(0, b.length, false);
    out.set(b, 2);
    return out;
  }

  const usernameBytes = p.username
    ? new TextEncoder().encode(p.username)
    : new Uint8Array();
  const userAddrBytes = p.user.addr.publicKey;

  const mqrKey = boxName("mqr");
  const nbBoxKey = new Uint8Array(3 + 32);
  nbBoxKey.set(new TextEncoder().encode("nb:"), 0);
  nbBoxKey.set(p.nullifier, 3);
  const wBoxKey = new Uint8Array(2 + 32);
  wBoxKey.set(new TextEncoder().encode("w:"), 0);
  wBoxKey.set(userAddrBytes, 2);

  const boxes: { appIndex: number; name: Uint8Array }[] = [
    { appIndex: Number(app.appId), name: mqrKey },
    { appIndex: Number(app.appId), name: nbBoxKey },
    { appIndex: Number(app.appId), name: wBoxKey },
  ];
  if (usernameBytes.length > 0) {
    const nameKey = new Uint8Array(2 + 32);
    nameKey.set(new TextEncoder().encode("n:"), 0);
    nameKey.set(
      new Uint8Array(createHash("sha256").update(usernameBytes).digest()),
      2,
    );
    boxes.push({ appIndex: Number(app.appId), name: nameKey });
  }

  const sp = await algorand.client.algod.getTransactionParams().do();
  const FEE_POOL = 250_000;
  const feeTxn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: escrow.address,
    receiver: escrow.address,
    amount: 0,
    suggestedParams: { ...sp, fee: FEE_POOL, flatFee: true },
  });
  const appCallTxn = algosdk.makeApplicationNoOpTxnFromObject({
    sender: p.user.addr,
    appIndex: Number(app.appId),
    appArgs: [
      selector,
      p.rootRef,
      p.nullifier,
      encodeBytes(p.proof),
      encodeBytes(p.publicInputs),
      encodeBytes(usernameBytes),
    ],
    boxes,
    suggestedParams: { ...sp, fee: 0, flatFee: true },
    note: new Uint8Array(randomBytes(8)),
  });

  algosdk.assignGroupID([feeTxn, appCallTxn]);
  const signedFee = algosdk.signLogicSigTransactionObject(
    feeTxn,
    escrow.account,
  ).blob;
  const signedCall = appCallTxn.signTxn(p.user.sk);
  const { txid } = await algorand.client.algod
    .sendRawTransaction([signedFee, signedCall])
    .do();
  await algosdk.waitForConfirmation(algorand.client.algod, txid, 4);
  return txid;
}

async function fundAccount(receiver: string, amount: bigint): Promise<void> {
  const sp = await algorand.client.algod.getTransactionParams().do();
  const txn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: dispenser.addr,
    receiver,
    amount: Number(amount),
    suggestedParams: sp,
  });
  const signed = txn.signTxn(dispenser.sk);
  const { txid } = await algorand.client.algod.sendRawTransaction(signed).do();
  await algosdk.waitForConfirmation(algorand.client.algod, txid, 4);
}

async function readBox(name: Uint8Array): Promise<Uint8Array | null> {
  try {
    const res = await algorand.client.algod
      .getApplicationBoxByName(Number(app.appId), name)
      .do();
    return new Uint8Array(res.value);
  } catch {
    return null;
  }
}

async function getCredits(user: algosdk.Account): Promise<bigint> {
  const appSpec = readFileSync(ARC56_PATH, "utf-8");
  algorand.setSignerFromAccount(app.admin);
  const client = algorand.client.getAppClientById({
    appSpec,
    appId: app.appId,
    defaultSender: app.admin.addr,
  });
  const wKey = new Uint8Array(2 + 32);
  wKey.set(new TextEncoder().encode("w:"), 0);
  wKey.set(user.addr.publicKey, 2);
  const res = await client.send.call({
    method: "getCredits(address)uint64",
    args: [user.addr.toString()],
    boxReferences: [wKey],
    sender: app.admin.addr,
    staticFee: AlgoAmount.MicroAlgo(2000n),
  });
  return BigInt(res.return as bigint);
}

async function initMimcTree(denomination: bigint): Promise<void> {
  const appSpec = readFileSync(ARC56_PATH, "utf-8");
  algorand.setSignerFromAccount(app.admin);
  const client = algorand.client.getAppClientById({
    appSpec,
    appId: app.appId,
    defaultSender: app.admin.addr,
  });
  await client.send.call({
    method: "initMimcTree(uint64)void",
    args: [denomination],
    boxReferences: [boxName("mfs"), boxName("mqr")],
    sender: app.admin.addr,
    staticFee: AlgoAmount.MicroAlgo(3000n),
    note: new Uint8Array(randomBytes(8)),
  });
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn("LocalNet not running — skipping redeemWithProofMimc tests.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
}, 60_000);

// Fresh app + fresh MiMC tree per test: each vector's root is a LEFTMOST
// (index-0, single-leaf) root, which only matches the on-chain root when the
// vector's leaf is the first and only deposit. A shared tree would advance the
// root on each deposit and the vector roots would no longer be in the ring.
beforeEach(async () => {
  if (!localNetUp) return;
  app = await deploySealed({
    algorand,
    dispenser,
    withEscrow: true,
    initialPrice: PRICE,
  });
  escrow = app.escrow!;
  await initMimcTree(DENOM);
}, 60_000);

describe("redeemWithProofMimc — happy + adversarial", () => {
  it("(a) valid proof grants 500 credits + writes nb:<nullifier>", async () => {
    if (!localNetUp) return;
    const v = loadVector("vector-01-basic.json");
    const user = senderFromVector(v);
    const rootBytes = fr32(v.publicInputs.root);
    const nullifierBytes = fr32(v.publicInputs.nullifier);

    await depositLeaf(frBytes32(v.leaf));
    await fundAccount(user.addr.toString(), 1_000_000n); // user signs (0-fee) appcall

    await redeemWithProofMimc({
      user,
      rootRef: rootBytes,
      nullifier: nullifierBytes,
      proof: proofBytes(v.proof),
      publicInputs: pubFromVector(v),
    });

    expect(await getCredits(user)).toBe(DENOM);

    const nbKey = new Uint8Array(3 + 32);
    nbKey.set(new TextEncoder().encode("nb:"), 0);
    nbKey.set(nullifierBytes, 3);
    expect(await readBox(nbKey)).not.toBeNull();
  }, 120_000);

  it("(b) replay same proof reverts DOUBLE_SPEND", async () => {
    if (!localNetUp) return;
    const v = loadVector("vector-02-deep.json");
    const user = senderFromVector(v);
    const rootBytes = fr32(v.publicInputs.root);
    const nullifierBytes = fr32(v.publicInputs.nullifier);

    await depositLeaf(frBytes32(v.leaf));
    await fundAccount(user.addr.toString(), 1_000_000n);

    await redeemWithProofMimc({
      user,
      rootRef: rootBytes,
      nullifier: nullifierBytes,
      proof: proofBytes(v.proof),
      publicInputs: pubFromVector(v),
    });
    await expect(
      redeemWithProofMimc({
        user,
        rootRef: rootBytes,
        nullifier: nullifierBytes,
        proof: proofBytes(v.proof),
        publicInputs: pubFromVector(v),
      }),
    ).rejects.toThrow(/DOUBLE_SPEND|assert/);
  }, 150_000);

  it("(c) bogus rootRef never deposited reverts STALE_ROOT", async () => {
    if (!localNetUp) return;
    const v = loadVector("vector-03-mid.json");
    const user = senderFromVector(v);
    await fundAccount(user.addr.toString(), 1_000_000n);

    // No deposit. Use a fresh random 32B root not in the ring.
    const bogus = new Uint8Array(randomBytes(32));
    const pub = concat(
      bogus,
      fr32(v.publicInputs.nullifier),
      fr32(v.publicInputs.recipient),
      fr32(v.publicInputs.denomination),
    );
    await expect(
      redeemWithProofMimc({
        user,
        rootRef: bogus,
        nullifier: fr32(v.publicInputs.nullifier),
        proof: proofBytes(v.proof),
        publicInputs: pub,
      }),
    ).rejects.toThrow(/STALE_ROOT|assert/);
  }, 90_000);

  it("(d) wrong sender reverts BAD_RECIPIENT", async () => {
    if (!localNetUp) return;
    const v = loadVector("vector-04-pow2.json");
    const rootBytes = fr32(v.publicInputs.root);

    await depositLeaf(frBytes32(v.leaf));
    const wrong = algosdk.generateAccount();
    await fundAccount(wrong.addr.toString(), 1_000_000n);

    await expect(
      redeemWithProofMimc({
        user: wrong,
        rootRef: rootBytes,
        nullifier: fr32(v.publicInputs.nullifier),
        proof: proofBytes(v.proof),
        publicInputs: pubFromVector(v),
      }),
    ).rejects.toThrow(/BAD_RECIPIENT|assert/);
  }, 120_000);

  it("(e) tampered proof reverts BAD_PROOF", async () => {
    if (!localNetUp) return;
    // vector-05 pub-inputs but vector-06's on-curve C_G1 spliced in.
    const v = loadVector("vector-05-odd.json");
    const v2 = loadVector("vector-06-far.json");
    const user = senderFromVector(v);
    const rootBytes = fr32(v.publicInputs.root);

    await depositLeaf(frBytes32(v.leaf));
    await fundAccount(user.addr.toString(), 1_000_000n);

    const goodProof = proofBytes(v.proof);
    const otherC = g1Bytes(v2.proof.pi_c); // 64B, on-curve
    const proof = new Uint8Array(256);
    proof.set(goodProof.subarray(0, 192), 0); // A_G1 + B_G2 from v
    proof.set(otherC, 192); // C_G1 from v2 — soundness break

    await expect(
      redeemWithProofMimc({
        user,
        rootRef: rootBytes,
        nullifier: fr32(v.publicInputs.nullifier),
        proof,
        publicInputs: pubFromVector(v),
      }),
    ).rejects.toThrow(/BAD_PROOF|assert/);
  }, 120_000);

  it("(f) username co-claim writes n:<sha256(name)>", async () => {
    if (!localNetUp) return;
    const v = loadVector("vector-07-edge0.json");
    const user = senderFromVector(v);
    const rootBytes = fr32(v.publicInputs.root);

    await depositLeaf(frBytes32(v.leaf));
    await fundAccount(user.addr.toString(), 1_000_000n);

    const username = "alice_mimc";
    await redeemWithProofMimc({
      user,
      rootRef: rootBytes,
      nullifier: fr32(v.publicInputs.nullifier),
      proof: proofBytes(v.proof),
      publicInputs: pubFromVector(v),
      username,
    });

    const nameKey = new Uint8Array(2 + 32);
    nameKey.set(new TextEncoder().encode("n:"), 0);
    nameKey.set(
      new Uint8Array(
        createHash("sha256")
          .update(new TextEncoder().encode(username))
          .digest(),
      ),
      2,
    );
    expect(await readBox(nameKey)).not.toBeNull();
  }, 120_000);
});
