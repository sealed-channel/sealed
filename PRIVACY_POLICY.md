# Privacy Policy — Sealed

**Effective Date:** March 14, 2026
**App Version:** 1.0.9+
**Platforms:** iOS · Android · Web · macOS · Linux · Windows

---

## 1. Overview

Sealed is a blockchain-based, end-to-end encrypted private messaging application. This policy explains what data is collected, where it lives, who controls it, and what rights you have.

A foundational principle of Sealed's architecture is that **no single party has full control over all your data**. Depending on where data lives, the controller is different — and in some cases it is you, the user, alone. We explain each data category explicitly below.

---

## 2. Who We Are

"Sealed", "we", "us", and "our" refers to the operator of the Sealed indexer service and application. Contact: **[your contact email]**.

For the purposes of applicable data protection law, we act as the **data controller only for the data stored on infrastructure we operate** (the indexer server). We are **not** the controller of data that exists only on your device or data written to a public blockchain — that distinction is critical and explained in full below.

---

## 3. The Three Data Realms — Who Controls What

Understanding Sealed requires understanding that your data exists in up to three distinct realms, each with a different controller:

### Realm A — Your Device (You are the sole controller)

The following data **never leaves your device in unencrypted form** and is stored in your device's secure enclave (iOS Keychain or Android Keystore):

| Data                                         | Storage Location                |
| -------------------------------------------- | ------------------------------- |
| 12-word BIP39 mnemonic (seed phrase)         | Device secure storage only      |
| Ed25519 wallet signing keypair (private key) | Device secure storage only      |
| X25519 encryption keypair (private key)      | Device secure storage only      |
| Message plaintext / decrypted conversations  | Local SQLite database on-device |
| Contact list (wallet addresses + usernames)  | Local SQLite database on-device |

**We have zero access to this data.** If you lose your device and your seed phrase backup, there is no recovery mechanism — no one can restore access on your behalf. You are the sole custodian.

---

### Realm B — The Public Blockchain (No one is the controller)

Every message sent through Sealed is transmitted as a transaction on a public blockchain (currently Algorand TestNet; previously Solana devnet). By design, this data is:

- **Public** — visible to anyone with access to the ledger
- **Permanent** — blockchain transactions are immutable; they cannot be deleted by you, by us, or by anyone
- **Pseudonymous** — tied to your wallet address, not your name or phone number

The following data is written to the blockchain as part of every message:

| Data                         | Description                                                                            |
| ---------------------------- | -------------------------------------------------------------------------------------- |
| Encrypted message ciphertext | AES-256-GCM ciphertext; content is unreadable without your private key                 |
| Ephemeral sender public key  | One-time X25519 public key per message, not your permanent identity key                |
| Recipient tag                | A 32-byte HMAC used for stealth addressing; does not directly identify you             |
| Transaction timestamp        | Block-level timestamp                                                                  |
| Sender wallet public key     | Your public wallet address (pseudonymous identity)                                     |
| Optional username            | If you register a human-readable username, it is written to the blockchain permanently |

**Because blockchain data is permanent and publicly accessible, no right of deletion or correction applies to on-chain data.** You should treat any information you choose to commit to the blockchain as irreversibly public (albeit encrypted where applicable).

---

### Realm C — Our Indexer Server (We are the data controller)

To deliver real-time push notifications and efficient message sync, we operate an indexer service. Sealed offers **three push modes** with very different privacy postures. The default is the most private; the others are explicitly opt-in (or being retired).

| Mode                          | What we hold                                          | What Apple/Google can see           | Status          |
| ----------------------------- | ----------------------------------------------------- | ------------------------------------ | --------------- |
| **Blinded (default)**         | Opaque tag + sealed device-token envelope             | Wake-ups proportional to **global** chain activity, not per-recipient | active          |
| **Targeted (opt-in)**         | Your X25519 view (scan) private key + sealed token    | One push **per matched message** to your device | opt-in, dual-disclosure consent required |
| **Legacy view-key endpoint**  | Your X25519 view private key + plaintext device token | Per-recipient silent push timing     | **deprecated**, sunset 2026-05-28 |

#### Blinded mode — the privacy default

