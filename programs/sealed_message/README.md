# SealedMessage — event-stream subscriber README

**Audience:** the Algorand dev running the event stream for Sealed.

**Goal:** give you a single, indexable filter (`txn.apid == SEALED_MESSAGE_APP_ID`) to isolate all Sealed traffic on TestNet (and later MainNet) without parsing any payload bytes.

---

## Summary

- **App ID (TestNet):** `759175203`
- **Deployer / creator:** `WRPMRFASRL4YDEKHSH2D74H3LC4TKVJK2OGWXIS5DIIDSVMR7ZZYEDTCTY`
- **Explorer:** https://lora.algokit.io/testnet/application/759175203
- **Contract source:** `sealed_message.py` in this directory (PyTeal).
- **Network:** Algorand TestNet at first; MainNet later.
- **Filter:** one `apid` equality check per block. That's it.

The contract is deliberately **stateless** (no boxes, no global/local state). Every method just emits `Log(ciphertext_bytes)` and approves. The user's tx cost stays at the Algorand min fee (1000 µAlgos = 0.001 ALGO), identical to the payment-tx-with-note path it replaces — no MBR, no inner txs, no group txs.

---

## ABI methods

| Method | ABI signature | Logs emitted (in order) |
|---|---|---|
| `send_message` | `(byte[32], byte[]) void` | `logs[0] = ciphertext` |
| `send_alias_message` | `(byte[32], byte[32], byte[]) void` | `logs[0] = ciphertext` |
| `set_username` | `(byte[], byte[32], byte[32]) void` | `logs[0] = username`<br>`logs[1] = encryption_pubkey`<br>`logs[2] = scan_pubkey` |
| `publish_pq_key` | `(byte[]) void` | `logs[0] = pq_pubkey` |

### Argument semantics

- `recipient_tag: byte[32]` — opaque 32-byte routing tag derived from the recipient's view key. Sealed's indexer uses it to match messages to recipients. **Feel free to offer per-tag subscriptions** on your stream; we don't need to decode the payload for you to route them.
- `channel_id: byte[32]` — alias-chat channel identifier. Deterministic; same on both sides.
- `ciphertext: byte[]` — AES-256-GCM envelope, padded to 1024 bytes. Opaque to you and to us-in-transit; only the recipient decrypts.
- `encryption_pubkey / scan_pubkey: byte[32]` — X25519 public keys.
- `pq_pubkey: byte[]` — ML-KEM-512 public key (~800 bytes) for the post-quantum upgrade path.

### Method selectors (first 4 bytes of ABI hash)

Read from `sealed_message_contract.json` after compile, or grep `sealed_message_approval.teal` for `method "<name>(...)"` directives at the top of the program (lines 6–14 of the compiled TEAL).

---

## What to forward to the Sealed Tor Indexer

For each confirmed tx with `apid == SEALED_MESSAGE_APP_ID`, we'd like:

```
{
  "app_id":       <int>,
  "sender":       <base32 algorand address>,
  "tx_id":        <base32 tx id>,
  "round":        <int>,
  "round_time":   <unix seconds>,
  "method_name":  "send_message" | "send_alias_message" | ...,
  "app_args_b64": ["<method selector>", "<arg0 b64>", "<arg1 b64>", ...],
  "logs_b64":     ["<log0 b64>", "<log1 b64>", ...]
}
```

JSON-over-WebSocket is fine. Ordering-within-round is best-effort, but each tx must arrive **at most once** (we dedupe by `tx_id` anyway, but fewer duplicates = less work).

---

## Non-goals for the event stream

- We do **not** need payload decoding or decryption — we do that.
- We do **not** need you to run any Sealed-specific code. `apid` filter + log forwarding is the whole job.
- We do **not** need a catch-up API for arbitrary historical ranges; the indexer has its own catchup worker against algod. A "last N rounds" replay on reconnect would be a nice-to-have, not a requirement.

---

## Questions for you

1. **Transport:** WebSocket, gRPC, or HTTP long-poll?
2. **Latency target:** we assume sub-second from consensus to stream push. Confirm.
3. **Per-tag pre-filter:** do you want us to re-expose `recipient_tag` (the first ABI arg of `send_message` / `send_alias_message`) as a top-level filter field so subscribers can register `(app_id, tag)` pairs? This would let one subscriber get only its own messages.
4. **Reconnect semantics:** do you replay missed events on reconnect, and if so, for how far back?
5. **Auth:** do you need a per-subscriber API key, or is the stream open?

---

## Appendix: raw TEAL reading tips

`sealed_message_approval.teal` is the compiled approval program. Useful anchors:

- Lines 6–14 list the four ABI method selectors. Each `method "..."` line is followed by `bnz main_lN` which jumps into that method's body.
- Any `log` opcode in the program is emitting stream data. You should see six `log` occurrences total: one each for `send_message`, `send_alias_message`, and `publish_pq_key`, and three for `set_username` (username + two pubkeys).
- The contract has no `app_global_put`, `app_local_put`, `box_create`, `box_replace`, or `itxn_begin` — verification that it is stateless and doesn't dispatch inner txs.
