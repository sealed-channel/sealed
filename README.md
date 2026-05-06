# Sealed

**End-to-end encrypted private messaging on the blockchain**

Sealed is a decentralized messaging application that provides true end-to-end encryption while using blockchain technology for message transmission. Built with Flutter for cross-platform support, Sealed prioritizes privacy, security, and user sovereignty over their communication.


## Future Steps:
- **New Smart Contract**: Allowing users to top-up anonymously, written in present Algorand smart contract language which is TypeScript.
- **Alias Chat - Offline Key Exchange**: Allowing users to start an alias conversation being next to the person. Without any server knowing! And then you two start conversating, sending all messages to global wallet with a hint created out of these alias keys. From attacker perspective, he sees you're just sending messages to GOD knows who.



## 🔒 Security Features

- **Quantum-Resistant End-to-End Encryption**: Hybrid ML-KEM-512 (NIST standard) + X25519 key exchange
- **Message Padding**: All messages padded to 1KB to prevent size-based analysis attacks
- **Self-Custodial**: Users control their private keys, stored in device secure storage
- **Anonymous Channels**: Alias chat system for identity-free communication
- **OHTTP Requests**: All network requests flow through OHTTP encapsulation, hiding user IP addresses from Algorand RPC nodes and Sealed indexer
- **Perfect Forward Secrecy**: Ephemeral keys per message ensure past communications remain secure

## 🏗️ Architecture

Sealed operates across three distinct realms:

### 1. Device Realm 
- **Local Control**: SQLite database + secure storage
- **User Sovereignty**: Private keys never leave the device
- **Offline Capability**: Decrypting and reading messages happens offline

### 2. Blockchain Realm
- **Immutable Storage**: Encrypted messages stored on-chain
- **Primary Chain**: Algorand TestNet 
- **Legacy Support**: Solana devnet (migration available)
- **Decentralization**: No central authority controls message storage

### 3. Indexer Realm *(Optional)*
- **Push Notifications**: Real-time message delivery via FCM/APNs
- **Privacy Preserving**: Only receives metadata to route notifications, cannot decrypt content
- **OHTTP Gateway**: Accessed via Raspberry Pi gateway, relay sees ciphertext + client IP, gateway sees plaintext + relay IP

## Message Sync Strategy

**Blockchain**: Direct chain scanning through OHTTP (always works, slower cold start)


## 📱 Platform Support

| Platform | Status | Notes |
|----------|--------|--------|
| iOS      | ✅ Full | Native secure storage, APNs push |
| Android  | ✅ Full | Keystore integration, FCM push |

## 🤝 Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for:

- Development environment setup
- Code style guidelines  
- Pull request process
- Security disclosure policy

## 📄 License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.

## 🔗 Links

- **Documentation**: `sealed_app/docs/`
- **Architecture Details**: `sealed_app/ERROR_HANDLING.md`
- **Issue Tracker**: GitHub Issues
- **Security Contact**: See [SECURITY.md](SECURITY.md)

---

*Sealed: Private by design, decentralized by choice*