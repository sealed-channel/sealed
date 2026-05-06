import { createSilentApnsSender, APNS_PAYLOAD_SIZE } from '../src/notifications/ohttp-apns';
import type { ApnsJwtProvider } from '../src/notifications/apns-jwt';

interface MockOhttpClient {
  send: jest.Mock;
}

/**
 * Task 1.6 — OHTTP-wrapped silent APNs sender.
 *
 * Contract:
 *  - Payload is a fixed-shape silent push: {aps: {content-available: 1}, n: <nonce>}
 *  - No alert/sound/badge/message_id/conversation_wallet/account_pubkey — ever.
 *  - Byte length is constant across calls (size side-channel defense).
 *  - Routed through OHTTP so Apple never sees the indexer's origin IP.
 */
describe('createSilentApnsSender', () => {
  let mockOhttp: MockOhttpClient;
  let mockJwtProvider: ApnsJwtProvider;
  const apnsUrl = 'https://api.push.apple.com/3/device/';
  const topic = 'com.example.sealed';

  beforeEach(() => {
    mockOhttp = { send: jest.fn().mockResolvedValue({ status: 200, body: Buffer.alloc(0) }) };
    mockJwtProvider = { getToken: jest.fn().mockReturnValue('fake.jwt.token') };
  });

  function makeSender() {
    return createSilentApnsSender({
      ohttp: mockOhttp as any,
      apnsUrl,
      jwtProvider: mockJwtProvider,
      topic,
    });
  }

  it('sends a silent push with content-available=1 and no other aps fields', async () => {
    const sender = makeSender();
    await sender.send({ deviceToken: 'a'.repeat(64) });

    const req = mockOhttp.send.mock.calls[0][0];
    expect(req.method).toBe('POST');
    expect(req.url).toBe(`${apnsUrl}${'a'.repeat(64)}`);
    expect(req.headers['apns-push-type']).toBe('background');
    expect(req.headers['apns-priority']).toBe('5');
    expect(req.headers['apns-topic']).toBe(topic);
    expect(req.headers['authorization']).toBe(`bearer ${mockJwtProvider.getToken()}`);

    const body = JSON.parse(req.body.toString('utf8').replace(/\0+$/, ''));
    expect(body).toHaveProperty('aps');
    expect(body.aps).toEqual({ 'content-available': 1 });
    expect(body).toHaveProperty('n');
    expect(typeof body.n).toBe('string');
    // nonce must be non-empty base64
    expect(body.n.length).toBeGreaterThan(0);
  });

  it('NEVER includes forbidden Sealed-level identifiers or alert fields', async () => {
    const sender = makeSender();
    await sender.send({ deviceToken: 'b'.repeat(64) });

    const req = mockOhttp.send.mock.calls[0][0];
    const raw = req.body.toString('utf8');

    for (const forbidden of [
      'alert', 'sound', 'badge',
      'message_id', 'conversation_wallet', 'account_pubkey', 'view_key',
      'title', 'body',
    ]) {
      expect(raw).not.toContain(forbidden);
    }
  });

  it('payload byte length is constant across calls (no size side channel)', async () => {
    const sender = makeSender();
    await sender.send({ deviceToken: 'c'.repeat(64) });
    await sender.send({ deviceToken: 'd'.repeat(64) });
    await sender.send({ deviceToken: 'e'.repeat(64) });

    const sizes = mockOhttp.send.mock.calls.map((c: any) => c[0].body.length);
    expect(new Set(sizes).size).toBe(1);
    expect(sizes[0]).toBe(APNS_PAYLOAD_SIZE);
  });

  it('returns ok:false with status 0 when OHTTP relay throws', async () => {
    mockOhttp.send.mockRejectedValueOnce(new Error('relay down'));
    const sender = makeSender();
    const result = await sender.send({ deviceToken: 'f'.repeat(64) });
    expect(result).toEqual({ ok: false, status: 0 });
  });

  it('invokes onInvalidToken on 410 Unregistered', async () => {
    mockOhttp.send.mockResolvedValueOnce({ status: 410, body: Buffer.from('{"reason":"Unregistered"}') });
    const onInvalidToken = jest.fn();
    const sender = createSilentApnsSender({
      ohttp: mockOhttp as any,
      apnsUrl,
      jwtProvider: mockJwtProvider,
      topic,
      onInvalidToken,
    });
    const token = 'g'.repeat(64);
    const result = await sender.send({ deviceToken: token });
    expect(result).toEqual({ ok: false, status: 410 });
    expect(onInvalidToken).toHaveBeenCalledWith(token);
  });

  it('rejects attempts to include a custom payload field', async () => {
    const sender = makeSender();
    // TS: typed signature does not accept extra fields. Runtime check for defensive code.
    await sender.send({ deviceToken: 'h'.repeat(64), extra: 'nope' } as any);

    const raw = mockOhttp.send.mock.calls[0][0].body.toString('utf8');
    expect(raw).not.toContain('extra');
    expect(raw).not.toContain('nope');
  });
});
