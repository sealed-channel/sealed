import { describe, expect, it } from "vitest";
import algosdk from "algosdk";
import { buildUnsignedSendGroup, GROUP_FEE, MIN_FEE } from "../../lib/group.js";

/** Stub algod that satisfies only the surface we touch. */
function fakeAlgod(): algosdk.Algodv2 {
  const sp: algosdk.SuggestedParams = {
    fee: 0,
    firstValid: 1000,
    lastValid: 2000,
    genesisID: "localnet-v1",
    genesisHash: new Uint8Array(32),
    flatFee: false,
    minFee: 1000,
  };
  return {
    getTransactionParams: () => ({ do: async () => sp }),
  } as unknown as algosdk.Algodv2;
}

describe("group — buildUnsignedSendGroup", () => {
  it("builds a 2-txn group with treasury fee payer first", async () => {
    const treasury = algosdk.generateAccount();
    const user = algosdk.generateAccount();
    const selector = new Uint8Array([0xde, 0xad, 0xbe, 0xef]);
    const { feeTxn, appCallTxn } = await buildUnsignedSendGroup({
      algod: fakeAlgod(),
      appId: 123n,
      treasuryAddress: treasury.addr.toString(),
      userAddress: user.addr.toString(),
      ciphertext: new Uint8Array([1, 2, 3, 4]),
      methodSelector: selector,
    });

    // Both txns must share a group ID.
    expect(feeTxn.group).toBeTruthy();
    expect(feeTxn.group).toEqual(appCallTxn.group);

    // Txn 0 — treasury self-pay, amount 0, fee 2× min.
    expect(feeTxn.type).toBe("pay");
    expect(feeTxn.payment?.amount).toBe(0n);
    expect(feeTxn.fee).toBe(GROUP_FEE);
    expect(feeTxn.sender.toString()).toBe(treasury.addr.toString());
    expect(feeTxn.payment?.receiver.toString()).toBe(treasury.addr.toString());

    // Txn 1 — user app call, fee 0 (covered by fee pool).
    expect(appCallTxn.type).toBe("appl");
    expect(appCallTxn.fee).toBe(0n);
    expect(appCallTxn.sender.toString()).toBe(user.addr.toString());
    expect(appCallTxn.applicationCall?.appIndex).toBe(123n);
  });

  it("exposes correct fee constants", () => {
    expect(MIN_FEE).toBe(1000n);
    expect(GROUP_FEE).toBe(2000n);
  });
});
