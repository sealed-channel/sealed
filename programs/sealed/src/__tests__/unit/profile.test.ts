import { describe, expect, it } from "vitest";
import algosdk from "algosdk";
import { createHash } from "node:crypto";
import {
  ctEqual,
  fetchFullProfile,
  readUserProfile,
} from "../../lib/profile.js";
import { encodeUserState, ZERO_KEY, type UserState } from "../../lib/codec.js";

const acct = algosdk.generateAccount();
const wallet = acct.addr.toString();
const APP_ID = 999n;

function fakeAlgod(box: Uint8Array | null): algosdk.Algodv2 {
  return {
    getApplicationBoxByName: () => ({
      do: async () => {
        if (box === null) throw new Error("box not found");
        return { value: box };
      },
    }),
  } as unknown as algosdk.Algodv2;
}

function makeState(pqPubkey: Uint8Array): {
  state: UserState;
  encoded: Uint8Array;
  hash: Uint8Array;
} {
  const hash = new Uint8Array(createHash("sha256").update(pqPubkey).digest());
  const state: UserState = {
    version: 3,
    username: new TextEncoder().encode("alice"),
    batchCount: 0,
    batches: [],
    encryptionPubkey: new Uint8Array(32).fill(7),
    scanPubkey: new Uint8Array(32).fill(8),
    pqPubkeyHash: hash,
    bio: new Uint8Array(),
  };
  return { state, encoded: encodeUserState(state), hash };
}

describe("ctEqual", () => {
  it("returns true on identical bytes", () => {
    expect(ctEqual(new Uint8Array([1, 2, 3]), new Uint8Array([1, 2, 3]))).toBe(
      true,
    );
  });
  it("returns false on length mismatch", () => {
    expect(ctEqual(new Uint8Array([1]), new Uint8Array([1, 2]))).toBe(false);
  });
  it("returns false on content mismatch", () => {
    expect(ctEqual(new Uint8Array([1, 2, 3]), new Uint8Array([1, 2, 4]))).toBe(
      false,
    );
  });
});

describe("readUserProfile", () => {
  it("returns null when box missing", async () => {
    const out = await readUserProfile(fakeAlgod(null), APP_ID, wallet);
    expect(out).toBeNull();
  });

  it("decodes existing box", async () => {
    const pq = new Uint8Array(64).fill(0xab);
    const { encoded, hash } = makeState(pq);
    const out = await readUserProfile(fakeAlgod(encoded), APP_ID, wallet);
    expect(out).not.toBeNull();
    expect(out!.wallet).toBe(wallet);
    expect(out!.version).toBe(3);
    expect(out!.pqPubkeyHash).toEqual(hash);
    expect(new TextDecoder().decode(out!.username)).toBe("alice");
  });
});

describe("fetchFullProfile", () => {
  const pq = new Uint8Array(800);
  for (let i = 0; i < pq.length; i++) pq[i] = i & 0xff;
  const { encoded } = makeState(pq);

  function mkFetch(body: Uint8Array | null, status = 200): typeof fetch {
    return (async () => ({
      ok: status >= 200 && status < 300,
      status,
      arrayBuffer: async () => (body ?? new Uint8Array()).buffer,
    })) as unknown as typeof fetch;
  }

  it("happy path returns FullUserProfile with verified pq pubkey", async () => {
    const out = await fetchFullProfile({
      algod: fakeAlgod(encoded),
      indexerBaseUrl: "http://idx",
      appId: APP_ID,
      wallet,
      fetchImpl: mkFetch(pq),
    });
    expect(out.pqPubkey).toEqual(pq);
  });

  it("throws PQ_HASH_MISMATCH on tampered pq pubkey", async () => {
    const tampered = new Uint8Array(pq);
    tampered[0] ^= 0xff;
    await expect(
      fetchFullProfile({
        algod: fakeAlgod(encoded),
        indexerBaseUrl: "http://idx",
        appId: APP_ID,
        wallet,
        fetchImpl: mkFetch(tampered),
      }),
    ).rejects.toThrow("PQ_HASH_MISMATCH");
  });

  it("throws NOT_FOUND when box missing", async () => {
    await expect(
      fetchFullProfile({
        algod: fakeAlgod(null),
        indexerBaseUrl: "http://idx",
        appId: APP_ID,
        wallet,
        fetchImpl: mkFetch(pq),
      }),
    ).rejects.toThrow("NOT_FOUND");
  });

  it("throws KEYS_UNSET when on-chain hash is zero", async () => {
    const zeroHashState: UserState = {
      version: 3,
      username: new Uint8Array(),
      batchCount: 0,
      batches: [],
      encryptionPubkey: new Uint8Array(ZERO_KEY),
      scanPubkey: new Uint8Array(ZERO_KEY),
      pqPubkeyHash: new Uint8Array(ZERO_KEY),
      bio: new Uint8Array(),
    };
    const encZero = encodeUserState(zeroHashState);
    await expect(
      fetchFullProfile({
        algod: fakeAlgod(encZero),
        indexerBaseUrl: "http://idx",
        appId: APP_ID,
        wallet,
        fetchImpl: mkFetch(pq),
      }),
    ).rejects.toThrow("KEYS_UNSET");
  });

  it("throws INDEXER_<status> on non-2xx", async () => {
    await expect(
      fetchFullProfile({
        algod: fakeAlgod(encoded),
        indexerBaseUrl: "http://idx",
        appId: APP_ID,
        wallet,
        fetchImpl: mkFetch(null, 503),
      }),
    ).rejects.toThrow("INDEXER_503");
  });
});
