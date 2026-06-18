/**
 * Treasury LogicSig escrow loader + funding helper.
 *
 * Reads the compiled `TreasuryEscrow.teal` artifact, compiles it via algod,
 * wraps it as an `algosdk.LogicSigAccount`, and exposes a `fundEscrow` helper
 * the deploy script uses to top it up.
 *
 * The LogicSig source-of-truth is `src/treasury_escrow.algo.ts`.
 */

import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import algosdk from "algosdk";

const HERE = dirname(fileURLToPath(import.meta.url));
const TEAL_PATH = resolve(HERE, "..", "..", "out", "TreasuryEscrow.teal");

export interface LoadedEscrow {
  /** Wrapped LogicSig account — usable as a signer. */
  account: algosdk.LogicSigAccount;
  /** Algorand address of the escrow account. */
  address: string;
  /** Raw compiled TEAL program bytes (cached for re-use across signs). */
  program: Uint8Array;
}

/**
 * Compiles `out/TreasuryEscrow.teal` via algod and returns a usable LogicSig
 * account. Throws if the TEAL artifact is missing — run `pnpm build` first.
 */
export async function loadTreasuryEscrow(
  algod: algosdk.Algodv2,
): Promise<LoadedEscrow> {
  let teal: string;
  try {
    teal = await readFile(TEAL_PATH, "utf8");
  } catch (e) {
    throw new Error(
      `TreasuryEscrow.teal not found at ${TEAL_PATH}; run "pnpm --filter @sealed/contract build" first (${(e as Error).message})`,
    );
  }
  const compiled = await algod.compile(teal).do();
  const program = new Uint8Array(Buffer.from(compiled.result, "base64"));
  const account = new algosdk.LogicSigAccount(program);
  return { account, address: account.address().toString(), program };
}

export interface FundEscrowParams {
  algod: algosdk.Algodv2;
  funder: algosdk.Account;
  escrowAddress: string;
  /** Amount in microALGO. */
  amount: bigint;
}

/**
 * Sends `amount` µALGO from `funder` to the escrow address. Idempotency is the
 * caller's job — this just submits one payment txn and waits for confirmation.
 */
export async function fundEscrow(p: FundEscrowParams): Promise<string> {
  const sp = await p.algod.getTransactionParams().do();
  const txn = algosdk.makePaymentTxnWithSuggestedParamsFromObject({
    sender: p.funder.addr,
    receiver: p.escrowAddress,
    amount: Number(p.amount),
    suggestedParams: sp,
  });
  const signed = txn.signTxn(p.funder.sk);
  const { txid } = await p.algod.sendRawTransaction(signed).do();
  await algosdk.waitForConfirmation(p.algod, txid, 4);
  return txid;
}
