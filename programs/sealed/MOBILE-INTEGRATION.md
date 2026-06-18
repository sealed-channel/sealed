# Sealed Contract — Mobile Integration

Handoff doc for the Flutter app. One unified Algorand TypeScript contract
(`Sealed`) replaces legacy `topup` + `alias_channel` + `sealed_message`. AVM 11.

## Deployment

| Network  | App ID    | App Address                                                      | Escrow (LogicSig)                                                |
|----------|-----------|------------------------------------------------------------------|------------------------------------------------------------------|
| TestNet  | 762150180 | D74MZVF4I6NRSLVQT3RKT7W3LNXPZ2SCM6YHCRZY6CPR5EBASL5MSU5OKY       | VQJ2L6FKQ2MYILEJJZJRU44DOWT7MRMNTLBHYKLKQXVSAM52LUNMW4XT6Q       |
| LocalNet | varies    | from `deploy.log`                                                | same escrow source bytes                                         |

> Note: appId 762150180 is the pre-unification deploy. Re-deploy fresh under the
> new `Sealed` name before mobile cutover (creator-only update path exists via
> bare `UpdateApplication`; contract is never deletable).

ARC56 spec: `programs/sealed/out/Sealed.arc56.json`
TEAL approval: `programs/sealed/out/Sealed.approval.teal`
Escrow TEAL: `programs/sealed/out/TreasuryEscrow.teal`

## ABI surface

All methods are on `Sealed`. Pubkeys are 32B X25519. `channelId` is 32B random.

```
createApplication(address,address,uint64)void          # bootstrap; creator only
setTreasury(address)void                               # creator only; rotate escrow
withdrawTreasury(uint64,address)void                   # admin only
registerCommitment(byte[],uint64)void                  # admin only; commits = hash(preimage)
claimUsername(byte[])void                              # 2-txn fee group
setBio(byte[])void                                     # 2-txn fee group; ≤160B UTF-8, empty clears
publishPqKey(byte[])void                               # 2-txn; per-sender PQ pubkey
sendMessage(byte[32],byte[])void                       # 2-txn; arg0 = recipient_tag
sendAliasMessage(byte[32],byte[32],byte[])void         # 2-txn; (channelId, recipient_tag, ct)
createChannel(byte[32],byte[32])void                   # 2-txn; (channelId, creatorPubkey)
acceptChannel(byte[32],byte[32])void                   # 2-txn; (channelId, acceptorPubkey)
deleteChannel(byte[32])void                            # 2-txn; anyone-with-id
readChannel(byte[32])byte[]                            # readonly; 73B blob
getCredits(address)uint64                              # readonly
pruneExpired(address)void                              # 2-txn
```

## Box layout

| Map        | Key prefix | Key suffix         | Value                                            |
|------------|------------|--------------------|--------------------------------------------------|
| commitments| `c:`       | 32B preimage hash  | `Commitment` (denomination + redeemer + expiry)  |
| credits    | `w:`       | 32B wallet addr    | `CreditState` (batches FIFO + total)             |
| names      | `n:`       | username bytes     | `arc4.Address` (32B)                             |
| channels   | `ch:`      | 32B channelId      | `ChannelRow` 73B = creator(32)+acceptor(32)+state(1)+createdAt(8) |

Box MBR auto-debits from **app account** (not escrow). Deploy pre-funds with
`BOX_HEADROOM = 2_000_000 µA` (≈44 channels). Delete refunds.

## Fees & escrow

- `GROUP_FEE = MIN_FEE * 2` (2000 µA flat). Escrow Txn 0 pays whole pool.
- Escrow constraints (`TreasuryEscrow` LogicSig): typeEnum=Pay, receiver==sender,
  amount==0, fee≤10000, no rekey/close, groupIndex==0, groupSize==2.
- App-call Txn 1 sets fee=0 (covered by pool).
- Escrow never moves value; only burns own ALGO as fee. Top up via dispenser.

## Ephemeral wallet flow

Zero-ALGO wallets work end-to-end because the escrow fronts fees and the app
account fronts box MBR. A fresh `algosdk.generateAccount()` can call
`createChannel` / `sendMessage` without ever holding ALGO.

## Redeem code grammar

16-char Crockford base32 (80-bit entropy). Charset `0123456789ABCDEFGHJKMNPQRSTVWXYZ`.
Normalize on input: `I/L → 1`, `O → 0`, uppercase, strip non-alphanumerics.

