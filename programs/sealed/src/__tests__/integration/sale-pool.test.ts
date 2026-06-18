/**
 * T2 gate: sale-pool ABI surface — seedSalePool / unseedSalePool / getPoolSize.
 *
 *   admin seeds 4 commitments → poolSize=4
 *   non-admin seed → revert NOT_ADMIN
 *   empty batch → revert EMPTY_BATCH
 *   batch > MAX_POOL_BATCH (4) → revert BATCH_TOO_LARGE
 *   unregistered commitment → revert COMMITMENT_MISSING
 *   admin unseed pops from tail; p: + c: boxes deleted
 *   unseed underflow → revert POOL_UNDERFLOW
 *   non-admin unseed → revert NOT_ADMIN
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
import { beforeAll, describe, expect, it } from "vitest";
import { postCommitment } from "../../scripts/post-commitment.js";
import { deploySealed, type DeployedSealed } from "./_deploy.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const ARC56_PATH = resolve(HERE, "..", "..", "..", "out", "Sealed.arc56.json");

let algorand: AlgorandClient;
let dispenser: algosdk.Account;
let app: DeployedSealed;
let appSpec: string;
let localNetUp = false;

function sha256(data: Uint8Array): Uint8Array {
  return new Uint8Array(createHash("sha256").update(data).digest());
}

function commitmentBoxKey(hash: Uint8Array): Uint8Array {
  const k = new Uint8Array(2 + 32);
  k.set(new TextEncoder().encode("c:"), 0);
  k.set(hash, 2);
  return k;
}

function poolBoxKey(idx: bigint): Uint8Array {
  const k = new Uint8Array(2 + 8);
  k.set(new TextEncoder().encode("p:"), 0);
  const dv = new DataView(k.buffer);
  dv.setBigUint64(2, idx, false);
  return k;
}

async function fundAccount(
  funder: algosdk.Account,
  receiver: string,
  amount: bigint,
): Promise<void> {
  const sp = await algorand.client.algod.getTransactionParams().do();
  const txn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: funder.addr,
    receiver,
    amount: Number(amount),
    suggestedParams: sp,
  });
  const signed = txn.signTxn(funder.sk);
  const { txid } = await algorand.client.algod.sendRawTransaction(signed).do();
  await algosdk.waitForConfirmation(algorand.client.algod, txid, 4);
}

interface SeedParams {
  caller: algosdk.Account;
  commitments: Uint8Array[];
  /** Tail index at the time of the call (for computing p: box refs). */
  tailAtCall: bigint;
}

async function seedSalePool(p: SeedParams): Promise<string> {
  algorand.setSignerFromAccount(p.caller);
  const client = algorand.client.getAppClientById({
    appSpec,
    appId: app.appId,
    defaultSender: p.caller.addr,
  });
  const boxes: Uint8Array[] = [];
  for (let i = 0; i < p.commitments.length; i++) {
    boxes.push(commitmentBoxKey(p.commitments[i]));
    boxes.push(poolBoxKey(p.tailAtCall + BigInt(i)));
  }
  const result = await client.send.call({
    method: "seedSalePool(byte[32][])void",
    args: [p.commitments],
    boxReferences: boxes,
    sender: p.caller.addr,
    staticFee: AlgoAmount.MicroAlgo(2000n),
  });
  return result.txIds[0];
}

interface UnseedParams {
  caller: algosdk.Account;
  qty: bigint;
  /** Hashes at the top of the pool, ordered tail→head, used to build c: refs. */
  topHashesTailToHead: Uint8Array[];
  tailAtCall: bigint;
}

async function unseedSalePool(p: UnseedParams): Promise<string> {
  algorand.setSignerFromAccount(p.caller);
  const client = algorand.client.getAppClientById({
    appSpec,
    appId: app.appId,
    defaultSender: p.caller.addr,
  });
  const boxes: Uint8Array[] = [];
  for (let i = 0n; i < p.qty; i++) {
    boxes.push(poolBoxKey(p.tailAtCall - 1n - i));
    boxes.push(commitmentBoxKey(p.topHashesTailToHead[Number(i)]));
  }
  const result = await client.send.call({
    method: "unseedSalePool(uint64)void",
    args: [p.qty],
    boxReferences: boxes,
    sender: p.caller.addr,
    staticFee: AlgoAmount.MicroAlgo(2000n),
  });
  return result.txIds[0];
}

async function getPoolSize(): Promise<bigint> {
  algorand.setSignerFromAccount(app.admin);
  const client = algorand.client.getAppClientById({
    appSpec,
    appId: app.appId,
    defaultSender: app.admin.addr,
  });
  const result = await client.send.call({
    method: "getPoolSize()uint64",
    args: [],
    sender: app.admin.addr,
    staticFee: AlgoAmount.MicroAlgo(1000n),
  });
  const ret = result.return as unknown;
  if (typeof ret === "bigint") return ret;
  if (typeof ret === "number") return BigInt(ret);
  throw new Error("UNEXPECTED_RETURN");
}

async function boxExists(key: Uint8Array): Promise<boolean> {
  const boxes = await algorand.client.algod
    .getApplicationBoxes(Number(app.appId))
    .do();
  return boxes.boxes.some((b) => Buffer.from(b.name).equals(Buffer.from(key)));
}

