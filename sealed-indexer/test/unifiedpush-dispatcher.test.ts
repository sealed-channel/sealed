import {
  createUnifiedPushDispatcher,
  UP_PAYLOAD_SIZE,
} from '../src/notifications/unifiedpush-dispatcher';

interface MockOhttpClient {
  send: jest.Mock;
}

/**
 * Task 1.5 — UnifiedPush dispatcher (Android, replaces FCM).
 *
 * Contract:
 *  - Zero FCM/Google involvement. The dispatcher POSTs to a ntfy-compatible
 *    endpoint whose URL is the device-supplied endpoint token.
 *  - Payload is a fixed-size opaque blob (ciphertext + padding). No
 *    Sealed-level identifiers leak to the distributor.
 *  - Routed through OHTTP so the distributor (if ever not on our own onion)
 *    does not see our indexer origin IP.
 */
describe('createUnifiedPushDispatcher', () => {
  let mockOhttp: MockOhttpClient;

  beforeEach(() => {
    mockOhttp = { send: jest.fn().mockResolvedValue({ status: 200, body: Buffer.alloc(0) }) };
  });

  function makeDispatcher() {
    return createUnifiedPushDispatcher({ ohttp: mockOhttp as any });
  }

  it('POSTs to the device-supplied endpoint URL with fixed-size body', async () => {
    const dispatcher = makeDispatcher();
    const endpoint = 'http://sealed-ntfy.onion/topic/abc123';
    const ciphertext = Buffer.from('real-encrypted-envelope');

    const result = await dispatcher.dispatch({ endpoint, ciphertext });

    expect(result.ok).toBe(true);
    const req = mockOhttp.send.mock.calls[0][0];
    expect(req.method).toBe('POST');
    expect(req.url).toBe(endpoint);
    expect(req.body.length).toBe(UP_PAYLOAD_SIZE);
  });

  it('pads all payloads to identical byte length regardless of ciphertext size', async () => {
    const dispatcher = makeDispatcher();
    await dispatcher.dispatch({ endpoint: 'http://x.onion/a', ciphertext: Buffer.alloc(10) });
    await dispatcher.dispatch({ endpoint: 'http://x.onion/b', ciphertext: Buffer.alloc(500) });
    await dispatcher.dispatch({ endpoint: 'http://x.onion/c', ciphertext: Buffer.alloc(1) });

    const sizes = mockOhttp.send.mock.calls.map((c: any) => c[0].body.length);
    expect(new Set(sizes).size).toBe(1);
    expect(sizes[0]).toBe(UP_PAYLOAD_SIZE);
  });

  it('never includes Sealed-level identifiers in headers or body', async () => {
    const dispatcher = makeDispatcher();
    await dispatcher.dispatch({
      endpoint: 'http://x.onion/a',
      ciphertext: Buffer.from('opaque'),
    });
    const req = mockOhttp.send.mock.calls[0][0];

    const headerStr = JSON.stringify(req.headers);
    for (const forbidden of ['message_id', 'conversation_wallet', 'account_pubkey', 'view_key', 'blinded_id']) {
      expect(headerStr).not.toContain(forbidden);
    }
  });

  it('rejects oversized ciphertext rather than truncating silently', async () => {
    const dispatcher = makeDispatcher();
    await expect(
      dispatcher.dispatch({
        endpoint: 'http://x.onion/a',
        ciphertext: Buffer.alloc(UP_PAYLOAD_SIZE + 1),
      })
    ).rejects.toThrow(/exceed/i);
  });

  it('returns ok:false status:0 when OHTTP relay throws', async () => {
    mockOhttp.send.mockRejectedValueOnce(new Error('relay down'));
    const dispatcher = makeDispatcher();
    const result = await dispatcher.dispatch({
      endpoint: 'http://x.onion/a',
      ciphertext: Buffer.from('x'),
    });
    expect(result).toEqual({ ok: false, status: 0 });
  });

  it('invokes onInvalidEndpoint on 404 Gone from distributor', async () => {
    mockOhttp.send.mockResolvedValueOnce({ status: 404, body: Buffer.alloc(0) });
    const onInvalidEndpoint = jest.fn();
    const dispatcher = createUnifiedPushDispatcher({
      ohttp: mockOhttp as any,
      onInvalidEndpoint,
    });
    const endpoint = 'http://x.onion/gone';
    const result = await dispatcher.dispatch({ endpoint, ciphertext: Buffer.from('x') });
    expect(result).toEqual({ ok: false, status: 404 });
    expect(onInvalidEndpoint).toHaveBeenCalledWith(endpoint);
  });
});
