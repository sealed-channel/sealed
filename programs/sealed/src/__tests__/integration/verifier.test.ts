/**
 * T4 gate test: Groth16 verifier (SPEC-snark-redeem-B §5).
 *
 *   positive: proof from vector-01-basic verifies → true
 *   negative: tampered public input (root flipped) → false
 *
 * Vectors are produced by `circuits/scripts/gen-vectors.mjs` and converted to
 * AVM blobs on the fly via the inline helpers in this file (same byte layout
 * as `circuits/scripts/gen-proof-bytes.mjs`).
 *
 * Requires `algokit localnet start`. Skips automatically if LocalNet is down.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import { AlgoAmount } from "@algorandfoundation/algokit-utils/types/amount";
import algosdk from "algosdk";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it } from "vitest";
import { deploySealed, type DeployedSealed } from "./_deploy.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const ARC56_PATH = resolve(HERE, "..", "..", "..", "out", "Sealed.arc56.json");
const VECTOR_PATH = resolve(
  HERE,
  "..",
  "..",
  "..",
  "test",
  "snark-vectors",
  "vector-01-basic.json",
);

let algorand: AlgorandClient;
let dispenser: algosdk.Account;
let app: DeployedSealed;
let localNetUp = false;

const Q =
  21888242871839275222246405745257275088696311157297823662689037894645226208583n;

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
  if (pt[2] !== "1") throw new Error("non-affine G1");
  return concat(feBytes32(pt[0]), feBytes32(pt[1]));
}
function g2Bytes(
  pt: [[string, string], [string, string], [string, string]],
): Uint8Array {
  if (pt[2][0] !== "1" || pt[2][1] !== "0") throw new Error("non-affine G2");
  return concat(
    feBytes32(pt[0][0]),
    feBytes32(pt[0][1]),
    feBytes32(pt[1][0]),
    feBytes32(pt[1][1]),
  );
}
function proofBytes(p: VectorProof): Uint8Array {
  if (p.protocol !== "groth16") throw new Error("not groth16");
  return concat(g1Bytes(p.pi_a), g2Bytes(p.pi_b), g1Bytes(p.pi_c));
}

interface CallParams {
  appId: bigint;
  caller: algosdk.Account;
  proof: Uint8Array;
  publicInputs: Uint8Array;
}
async function callVerify(p: CallParams): Promise<boolean> {
  const appSpec = readFileSync(ARC56_PATH, "utf-8");
  algorand.setSignerFromAccount(p.caller);
  const client = algorand.client.getAppClientById({
    appSpec,
    appId: p.appId,
    defaultSender: p.caller.addr,
  });
  // Verifier is heavy: ensureSnarkBudget issues inner OpUp txns (each needs
  // 1000µA min fee, paid from group credit). 80k unit pool ≈ 114 OpUps.
  const result = await client.send.call({
    method: "_verifyProofForTest(byte[],byte[])bool",
    args: [p.proof, p.publicInputs],
    sender: p.caller.addr,
    staticFee: AlgoAmount.MicroAlgo(200_000n),
    note: new Uint8Array(randomBytes(8)),
  });
  return result.return as boolean;
}

beforeAll(async () => {
  try {
    algorand = AlgorandClient.defaultLocalNet();
    await algorand.client.algod.status().do();
    localNetUp = true;
  } catch {
    console.warn("LocalNet not running — skipping verifier integration tests.");
    return;
  }
  const dispenserAccount = await algorand.account.localNetDispenser();
  dispenser =
    dispenserAccount.account ??
    (dispenserAccount as unknown as algosdk.Account);
  app = await deploySealed({ algorand, dispenser });
});

describe("Groth16 verifier — DEV vk + golden vector (T4)", () => {
  it("accepts a valid proof from vector-01-basic", async () => {
    if (!localNetUp) return;
    const vec = JSON.parse(readFileSync(VECTOR_PATH, "utf-8"));
    const proof = proofBytes(vec.proof as VectorProof);
    expect(proof.length).toBe(256);
    const pub = concat(
      frBytes32(vec.publicInputs.root),
      frBytes32(vec.publicInputs.nullifier),
      frBytes32(vec.publicInputs.recipient),
      frBytes32(vec.publicInputs.denomination),
    );
    expect(pub.length).toBe(128);
    const ok = await callVerify({
      appId: app.appId,
      caller: app.admin,
      proof,
      publicInputs: pub,
    });
    expect(ok).toBe(true);
  }, 60_000);

  it("rejects a proof whose root public input is tampered", async () => {
    if (!localNetUp) return;
    const vec = JSON.parse(readFileSync(VECTOR_PATH, "utf-8"));
    const proof = proofBytes(vec.proof as VectorProof);
    const tamperedRoot = frBytes32(vec.publicInputs.root);
    // Flip the low byte. Result is still a valid Fr element (< 2^254), but does
    // not match the proof.
    tamperedRoot[31] ^= 0x01;
    const pub = concat(
      tamperedRoot,
      frBytes32(vec.publicInputs.nullifier),
      frBytes32(vec.publicInputs.recipient),
      frBytes32(vec.publicInputs.denomination),
    );
    const ok = await callVerify({
      appId: app.appId,
      caller: app.admin,
      proof,
      publicInputs: pub,
    });
    expect(ok).toBe(false);
  }, 60_000);
});
