/**
 * TreasuryEscrow — fee-payer LogicSig for the Sealed contract.
 *
 * The only thing this signature ever authorises is paying group fees on behalf
 * of users. Six constraints enforce that nothing else is possible (SPEC §5.3):
 *
 *   1. Txn.typeEnum == Pay
 *   2. Txn.receiver  == Txn.sender             (self-pay, no value out)
 *   3. Txn.amount    == 0
 *   4. Txn.fee       <= MAX_FEE                (250000 µAlgo — covers Groth16
 *                                                verify's ~115 OpUp inner txns
 *                                                @ 1000µA each plus margin;
 *                                                see internal/benchmarks/verifier-cost.md)
 *   5. Txn.rekeyTo   == ZeroAddress
 *      Txn.closeRemainderTo == ZeroAddress
 *   6. Txn.groupIndex == 0 AND Global.groupSize == 2
 *
 * Combined: the escrow can only burn its own ALGO as group-fee pool, can't
 * move funds, can't rekey, can't close out.
 *
 * Channel box MBR (44_500µA per channel) is funded from the *app account*, not
 * the escrow. Deploy.ts pre-funds the app with BOX_HEADROOM=2_000_000µA
 * (≈44 channels). When deleteChannel runs, MBR auto-refunds to the app account
 * (self-healing). Admin can top up app via withdrawTreasury→pay if depleted.
 * This keeps the LogicSig amount==0 invariant intact (channel MBR never flows
 * through escrow).
 */

import {
  Global,
  LogicSig,
  logicsig,
  TransactionType,
  Txn,
} from "@algorandfoundation/algorand-typescript";
import type { uint64 } from "@algorandfoundation/algorand-typescript";

const MAX_FEE: uint64 = 250000;

@logicsig({ avmVersion: 11 })
export class TreasuryEscrow extends LogicSig {
  program(): boolean {
    return (
      Txn.typeEnum === TransactionType.Payment &&
      Txn.receiver === Txn.sender &&
      Txn.amount === 0 &&
      Txn.fee <= MAX_FEE &&
      Txn.rekeyTo === Global.zeroAddress &&
      Txn.closeRemainderTo === Global.zeroAddress &&
      Txn.groupIndex === 0 &&
      Global.groupSize === 2
    );
  }
}
