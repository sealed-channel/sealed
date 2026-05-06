# Security Policy

## Supported Versions

| Version | Security Updates |
|---------|------------------|
| 1.x.x   | ✅ Actively supported |
| 0.x.x   | ❌ No longer supported |

## Reporting Security Vulnerabilities

**Please do not report security vulnerabilities through public GitHub issues.**

### Disclosure Process

1. **Email**: Send details to `development@sealed.channel` (replace with actual security email)
2. **GitHub Security Advisories**: Use the "Report a vulnerability" feature in the Security tab
3. **Response Time**: We aim to respond within 48 hours
4. **Disclosure Timeline**: Coordinated disclosure after fix deployment (typically 90 days)

### What to Include

- Description of the vulnerability
- Steps to reproduce the issue
- Potential impact assessment
- Any suggested fixes or mitigations

## Threat Model

### Cryptographic Guarantees

✅ **Protected by Design**:
- **Message Content**: AES-256-GCM encryption with hybrid ML-KEM-512 + X25519 keys
- **Quantum Resistance**: ML-KEM-512 (NIST standard) protects against quantum attacks
- **Forward Secrecy**: Each message uses unique ephemeral keypairs  
- **Size Analysis**: 1KB message padding prevents length-based inference
- **Key Isolation**: Private keys stored in device secure storage only

⚠️ **Limited Protection**:
- **Metadata Patterns**: Message timing and frequency observable on blockchain



### Trust Model

#### Device Realm
- **Trust Required**: Device operating system, secure storage implementation
- **Risk**: Physical device access, malware, platform vulnerabilities
- **Mitigation**: Hardware security modules (HSMs) where available

#### Blockchain Realm  
- **Trust Required**: Blockchain consensus mechanism (Algorand/Solana validators)
- **Risk**: Chain reorganization, validator collusion, protocol vulnerabilities
- **Mitigation**: Economic security of established networks

#### Indexer Realm *(Optional)*
- **Trust Required**: OHTTP relay and gateway operators act independently  
- **Risk**: Metadata correlation if relay and gateway collude
- **Mitigation**: Relay (oblivious.network) sees ciphertext + client IP, gateway (operator Pi) sees plaintext + relay IP, unlinkability holds with non-collusion

### Post-Quantum Cryptography

**Current State**: Quantum-resistant hybrid cryptography implemented

**Active Implementation**:
- **ML-KEM-512 (Kyber-512)**: NIST-standardized post-quantum key encapsulation
- **Hybrid Security**: X25519 + ML-KEM-512 for maximum compatibility and security  
- **Forward Security**: Each message protected by both classical and quantum-resistant keys
- **Future-Proof**: Already deployed and active in production

**Timeline**: Post-quantum resistance active today. Future updates will optimize performance and add additional PQ algorithms as standards evolve.

## Security Assumptions

### Device Security
- Secure storage (iOS Keychain, Android Keystore) protects private keys
- SQL Cipher database protects the database with messages by PIN code.
- Operating system prevents unauthorized app access to key material
- User maintains physical control of device and reasonable security practices

### Network Security
- TLS/HTTPS protects transport layer communications  
- OHTTP encapsulation hides client IP addresses from service endpoints
- Blockchain network maintains consensus and transaction integrity

### Cryptographic Implementations
- Cryptography libraries (Dart `cryptography`, `post_quantum`) are free of critical bugs
- Key generation uses cryptographically secure random number sources
- AES-GCM implementation provides authenticated encryption

## Known Limitations

### Metadata Leakage
- **Blockchain Transactions**: Sender/recipient wallet addresses are public
- **Timing Patterns**: Message frequency and timing observable by network monitors
- **Size Patterns**: Despite padding, some usage patterns may be detectable

### Availability Attacks
- **Chain Congestion**: High blockchain fees or congestion can delay message delivery
- **Network Blocking**: Jurisdictional internet filtering can block blockchain access

### Implementation Risks
- **Mobile Platform Security**: Varies significantly across devices and OS versions
- **Side Channel Attacks**: Timing/power analysis on consumer devices
- **Supply Chain**: Dependency on external cryptographic libraries and platform APIs

## Security Contact

For security-related inquiries:
- **Email**: development@sealed.channel
- **GitHub**: Use private security advisory reporting

Please allow up to 48 hours for initial response and follow responsible disclosure practices.