In blinded mode the server stores **only**:

| Data                                  | Purpose                                                                                                |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `blinded_id` (HMAC-SHA256)            | Opaque per-device tag derived on your device. Cannot be reversed to identify you.                      |
| `enc_token` (sealed-box envelope)     | Your APNs/FCM device token, encrypted under the dispatcher's X25519 key. The indexer cannot decrypt it without help from a separately-operated dispatcher process. |
| Device platform (`ios` / `android`)   | Routing only.                                                                                          |
| Last-seen timestamp                   | Inactivity cleanup.                                                                                    |

When activity occurs on chain, the indexer fans out a **content-free wake-up** to every blinded registration. The notification carries **no ciphertext, no sender, no message ID, no chain metadata** — just "go check the chain". Per-device wake-ups are coalesced within a 5-second window to prevent battery drain on chain bursts.

**What this gives you:** the indexer cannot tell which messages are yours, and Apple/Google see only that your device wakes when *anybody* on Sealed has a new message — not when *you* do.

#### Targeted mode — opt-in only

If you turn on "Push Notifications" in settings, you accept a **two-paragraph disclosure** (with a checkbox gate) before the toggle takes effect:

1. The indexer holds your X25519 view (scan) private key and trial-decrypts every chain event to find ones addressed to you. It learns which messages are yours.
2. Apple or Google receive one push per matched message, so they can observe per-recipient wake timing.

In return, you get a visible alert ("You got a new encrypted message") instead of a silent wake-up. The push body is a frozen string and contains no metadata. The trade-off is unambiguous and reversible — toggling off unregisters the targeted record on the server.

#### Legacy view-key endpoint — being retired

The original push registration endpoint (`/push/register`) accepted your view private key alongside a plaintext device token. It is **deprecated as of 2026-04-28** and will be removed on **2026-05-28** (one release cycle). Responses include the IETF `Deprecation: true` and `Sunset` headers so older clients are warned. New installs use blinded mode by default; existing rows stop being honoured at sunset.

#### What the view key does and does not allow

In both legacy and targeted modes, the view key allows the indexer to determine **that a message was sent to you**. It does **not** allow the indexer to read the message contents. Content encryption uses a separate key path that never leaves your device.

#### Common indexer-side data

Across all modes, the indexer also keeps:

| Data                                 | Retention                                                       |
| ------------------------------------ | --------------------------------------------------------------- |
| Wallet public address                | Until account deletion or 90 days of inactivity                 |
| Username (if registered)             | Until account deletion                                          |
| Message metadata pointers            | 30 days; not message content                                    |
| Last-seen timestamp                  | 90 days                                                         |
| IP address (gateway logs)            | Server logs rotated per standard practice (typically 7–30 days) |

Push registration calls flow through OHTTP encapsulation, so the indexer gateway operator does not see your egress IP for those requests. The OHTTP relay (oblivious.network) sees ciphertext + client IP; the gateway operator sees plaintext request but not client IP. Calls between the indexer and Apple/Google are wrapped in OHTTP (RFC 9458) so push providers do not see the indexer's egress IP either.

---

## 4. Authentication

Sealed uses **wallet-based authentication only**. There is no email address, phone number, or password associated with your account. When authenticating to our indexer API, your app signs a time-limited challenge string with your Ed25519 wallet private key — the signing key never leaves your device.

---

## 5. Data We Do Not Collect

We explicitly do not collect:

- Your real name
- Email address
- Phone number
- Contacts from your device address book
- Location data
- Device advertising identifiers (IDFA / GAID)
- Biometric data
- Analytics or behavioural tracking data
- Crash reports or telemetry beyond server-side operational logs

---

## 6. Third-Party Data Processors

We use one external third-party service that processes your personal data:

### Google Firebase (Firebase Cloud Messaging)

- **Purpose:** Delivering push notification alerts when a new message is addressed to you
- **Data shared with Google:** Your FCM device token and notification payload. Notification payloads contain only the sender's wallet address and a message reference — **not message content**
- **Google's privacy policy:** [https://policies.google.com/privacy](https://policies.google.com/privacy)
- **Google's role:** Independent data processor; FCM token data is subject to Google's terms

