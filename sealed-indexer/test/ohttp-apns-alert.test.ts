/**
 * Task 1 follow-up — OHTTP-wrapped visible-alert APNs sender.
 *
 * Sibling of `createSilentApnsSender`, but emits `apns-push-type: alert` with
 * priority 10 and the frozen `TARGETED_APNS_PAYLOAD` body. Used exclusively
 * by the targeted-push fanout (opt-in mode). The silent sender stays
 * untouched.
 *
 * Privacy contract enforced here:
 *  - Body bytes are exactly `buildApnsBody()` (the frozen aps.alert payload)
 *    — no per-recipient content, no Sealed-level identifiers ever.
 *  - Headers are `apns-push-type: alert` and `apns-priority: 10` — visible
 *    alerts must be high-priority or APNs throttles them.
 *  - Routed through OHTTP so Apple does not see the indexer's origin IP.
 *  - 410 Unregistered triggers the unregister callback.
 */
import { createAlertApnsSender } from '../src/notifications/ohttp-apns-alert';
import { buildApnsBody, TARGETED_PUSH_BODY } from '../src/notifications/targeted-payload';
import type { ApnsJwtProvider } from '../src/notifications/apns-jwt';

interface MockOhttpClient {
  send: jest.Mock;
}

describe('createAlertApnsSender', () => {
  let mockOhttp: MockOhttpClient;
  let mockJwtProvider: ApnsJwtProvider;
  const apnsUrl = 'https://api.push.apple.com/3/device/';
  const topic = 'com.example.sealed';

  beforeEach(() => {
    mockOhttp = { send: jest.fn().mockResolvedValue({ status: 200, body: Buffer.alloc(0) }) };
    mockJwtProvider = { getToken: jest.fn().mockReturnValue('fake.jwt.token') };
  });

  function makeSender(onInvalidToken?: (token: string) => void) {
    return createAlertApnsSender({
      ohttp: mockOhttp as never,
      apnsUrl,
      jwtProvider: mockJwtProvider,
      topic,
      onInvalidToken,
    });
  }

  it('sends a visible alert with apns-push-type=alert and apns-priority=10', async () => {
    const sender = makeSender();
    await sender.send({
      deviceToken: 'a'.repeat(64),
      body: TARGETED_PUSH_BODY,
      platform: 'ios',
    });

    const req = mockOhttp.send.mock.calls[0][0];
    expect(req.method).toBe('POST');
    expect(req.url).toBe(`${apnsUrl}${'a'.repeat(64)}`);
    expect(req.headers['apns-push-type']).toBe('alert');
    expect(req.headers['apns-priority']).toBe('10');
    expect(req.headers['apns-topic']).toBe(topic);
    expect(req.headers['authorization']).toBe('bearer fake.jwt.token');
    expect(req.headers['content-type']).toBe('application/json');
  });

  it('body bytes are exactly buildApnsBody() — frozen, identical for every push', async () => {
    const sender = makeSender();
    await sender.send({
      deviceToken: 'b'.repeat(64),
      body: TARGETED_PUSH_BODY,
      platform: 'ios',
    });
    await sender.send({
      deviceToken: 'c'.repeat(64),
      body: TARGETED_PUSH_BODY,
      platform: 'ios',
    });

    const expected = buildApnsBody();
    const bodies = mockOhttp.send.mock.calls.map((c: never[]) => (c[0] as { body: Buffer }).body);
    for (const body of bodies) {
      expect(Buffer.isBuffer(body)).toBe(true);
      expect(body.equals(expected)).toBe(true);
    }
  });

  it('NEVER includes per-recipient content or Sealed-level identifiers', async () => {
    const sender = makeSender();
    await sender.send({
      deviceToken: 'd'.repeat(64),
      body: TARGETED_PUSH_BODY,
      platform: 'ios',
    });

    const req = mockOhttp.send.mock.calls[0][0];
    const raw = req.body.toString('utf8');

    for (const forbidden of [
      'message_id',
      'conversation_wallet',
      'account_pubkey',
      'view_key',
      'view_priv',
      'blinded_id',
      'enc_token',
      'content-available',
      'mutable-content',
    ]) {
      expect(raw).not.toContain(forbidden);
    }
  });

  it('refuses to emit a body that does not match the frozen TARGETED_PUSH_BODY', async () => {
    const sender = makeSender();
    await expect(
      sender.send({
        deviceToken: 'e'.repeat(64),
        body: 'a different body',
        platform: 'ios',
      }),
    ).rejects.toThrow(/frozen/i);
    expect(mockOhttp.send).not.toHaveBeenCalled();
  });

  it('returns ok:false with status 0 when OHTTP relay throws', async () => {
    mockOhttp.send.mockRejectedValueOnce(new Error('relay down'));
    const sender = makeSender();
    const result = await sender.send({
      deviceToken: 'f'.repeat(64),
      body: TARGETED_PUSH_BODY,
      platform: 'ios',
    });
    expect(result).toEqual({ ok: false, status: 0 });
  });

  it('invokes onInvalidToken on 410 Unregistered', async () => {
    mockOhttp.send.mockResolvedValueOnce({
      status: 410,
      body: Buffer.from('{"reason":"Unregistered"}'),
    });
    const onInvalidToken = jest.fn();
    const sender = makeSender(onInvalidToken);
    const token = 'g'.repeat(64);

    const result = await sender.send({
      deviceToken: token,
      body: TARGETED_PUSH_BODY,
      platform: 'ios',
    });

    expect(result).toEqual({ ok: false, status: 410 });
    expect(onInvalidToken).toHaveBeenCalledWith(token);
  });

  it('returns ok:true on 2xx and ok:false on other 4xx/5xx', async () => {
    mockOhttp.send
      .mockResolvedValueOnce({ status: 200, body: Buffer.alloc(0) })
      .mockResolvedValueOnce({ status: 400, body: Buffer.alloc(0) })
      .mockResolvedValueOnce({ status: 503, body: Buffer.alloc(0) });

    const sender = makeSender();

    const a = await sender.send({
      deviceToken: 'h'.repeat(64),
      body: TARGETED_PUSH_BODY,
      platform: 'ios',
    });
    const b = await sender.send({
      deviceToken: 'i'.repeat(64),
      body: TARGETED_PUSH_BODY,
      platform: 'ios',
    });
    const c = await sender.send({
      deviceToken: 'j'.repeat(64),
      body: TARGETED_PUSH_BODY,
      platform: 'ios',
    });

    expect(a).toEqual({ ok: true, status: 200 });
    expect(b).toEqual({ ok: false, status: 400 });
    expect(c).toEqual({ ok: false, status: 503 });
  });

  it('rejects empty deviceToken without making an OHTTP request', async () => {
    const sender = makeSender();
    await expect(
      sender.send({
        deviceToken: '',
        body: TARGETED_PUSH_BODY,
        platform: 'ios',
      }),
    ).rejects.toThrow(/deviceToken/);
    expect(mockOhttp.send).not.toHaveBeenCalled();
  });
});