```
code      = 16 chars Crockford b32
preimage  = b32decode(code)            # 10 bytes
preimage  = preimage || zero(6)        # pad to 16B
commitment= sha256(preimage)[:32]      # admin registers this
```

Admin calls `registerCommitment(commitment, denomination)`. User redeems by
revealing preimage; contract recomputes sha256 and matches box `c:<commitment>`.

## TypeScript snippets

```ts
import { AlgorandClient } from '@algorandfoundation/algokit-utils';
import { createChannel, acceptChannel, readChannel, parseChannelRow }
  from '@sealed/contract/lib/channel';
import { loadTreasuryEscrow } from '@sealed/contract/lib/escrow';

const algorand = AlgorandClient.testNet();
const escrow   = await loadTreasuryEscrow(algorand.client.algod);
const appId    = 762150180n;

// Create channel (creator side)
await createChannel({
  algorand, appId, sender: aliceAccount,
  channelId: random32(), creatorPubkey: alice.x25519.pub,
  escrow,
});

// Accept (bob side)
await acceptChannel({
  algorand, appId, sender: bobAccount,
  channelId, acceptorPubkey: bob.x25519.pub, escrow,
});

// Read state
const row = parseChannelRow(
  await readChannel({ algorand, appId, sender: anyAccount, channelId })
);
// row.state: 0=pending, 1=accepted
```

For sendMessage / sendAliasMessage: pass `recipient_tag = sha256(recipientPubkey || salt)`
as the first 32B arg. Indexer filters on `application-args[1]` to route push notifications.

## Revert codes (assert messages)

| Code              | Where           | Meaning                                    |
|-------------------|-----------------|--------------------------------------------|
| `NOT_GROUP`       | all 2-txn       | groupSize ≠ 2                              |
| `BAD_GROUP_INDEX` | all 2-txn       | app-call not at index 1                    |
| `BAD_FEE_PAYER`   | all 2-txn       | Txn 0 sender ≠ stored treasury             |
| `BAD_FEE`         | all 2-txn       | Txn 0 fee < GROUP_FEE                      |
| `CHANNEL_EXISTS`  | createChannel   | box already present                        |
| `CHANNEL_NOT_FOUND`| accept/delete/read | box missing                             |
| `NOT_PENDING`     | acceptChannel   | state ≠ 0                                  |
| `SELF_ACCEPT`     | acceptChannel   | acceptorPubkey == creatorPubkey            |
| `ZERO_PUBKEY`     | create/accept   | all-zero 32B pubkey                        |
| `NOT_ADMIN`       | admin gates     | sender ≠ admin                             |
| `TAKEN`           | register/claim  | commitment or name already used            |
| `NO_CREDITS`      | sendMessage     | wallet has zero unexpired credits          |
| `BIO_TOO_LONG`    | setBio          | bio arg exceeds 160 bytes                  |
| `BAD_VERSION`     | any UserState read | box version byte not in {2, 3}          |

## Profile bio (UserState v3, 2026-06-12)

`UserState` (box `w:<addr>`) is now wire-layout **v3**: the dynamic field
`bio` (byte[], ≤160 bytes UTF-8) is appended after `pqPubkeyHash`. ARC4 head
grew 102→104 bytes — decoders MUST branch on the version byte (byte 0):

- `2` — legacy box, no bio slot; treat bio as empty.
- `3` — current layout, bio offset at head bytes 102-103.

Migration is **lazy**: the contract upgrades a v2 box to v3 on its next write
(any credit-spending op). Readonly methods decode both. Off-chain mirror:
`src/lib/codec.ts` `decodeUserState` (v2+v3) / `encodeUserState` (v3 only);
`src/lib/bio.ts` `setBio()` builds the 2-txn escrow group.

`setBio` spends 1 credit and emits `BioChanged { wallet, bio }` (ARC28) plus
`CreditSpent`. Empty bio clears the field. Bio is public on-chain plaintext.

## Test verification

- 73 unit + integration tests green on LocalNet (`npm test`).
- Stability: 3 consecutive runs, 73/73 pass.
- Channel lifecycle covered: create/accept/delete + 7 revert paths.

## Build / deploy

```bash
cd programs/sealed
npm install
npm run build                  # puya-ts → out/Sealed.arc56.json
npm test                       # vitest fileParallelism:false
npm run deploy:testnet         # ts-node src/scripts/deploy.ts
```

Deploys append a line to `deploy.log` with `network`, `appId`, `appAddress`,
`escrow`, `deployer`, `commit`.
