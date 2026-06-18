/**
 * Admin helpers for Sealed.
 *
 * Wraps `withdrawTreasury(uint64,address)void` and `setTreasury(address)void`.
 *
 * `withdrawTreasury` issues an inner-pay from the contract account; caller
 * fee-pools both txns (own fee + inner-txn fee).
 *
 * `setTreasury` rotates the `treasuryAddress` global; creator-only.
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import { AlgoAmount } from "@algorandfoundation/algokit-utils/types/amount";
import algosdk from "algosdk";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ARC56_PATH = resolve(__dirname, "../../out/Sealed.arc56.json");

export interface WithdrawTreasuryParams {
  algorand: AlgorandClient;
  appId: bigint;
  admin: algosdk.Account;
  amount: bigint;
  receiver: string;
}

export async function withdrawTreasury(
  p: WithdrawTreasuryParams,
): Promise<string> {
  const appSpec = readFileSync(ARC56_PATH, "utf-8");
  p.algorand.setSignerFromAccount(p.admin);
  const client = p.algorand.client.getAppClientById({
    appSpec,
    appId: p.appId,
    defaultSender: p.admin.addr,
  });

  const result = await client.send.call({
    method: "withdrawTreasury(uint64,address)void",
    args: [p.amount, p.receiver],
    sender: p.admin.addr,
    // Own fee + inner-pay fee.
    staticFee: AlgoAmount.MicroAlgo(2000n),
  });
  return result.txIds[0];
}

export interface SetTreasuryParams {
  algorand: AlgorandClient;
  appId: bigint;
  creator: algosdk.Account;
  newEscrow: string;
}

export async function setTreasury(p: SetTreasuryParams): Promise<string> {
  const appSpec = readFileSync(ARC56_PATH, "utf-8");
  p.algorand.setSignerFromAccount(p.creator);
  const client = p.algorand.client.getAppClientById({
    appSpec,
    appId: p.appId,
    defaultSender: p.creator.addr,
  });

  const result = await client.send.call({
    method: "setTreasury(address)void",
    args: [p.newEscrow],
    sender: p.creator.addr,
    staticFee: AlgoAmount.MicroAlgo(1000n),
  });
  return result.txIds[0];
}
