/**
 * Schema-driven ABI app-call decoder.
 *
 * Replaces the per-watcher decode helpers (decodeClaimUsername,
 * decodeSetUsername, …). Each on-chain method is described by an
 * `AbiCallSchema`; `decodeAbiCall` returns a typed, named-arg object or
 * `null` for any txn that does not match (wrong selector, malformed args,
 * length mismatch, missing/disagreeing sender, etc.).
 *
 * Why named args
 *   ABI byte[] uses a 2-byte big-endian length prefix; ABI byte[N] is a
 *   raw fixed-length blob. Doing this by index in every watcher meant
 *   `args[1]`/`args[2]` magic numbers and copy-pasted length checks. A
 *   schema names each arg, fixes its kind, and the decoder is the single
 *   place that knows the wire format.
 *
 * Sender-log verification
 *   Some contracts (the auth-binding sealed-message app) log Txn.sender()
 *   as logs[0] so consumers can verify the txn envelope wasn't repackaged
 *   by a relayer. Schemas opt-in via `requireSenderLog: true`. If the log
 *   is absent we treat that as "older contract, fall back to txn.sender"
 *   rather than a hard failure (otherwise we cannot ingest historical
 *   claims). If the log IS present and disagrees with txn.sender we drop
 *   the call. Mirrors the previous user-watcher behaviour exactly.
 */

import algosdk from 'algosdk';
import type { Logger } from 'pino';

const ABI_DYNAMIC_BYTES_HEADER = 2;

export type AbiArgSpec =
  | { kind: 'dynBytes'; minLen?: number; maxLen?: number }
  | { kind: 'fixedBytes'; len: number };

export interface AbiCallSchema<TArgs extends Record<string, AbiArgSpec>> {
  /** Method selector — first 4 bytes of sha512/256(method-signature). */
  selector: Buffer;
  /** Named args, declared in on-chain order. */
  args: TArgs;
  /** When true, drop the call if logs[0] is a 32-byte address that disagrees with txn.sender. */
  requireSenderLog?: boolean;
}

/** Subset of an algokit-subscriber transaction we actually read. */
export interface SubscribedTxn {
  id: string;
  sender?: string;
  confirmedRound?: bigint;
  roundTime?: number;
  logs?: ReadonlyArray<Uint8Array | string>;
  applicationTransaction?: {
    applicationId?: bigint | number;
    applicationArgs?: ReadonlyArray<Uint8Array>;
  };
  /** Present on payment txns; read by raw (non-ABI) filters. */
  paymentTransaction?: {
    receiver?: string;
    amount?: bigint | number;
  };
  /** Raw txn note (base64 string from the indexer, or bytes from algod). */
  note?: Uint8Array | string;
}

export interface DecodedAbiCall<TArgs extends Record<string, AbiArgSpec>> {
  /** Raw bytes per named arg, length-validated against the schema. */
  args: { [K in keyof TArgs]: Uint8Array };
  /** Algorand address (base32, 58 chars). */
  sender: string;
  txId: string;
  confirmedRound: bigint;
  /**
   * Unix seconds from the block. `undefined` when the txn lacks roundTime
   * (e.g. test fakes); callers decide what to use as a fallback (Date.now()
   * in ms vs unix seconds, etc.) — the decoder does NOT default it.
   */
  roundTime: number | undefined;
}

export function decodeAbiCall<TArgs extends Record<string, AbiArgSpec>>(
  txn: SubscribedTxn,
  schema: AbiCallSchema<TArgs>,
  logger: Logger,
): DecodedAbiCall<TArgs> | null {
  const argSpecs = Object.entries(schema.args) as Array<[keyof TArgs, AbiArgSpec]>;
  const expectedArgCount = argSpecs.length + 1; // +1 for selector

  const appArgs = txn.applicationTransaction?.applicationArgs;
  if (!appArgs || appArgs.length !== expectedArgCount) return null;

  const selector = Buffer.from(appArgs[0]);
  if (!selector.equals(schema.selector)) return null;

  const out: Record<string, Uint8Array> = {};
  for (let i = 0; i < argSpecs.length; i++) {
    const [name, spec] = argSpecs[i];
    const raw = appArgs[i + 1];
    const value = decodeArg(raw, spec);
    if (!value) {
      logger.debug(
        { txId: txn.id, arg: String(name), kind: spec.kind },
        'decodeAbiCall: arg failed schema check',
      );
      return null;
    }
    out[name as string] = value;
  }

  if (!txn.sender || txn.sender.length === 0) {
    logger.debug({ txId: txn.id }, 'decodeAbiCall: missing sender');
    return null;
  }

  if (schema.requireSenderLog) {
    const senderFromLogs = extractSenderLog(txn);
    if (senderFromLogs && senderFromLogs !== txn.sender) {
      logger.warn(
        { txId: txn.id, txnSender: txn.sender, loggedSender: senderFromLogs },
        'decodeAbiCall: dropping call with sender / log[0] mismatch',
      );
      return null;
    }
  }

  return {
    args: out as { [K in keyof TArgs]: Uint8Array },
    sender: txn.sender,
    txId: txn.id,
    confirmedRound: txn.confirmedRound ?? 0n,
    roundTime: txn.roundTime,
  };
}

function decodeArg(raw: Uint8Array, spec: AbiArgSpec): Uint8Array | null {
  if (spec.kind === 'fixedBytes') {
    return raw.length === spec.len ? raw : null;
  }
  // dynBytes: 2-byte big-endian length || payload.
  if (raw.length < ABI_DYNAMIC_BYTES_HEADER) return null;
  const len = (raw[0] << 8) | raw[1];
  if (len + ABI_DYNAMIC_BYTES_HEADER !== raw.length) return null;
  const payload = raw.subarray(ABI_DYNAMIC_BYTES_HEADER);
  if (spec.minLen !== undefined && payload.length < spec.minLen) return null;
  if (spec.maxLen !== undefined && payload.length > spec.maxLen) return null;
  return payload;
}

/**
 * Read logs[0] of an app call as an Algorand address, if present and
 * 32 bytes. Returns null otherwise (no logs, wrong length, decode error).
 * Pre-auth-binding contracts emit no logs — caller treats null as "fall
 * back to txn.sender", not as a failure.
 */
function extractSenderLog(txn: SubscribedTxn): string | null {
  const logs = txn.logs;
  if (!logs || logs.length === 0) return null;
  const first = logs[0];
  const buf = typeof first === 'string' ? Buffer.from(first, 'base64') : Buffer.from(first);
  if (buf.length !== 32) return null;
  try {
    return algosdk.encodeAddress(new Uint8Array(buf));
  } catch {
    return null;
  }
}