### Public Blockchain RPC Endpoints

- **AlgoNode** (`testnet-api.algonode.cloud`) — public Algorand node operated by a third party. Transactions you broadcast are by nature globally visible. No personal identifying data beyond your wallet address and message ciphertext is transmitted.

No advertising networks, analytics platforms, data brokers, or any other third parties receive your data.

---

## 7. How We Use Your Data

Data we hold on our indexer server is used exclusively for:

1. **Delivering push notifications** — detecting new messages addressed to you and alerting your device
2. **Message sync** — helping your app efficiently retrieve relevant on-chain messages after periods offline
3. **Rate limiting and abuse prevention** — protecting the service from excessive API requests
4. **Service operation** — standard logging for diagnosing failures

We do not sell, rent, or share your data with any third party for commercial purposes.

---

## 8. Data Retention and Deletion

| Data Type                          | Automatic Retention Policy                                      |
| ---------------------------------- | --------------------------------------------------------------- |
| Indexer message metadata           | Deleted after **30 days**                                       |
| User account (view key, FCM token) | Deleted after **90 days of inactivity**                         |
| Server IP logs                     | Rotated per operational practice                                |
| Blockchain data                    | **Permanent** — cannot be deleted                               |
| Device data                        | Controlled entirely by you; deleting the app removes local data |

**Account deletion:** You may request deletion of all data we hold on our indexer by [method — e.g., sending a signed deletion request via the app settings or emailing us with your wallet address]. We will delete your view key, FCM token, and all associated metadata within 30 days. This does not affect blockchain data.

---

## 9. Security

- All message content is encrypted end-to-end using AES-256-GCM with per-message ephemeral keys derived via X25519 + HKDF
- Messages are padded to a uniform 1,024 bytes before encryption to prevent length-inference attacks
- Our indexer API uses Ed25519 signature-based authentication with signed time-limited nonces
- HTTPS/TLS is enforced for all API communication
- Our server uses `helmet` security headers and rate limiting (100 requests/minute per IP)
- Private keys are stored in platform secure enclaves (iOS Keychain, Android Keystore)
- Keys are zeroed in memory after use

**Post-quantum encryption (upcoming):** A planned upgrade will add ML-KEM-512 (Kyber-512) as a hybrid layer on top of X25519 for forward-looking quantum resistance.

---

## 10. Children's Privacy

Sealed is not directed at children under the age of 13 (or 16 where applicable under local law). We do not knowingly collect data from children. If you believe a child has used the service, please contact us and we will delete indexer-side data promptly.

---

## 11. Your Rights

Depending on your jurisdiction, you may have the right to:

- **Access** the personal data we hold about you
- **Rectification** of inaccurate data (where technically possible)
- **Erasure** ("right to be forgotten") of data held on our servers — note this cannot extend to blockchain data
- **Portability** of your indexer-held data
- **Object** to processing
- **Withdraw consent** at any time (e.g., disabling push notifications revokes FCM token registration)

To exercise any of these rights, contact us at **[your contact email]**. We will respond within 30 days.

**Important limitation:** Rights of deletion, rectification, and erasure **do not apply to data written to the public blockchain** (Algorand or Solana). That data is outside our technical control by design.

---

## 12. International Data Transfers

Our indexer server is hosted at **[your hosting region]**. If you access Sealed from outside that region, your indexer-held data may be transferred internationally. We implement appropriate safeguards in accordance with applicable law.

Public blockchain data (Realm B) is replicated globally across all blockchain nodes and is not subject to geographic data transfer restrictions.

---

## 13. Changes to This Policy

We may update this policy as the app evolves. Material changes will be communicated via an in-app notice. Continued use of Sealed after such notice constitutes acceptance. Previous versions will be archived at **[URL]**.

---

## 14. Contact

For privacy-related questions, data requests, or complaints:

**Email:** [your contact email]
**Response time:** Within 30 days

If you are in the EU/EEA and believe we have violated your rights under the GDPR, you have the right to lodge a complaint with your local supervisory authority.

---

_Sealed is designed on the principle that private communication should be verifiably private — not just by policy, but by cryptographic architecture. This privacy policy reflects that design honestly, including the trade-offs involved._
