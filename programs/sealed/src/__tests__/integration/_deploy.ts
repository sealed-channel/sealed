/**
 * Deploys a fresh Sealed app for tests on LocalNet.
 *
 * Tests want a clean app per suite — no idempotent reuse here. Production
 * deploy lives in `src/deploy.ts` (slice S10).
 */

import { AlgorandClient } from "@algorandfoundation/algokit-utils";
import { AlgoAmount } from "@algorandfoundation/algokit-utils/types/amount";
import algosdk from "algosdk";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  fundEscrow,
  loadTreasuryEscrow,
  type LoadedEscrow,
} from "../../lib/escrow.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const ARC56_PATH = resolve(HERE, "..", "..", "..", "out", "Sealed.arc56.json");

const APP_BASE_MBR = 200_000n;
// Headroom: ~30 redeem+claim+publishKeys sequences. UserState 150k + name 30k
// + slack. Phase 3b: every redeem creates a 'w:' box from app account MBR;
// every claimUsername first claim creates an 'n:' box. Bumped from 2_000_000.
const BOX_HEADROOM = 6_000_000n;

export interface DeployedSealed {
  appId: bigint;
  appAddress: string;
  creator: algosdk.Account;
  admin: algosdk.Account;
  treasuryAddress: string;
  /** Loaded escrow if `withEscrow` was set. */
  escrow?: LoadedEscrow;
}

export interface DeploySealedParams {
  algorand: AlgorandClient;
  /** Funder that seeds the deployer + admin + treasury accounts. */
  dispenser: algosdk.Account;
  /** Address that gets the admin role on the contract. Defaults to deployer. */
  admin?: algosdk.Account;
  /** When true: load LogicSig escrow, fund it, rotate `treasuryAddress`. */
  withEscrow?: boolean;
  /** µAlgo to fund the escrow with. Defaults to 5 ALGO. */
  escrowFunding?: bigint;
  /** Override `roundsPerYear` global (default 9_500_000). Use small for expiry tests. */
  roundsPerYear?: bigint;
  /** Override `priceMicroAlgos` global (default 10_000_000 = 10 ALGO). */
  initialPrice?: bigint;
  /**
   * Override the ARC56 app spec path (default: current build in `out/`).
   * Used by migration tests to deploy a historical wire-layout build
   * (e.g. `fixtures/Sealed.v2.arc56.json`) and then update in place.
   */
  appSpecPath?: string;
}

/**
 * Generates a fresh deployer + admin, funds them, deploys the Sealed app,
 * calls `createApplication` to seed globals, tops up the app account.
 */
export async function deploySealed(
  p: DeploySealedParams,
): Promise<DeployedSealed> {
  const creator = algosdk.generateAccount();
  const admin = p.admin ?? algosdk.generateAccount();
  const zeroAddr = algosdk.encodeAddress(new Uint8Array(32));

  // Seed deployer + admin so they can sign.
  await fundAccount(
    p.algorand,
    p.dispenser,
    creator.addr.toString(),
    10_000_000n,
  );
  if (!p.admin) {
    await fundAccount(
      p.algorand,
      p.dispenser,
      admin.addr.toString(),
      1_000_000n,
    );
  }

  p.algorand.setSignerFromAccount(creator);

  const appSpec = readFileSync(p.appSpecPath ?? ARC56_PATH, "utf-8");
  const factory = p.algorand.client.getAppFactory({
    appSpec,
    defaultSender: creator.addr,
  });

  const { appClient, result } = await factory.send.create({
    method: "createApplication(address,address,uint64,uint64)void",
    args: [
      zeroAddr,
      admin.addr.toString(),
      p.roundsPerYear ?? 9_500_000n,
      p.initialPrice ?? 10_000_000n,
    ],
    onComplete: algosdk.OnApplicationComplete.NoOpOC,
    staticFee: AlgoAmount.MicroAlgo(2000n),
    // Match production deploy.ts: pages are immutable post-create and the
    // program grows across in-place updates (migration tests rely on this).
    extraProgramPages: 3,
  });

  const appId = appClient.appId;
  const appAddress = appClient.appAddress.toString();

  await p.algorand.send.payment({
    sender: creator.addr,
    receiver: appAddress,
    amount: AlgoAmount.MicroAlgo(APP_BASE_MBR + BOX_HEADROOM),
  });
  // result kept for future inspection
  void result;

  let escrow: LoadedEscrow | undefined;
  let treasuryAddress = zeroAddr;
  if (p.withEscrow) {
    escrow = await loadTreasuryEscrow(p.algorand.client.algod);
    treasuryAddress = escrow.address;

    await fundEscrow({
      algod: p.algorand.client.algod,
      funder: p.dispenser,
      escrowAddress: escrow.address,
      amount: p.escrowFunding ?? 50_000_000n,
    });

    // Rotate treasury via creator-only setTreasury ABI.
    const client = p.algorand.client.getAppClientById({
      appSpec,
      appId,
      defaultSender: creator.addr,
    });
    await client.send.call({
      method: "setTreasury(address)void",
      args: [escrow.address],
      sender: creator.addr,
      staticFee: AlgoAmount.MicroAlgo(1000n),
    });
  }

  return {
    appId,
    appAddress,
    creator,
    admin,
    treasuryAddress,
    escrow,
  };
}

async function fundAccount(
  algorand: AlgorandClient,
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
