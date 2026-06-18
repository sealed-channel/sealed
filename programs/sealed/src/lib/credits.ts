/**
 * Credit helpers for Sealed.
 *
 * Wraps `pruneExpired(address)void` and `getCredits(address):uint64` ABI calls.
 *
 * Both are anyone-callable. `pruneExpired` reverts `NO_CREDITS` if the target
 * has no credit box; `getCredits` returns 0 instead of reverting.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import { AlgoAmount } from "@algorandfoundation/algokit-utils/types/amount";
import algosdk from "algosdk";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ARC56_PATH = resolve(__dirname, "../../out/Sealed.arc56.json");

function creditBoxKey(addr: string): Uint8Array {
  const pk = algosdk.decodeAddress(addr).publicKey;
  const key = new Uint8Array(2 + 32);
  key.set(new TextEncoder().encode("w:"), 0);
  key.set(pk, 2);
  return key;
}

export interface PruneExpiredParams {
  algorand: AlgorandClient;
  appId: bigint;
  caller: algosdk.Account;
  wallet: string;
}

export async function pruneExpired(p: PruneExpiredParams): Promise<string> {
  const appSpec = readFileSync(ARC56_PATH, "utf-8");
  p.algorand.setSignerFromAccount(p.caller);
  const client = p.algorand.client.getAppClientById({
    appSpec,
    appId: p.appId,
    defaultSender: p.caller.addr,
  });

  const result = await client.send.call({
    method: "pruneExpired(address)void",
    args: [p.wallet],
    boxReferences: [creditBoxKey(p.wallet)],
    sender: p.caller.addr,
    staticFee: AlgoAmount.MicroAlgo(1000n),
  });
  return result.txIds[0];
}

export interface GetCreditsParams {
  algorand: AlgorandClient;
  appId: bigint;
  caller: algosdk.Account;
  wallet: string;
}

export async function getCredits(p: GetCreditsParams): Promise<bigint> {
  const appSpec = readFileSync(ARC56_PATH, "utf-8");
  p.algorand.setSignerFromAccount(p.caller);
  const client = p.algorand.client.getAppClientById({
    appSpec,
    appId: p.appId,
    defaultSender: p.caller.addr,
  });

  const result = await client.send.call({
    method: "getCredits(address)uint64",
    args: [p.wallet],
    boxReferences: [creditBoxKey(p.wallet)],
    sender: p.caller.addr,
    staticFee: AlgoAmount.MicroAlgo(1000n),
  });
  const ret = result.return as unknown;
  if (typeof ret === "bigint") return ret;
  if (typeof ret === "number") return BigInt(ret);
  throw new Error("UNEXPECTED_RETURN");
}