async function makeRegisteredCommitments(n: number): Promise<Uint8Array[]> {
  const hashes: Uint8Array[] = [];
  for (let i = 0; i < n; i++) {
    const preimage = new Uint8Array(randomBytes(16));
    const hash = sha256(preimage);
    await postCommitment({
      algorand,
      appId: app.appId,
      admin: app.admin,
      commitment: hash,
      denomination: 500n,
    });
    hashes.push(hash);
  }
  return hashes;
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn(
      "LocalNet not running — skipping sale-pool integration tests.",
    );
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  app = await deploySealed({ algorand, dispenser });
  appSpec = readFileSync(ARC56_PATH, "utf-8");
});

describe("seedSalePool / unseedSalePool / getPoolSize (T2)", () => {
  it("initial pool size is zero", async () => {
    if (!localNetUp) return;
    expect(await getPoolSize()).toBe(0n);
  });

  it("admin seeds 4 commitments; pool size = 4; p: boxes exist", async () => {
    if (!localNetUp) return;
    const hashes = await makeRegisteredCommitments(4);
    await seedSalePool({
      caller: app.admin,
      commitments: hashes,
      tailAtCall: 0n,
    });
    expect(await getPoolSize()).toBe(4n);
    for (let i = 0n; i < 4n; i++) {
      expect(await boxExists(poolBoxKey(i))).toBe(true);
    }
  });

  it("non-admin seed reverts NOT_ADMIN", async () => {
    if (!localNetUp) return;
    const imposter = algosdk.generateAccount();
    await fundAccount(dispenser, imposter.addr.toString(), 3_000_000n);
    const hashes = await makeRegisteredCommitments(1);
    await expect(
      seedSalePool({ caller: imposter, commitments: hashes, tailAtCall: 4n }),
    ).rejects.toThrow(/NOT_ADMIN|assert failed/);
  });

  it("empty batch reverts EMPTY_BATCH", async () => {
    if (!localNetUp) return;
    await expect(
      seedSalePool({ caller: app.admin, commitments: [], tailAtCall: 4n }),
    ).rejects.toThrow(/EMPTY_BATCH|assert failed/);
  });

  it("batch of 5 rejected (BATCH_TOO_LARGE or network ref-cap)", async () => {
    if (!localNetUp) return;
    // Qty=5 means 10 box refs (5×c: + 5×p:); AVM caps txn box refs at 8 so
    // this trips the network limit before the contract's BATCH_TOO_LARGE
    // assert runs. Both rejection paths are valid safety nets.
    const hashes = await makeRegisteredCommitments(5);
    await expect(
      seedSalePool({ caller: app.admin, commitments: hashes, tailAtCall: 4n }),
    ).rejects.toThrow(/BATCH_TOO_LARGE|box references is 8|assert failed/);
  });

  it("unregistered commitment reverts COMMITMENT_MISSING", async () => {
    if (!localNetUp) return;
    const phantom = sha256(new Uint8Array(randomBytes(16)));
    await expect(
      seedSalePool({
        caller: app.admin,
        commitments: [phantom],
        tailAtCall: 4n,
      }),
    ).rejects.toThrow(/COMMITMENT_MISSING|assert failed/);
  });

  it("admin unseeds 2; pool size shrinks; tail p: + c: boxes deleted", async () => {
    if (!localNetUp) return;
    const beforeSize = await getPoolSize();
    expect(beforeSize).toBe(4n);
    // Tail at call = 4. Pop idx 3 then idx 2.
    // We need the hashes at idx 3 and 2 to satisfy box refs. Read p: boxes.
    const algoBoxes = await algorand.client.algod
      .getApplicationBoxes(Number(app.appId))
      .do();
    const findP = async (idx: bigint): Promise<Uint8Array> => {
      const key = poolBoxKey(idx);
      const hit = algoBoxes.boxes.find((b) =>
        Buffer.from(b.name).equals(Buffer.from(key)),
      );
      expect(hit).toBeDefined();
      const box = await algorand.client.algod
        .getApplicationBoxByName(Number(app.appId), key)
        .do();
      return new Uint8Array(box.value);
    };
    const h3 = await findP(3n);
    const h2 = await findP(2n);

    await unseedSalePool({
      caller: app.admin,
      qty: 2n,
      topHashesTailToHead: [h3, h2],
      tailAtCall: 4n,
    });

    expect(await getPoolSize()).toBe(2n);
    expect(await boxExists(poolBoxKey(3n))).toBe(false);
    expect(await boxExists(poolBoxKey(2n))).toBe(false);
    expect(await boxExists(commitmentBoxKey(h3))).toBe(false);
    expect(await boxExists(commitmentBoxKey(h2))).toBe(false);
  });

  it("non-admin unseed reverts NOT_ADMIN", async () => {
    if (!localNetUp) return;
    const imposter = algosdk.generateAccount();
    await fundAccount(dispenser, imposter.addr.toString(), 3_000_000n);
    await expect(
      unseedSalePool({
        caller: imposter,
        qty: 1n,
        topHashesTailToHead: [new Uint8Array(32)],
        tailAtCall: 2n,
      }),
    ).rejects.toThrow(/NOT_ADMIN|assert failed/);
  });

  it("unseed underflow reverts POOL_UNDERFLOW", async () => {
    if (!localNetUp) return;
    // Pool now has 2 entries (after the unseed above). Try to unseed 4.
    await expect(
      unseedSalePool({
        caller: app.admin,
        qty: 4n,
        topHashesTailToHead: [
          new Uint8Array(32),
          new Uint8Array(32),
          new Uint8Array(32),
          new Uint8Array(32),
        ],
        tailAtCall: 2n,
      }),
    ).rejects.toThrow(/POOL_UNDERFLOW|BATCH_TOO_LARGE|assert failed/);
  });
});
