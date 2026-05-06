# Push Provider Metadata Audit

This document enumerates exactly what Apple (APNs) and Google can observe in Sealed's push notification pipeline, implemented in commits 439bfce8 and bb001095.

## Implementation Overview

The push pipeline consists of three key components:

- [`src/notifications/ohttp-apns.ts`](../src/notifications/ohttp-apns.ts) — iOS silent-push via OHTTP relay, 2048B fixed payload
- [`src/notifications/push-scheduler.ts`](../src/notifications/push-scheduler.ts) — uniform heartbeat scheduling for cover traffic
- [`src/notifications/unifiedpush-dispatcher.ts`](../src/notifications/unifiedpush-dispatcher.ts) — Android UnifiedPush, zero Google involvement

## Observable Metadata by Provider

| Observable Item | iOS (Apple APNs) | Android (UnifiedPush) | Mitigation Status |
|---|---|---|---|
| Device token | Apple-issued opaque token | Device-supplied endpoint URL | Unavoidable (protocol requirement) |
| Payload size | Constant 2048 bytes | Constant 2048 bytes | **Mitigated** (fixed padding) |
| Send timing | Fixed slot intervals | Real-time dispatch | **Mitigated** for iOS via scheduler |
| Send frequency | Uniform cadence per token | Event-driven | **Mitigated** for iOS (cover traffic) |
| Source IP | OHTTP relay IP | OHTTP relay IP | **Mitigated** (origin hidden) |
| TLS fingerprint | Relay's JA3 signature | Relay's JA3 signature | **Residual** (relay-level mitigation) |
| Destination enumeration | All tokens for bundle ID | N/A (self-hosted) | **Residual** (APNs can list all) |
| Provider auth | Team ID in JWT | None required | **Residual** (APNs protocol requirement) |
| App identification | Bundle ID in apns-topic | None transmitted | **Residual** (APNs protocol requirement) |

## iOS Residual Exposure (Unavoidable)

Apple necessarily observes the following through APNs:

1. **App presence**: A Sealed-bundled application exists on device with token X
2. **Push cadence**: Token X receives uniform-interval silent pushes (heartbeat pattern)
3. **Developer identity**: Provider JWT contains the Sealed team ID for authentication
4. **Bundle identification**: `apns-topic` header contains `com.sealed.app` bundle ID

These residuals are inherent to the APNs protocol. The uniform timing prevents Apple from distinguishing real message arrivals from cover traffic.

## Android Residual Exposure

### UnifiedPush on De-Googled Android (GrapheneOS/CalyxOS)

**Essentially none.** The UnifiedPush distributor is self-hosted and receives only:
- Fixed 2048-byte opaque blobs via OHTTP relay
- Device-supplied endpoint URLs (distributor already knows its own topics)

Google Play Services is absent from the system entirely.

### UnifiedPush on Stock Android with Play Services

The UnifiedPush distributor app is installed, but Google Play Services is **not in the push delivery path**. Play Services may observe:
- App installation and foreground usage (OS-level telemetry)
- Network usage patterns (out of scope for push-specific privacy)

Push notification content and timing remain invisible to Google.

## Implementation Notes

### Payload Construction

iOS pushes use a byte-exact template:
```json
{"aps":{"content-available":1},"n":"<base64-nonce>"}
```
Padded with NUL bytes to exactly 2048 bytes. The nonce varies but payload size remains constant.

Android payloads are application-layer ciphertext + random padding to 2048 bytes.

### Timing Schedule

The iOS push scheduler (Task 1.7) enforces uniform cadence via `PushSchedulerOptions.slotMs`. The specific interval value requires tuning against Apple's push budget limitations and will be configured in a follow-up deployment.

### OHTTP Relay

Both platforms route through an OHTTP relay to hide the indexer's source IP from push providers. The relay's TLS fingerprint toward APNs/distributors is not controlled by this implementation.

## Security Assessment

**Threat model satisfied**: Push providers cannot correlate message arrival timing with user activity or distinguish real notifications from cover traffic. Content remains encrypted end-to-end.

**Remaining work**: Finalize iOS slot interval based on APNs budget measurements in production.