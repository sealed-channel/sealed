/**
 * Payload canary test — ensures push notification payloads are identifier-free.
 *
 * Task 3.1 privacy requirement: no Sealed-level identifiers (message_id,
 * conversation_wallet, account_pubkey, etc.) should appear in push payloads.
 * This test uses canary strings to verify the privacy-clean implementations
 * don't leak metadata while allowing legitimate ciphertext content.
 */

import { createSilentApnsSender } from '../src/notifications/ohttp-apns';
import { createUnifiedPushDispatcher } from '../src/notifications/unifiedpush-dispatcher';
import type { OhttpClient, OhttpRequest } from '../src/notifications/ohttp-client';

describe('Payload Privacy Guard', () => {
  const CANARY_LEAK_MARKER = 'CANARY_LEAK_MARKER_abc123';

  // Forbidden identifiers that must NEVER appear as JSON keys or header names
  const FORBIDDEN_IDENTIFIERS = [
    'message_id',
    'conversation_wallet',
    'account_pubkey',
    'view_key',
    'blinded_id',
  ];

  // Mock OhttpClient that captures outgoing payloads
  let capturedRequests: OhttpRequest[] = [];

  const mockOhttpClient: OhttpClient = {
    async send(args: OhttpRequest) {
      capturedRequests.push({ ...args });
      return { status: 200, body: Buffer.from('{}') };
    }
  };

  beforeEach(() => {
    capturedRequests = [];
  });

  describe('Silent APNs Sender', () => {
    const mockJwtProvider = { getToken: () => 'test-jwt' };
    const apnsSender = createSilentApnsSender({
      ohttp: mockOhttpClient,
      apnsUrl: 'https://api.push.apple.com/3/device/',
      jwtProvider: mockJwtProvider,
      topic: 'com.test.app',
    });

    it('should not leak forbidden identifiers in payload', async () => {
      // Try to smuggle canary via device token
      const canaryDeviceToken = `deadbeef${CANARY_LEAK_MARKER}`;

      await apnsSender.send({ deviceToken: canaryDeviceToken });

      expect(capturedRequests).toHaveLength(1);

      const request = capturedRequests[0];
      const payloadStr = request.body.toString('utf8');

      // The canary in device token should NOT appear in payload body
      expect(payloadStr).not.toContain(CANARY_LEAK_MARKER);

      // No forbidden identifiers should appear as JSON keys
      for (const identifier of FORBIDDEN_IDENTIFIERS) {
        expect(payloadStr).not.toContain(`"${identifier}"`);
        expect(payloadStr).not.toContain(`'${identifier}'`);
      }

      // Headers should not contain forbidden identifiers
      const headersStr = JSON.stringify(request.headers);
      for (const identifier of FORBIDDEN_IDENTIFIERS) {
        expect(headersStr).not.toContain(identifier);
      }
    });

    it('should produce fixed-size payload regardless of input', async () => {
      // Send multiple different pushes
      await apnsSender.send({ deviceToken: 'short' });
      await apnsSender.send({ deviceToken: 'very-long-device-token-that-might-affect-payload' });
      await apnsSender.send({ deviceToken: CANARY_LEAK_MARKER.repeat(10) });

      expect(capturedRequests).toHaveLength(3);

      // All payloads should be identical size (APNS_PAYLOAD_SIZE = 2048)
      const firstSize = capturedRequests[0].body.length;
      expect(firstSize).toBe(2048);

      for (const request of capturedRequests) {
        expect(request.body.length).toBe(firstSize);
      }
    });
  });

  describe('UnifiedPush Dispatcher', () => {
    const upDispatcher = createUnifiedPushDispatcher({
      ohttp: mockOhttpClient,
    });

    it('should not leak forbidden identifiers in UP payload', async () => {
      // Create ciphertext containing canary (this is legitimate)
      const ciphertextWithCanary = Buffer.from(`encrypted-data-${CANARY_LEAK_MARKER}`, 'utf8');

      await upDispatcher.dispatch({
        endpoint: `https://up.example.com/push/${CANARY_LEAK_MARKER}`,
        ciphertext: ciphertextWithCanary,
      });

      expect(capturedRequests).toHaveLength(1);

      const request = capturedRequests[0];
      const payloadStr = request.body.toString('utf8');

      // The canary CAN appear in payload (it's legitimate ciphertext)
      expect(payloadStr).toContain(CANARY_LEAK_MARKER);

      // But no forbidden identifier NAMES should appear as structured metadata
      for (const identifier of FORBIDDEN_IDENTIFIERS) {
        // Not as JSON keys
        expect(payloadStr).not.toContain(`"${identifier}"`);
        expect(payloadStr).not.toContain(`'${identifier}'`);
        // Not as form fields
        expect(payloadStr).not.toContain(`${identifier}=`);
      }

      // Headers should not contain forbidden identifiers
      const headersStr = JSON.stringify(request.headers);
      for (const identifier of FORBIDDEN_IDENTIFIERS) {
        expect(headersStr).not.toContain(identifier);
      }
    });

    it('should produce fixed-size payload for UP dispatch', async () => {
      const shortCiphertext = Buffer.from('short', 'utf8');
      const longCiphertext = Buffer.from('x'.repeat(1000), 'utf8');
      const canaryData = Buffer.from(CANARY_LEAK_MARKER.repeat(50), 'utf8');

      await upDispatcher.dispatch({
        endpoint: 'https://up.example.com/push/token1',
        ciphertext: shortCiphertext,
      });

      await upDispatcher.dispatch({
        endpoint: 'https://up.example.com/push/token2',
        ciphertext: longCiphertext,
      });

      await upDispatcher.dispatch({
        endpoint: 'https://up.example.com/push/token3',
        ciphertext: canaryData,
      });

      expect(capturedRequests).toHaveLength(3);

      // All UP payloads should be fixed size (UP_PAYLOAD_SIZE = 2048)
      const firstSize = capturedRequests[0].body.length;
      expect(firstSize).toBe(2048);

      for (const request of capturedRequests) {
        expect(request.body.length).toBe(firstSize);
      }
    });

    it('should handle endpoint with canary without leaking structured metadata', async () => {
      // Endpoint URL contains canary - should not affect payload structure
      const canaryEndpoint = `https://push.service/${CANARY_LEAK_MARKER}/notify`;
      const cleanCiphertext = Buffer.from('clean-encrypted-data', 'utf8');

      await upDispatcher.dispatch({
        endpoint: canaryEndpoint,
        ciphertext: cleanCiphertext,
      });

      expect(capturedRequests).toHaveLength(1);

      const request = capturedRequests[0];

      // Request URL should contain the canary (legitimate)
      expect(request.url).toContain(CANARY_LEAK_MARKER);

      // But payload body should not contain it (only ciphertext)
      const payloadStr = request.body.toString('utf8');
      expect(payloadStr).not.toContain(CANARY_LEAK_MARKER);

      // And no forbidden identifiers should be present
      for (const identifier of FORBIDDEN_IDENTIFIERS) {
        expect(payloadStr).not.toContain(`"${identifier}"`);
      }
    });
  });

  describe('Cross-platform consistency', () => {
    it('should maintain consistent payload sizes across platforms', async () => {
      const apnsSender = createSilentApnsSender({
        ohttp: mockOhttpClient,
        apnsUrl: 'https://api.push.apple.com/3/device/',
        jwtProvider: { getToken: () => 'test-jwt' },
        topic: 'com.test.app',
      });

      const upDispatcher = createUnifiedPushDispatcher({
        ohttp: mockOhttpClient,
      });

      // Send one push per platform
      await apnsSender.send({ deviceToken: 'ios-token' });
      await upDispatcher.dispatch({
        endpoint: 'https://up.example.com/android-token',
        ciphertext: Buffer.from('test-data', 'utf8'),
      });

      expect(capturedRequests).toHaveLength(2);

      // Both platforms should use the same payload size for privacy symmetry
      expect(capturedRequests[0].body.length).toBe(2048);
      expect(capturedRequests[1].body.length).toBe(2048);
    });
  });
});