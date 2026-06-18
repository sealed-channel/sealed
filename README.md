# Sealed

**End-to-end encrypted messaging on Algorand. No servers. No phone number.**

Sealed is a decentralized messaging app where every message is encrypted on your device and stored on-chain as an unreadable blob. Not Sealed, not Algorand nodes, not anyone — only the intended recipient can read it. Your identity is your Algorand wallet. Built with Flutter for iOS and Android.

---

## How it works

When you send a message:

1. Your device fetches the recipient's public keys from the Algorand blockchain
2. A one-time ephemeral keypair is generated — used only for this message, then discarded
3. Two independent secrets are derived: one classical (X25519) and one post-quantum (ML-KEM-512), then combined via HKDF into an AES-GCM key
4. The message is padded to exactly 1KB and encrypted
5. The encrypted blob is submitted to the Sealed smart contract on Algorand

To receive messages, your device scans the chain for blobs that match your recipient tag — a cheap hash derived from your scan key — then decrypts only the ones addressed to you. All requests go through OHTTP so your IP is never exposed to Algorand nodes or Sealed infrastructure.

---

## Security

| Property | How |
|---|---|
| End-to-end encryption | AES-GCM with HKDF-derived key |
| Quantum resistance | Hybrid X25519 + ML-KEM-512 (NIST standard) |
| Forward secrecy | New ephemeral keypair per alias conversation |
| Traffic analysis resistance | All messages padded to 1KB |
| IP privacy | All requests via OHTTP — node never sees your IP |
| Self-custody | Private keys never leave your device |
| Duress wipe | Termination code on PIN screen wipes device silently |

---

## Alias Chats

Alias chats use freshly generated Algorand wallets for both sender and recipient — neither party uses their real wallet. Messages are encrypted and sent the same way as normal messages. No link exists between the alias wallets and either real identity.

**Roadmap:** Alias wallets will be funded through your subscription — no funding transaction ties back to your real wallet, no trail.

---

## Payment

Every message costs 1 credit. **Credits** are on-chain tokens redeemed via redeem code. If you have no credits, Sealed falls back to a small ALGO fee paid from your wallet via a treasury escrow — your wallet never pays gas directly.

---

## Architecture

### On device
- Private keys, decrypted messages, and contacts stored locally under a PIN-wrapped encryption key (DEK)
- Keys are deterministically derived from your Algorand wallet signature — same wallet always produces the same identity
- PIN wraps the DEK via KDF + AEAD. Termination code triggers silent full wipe

### On chain (Algorand)
- Encrypted message blobs stored as app-call transactions on the Sealed smart contract
- User identity (keys, username, credits) stored in ARC4 box state
- All writes use a 2-transaction fee-pool group — treasury escrow pays fees, user wallet signs the app-call only
- Smart contract written in TypeScript (Algorand AVM via TEALScript)

### Indexer (optional, privacy-preserving)
- Off-chain service that pre-matches messages to recipients using your view key
- View key lets the indexer find your messages without being able to read them
- Used for push notifications — delivers a pointer to the exact message to decrypt, no chain scan needed
- All indexer requests go through OHTTP

---

## Roadmap

- **Offline alias key exchange** — start an alias conversation in person, no server involved, using local key exchange
- **New UI / Design System** -  full redesign with a custom design system, new animations, and improved accessibility
- **Group chats** — extend the protocol to support multiple recipients with separate encryption keys, while maintaining the same security properties



---

## Platform support

| Platform | Status |
|---|---|
| iOS | ✅ Native secure storage, APNs push |
| Android | ✅ Keystore integration, FCM push |

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, code style, and PR process.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Security

See [SECURITY.md](SECURITY.md) for responsible disclosure.

---

*Private by design. Decentralized by choice.*
