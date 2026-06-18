/**
 * Tests for OHTTP-wrapped FCM HTTP v1 visible-alert sender.
 *
 * Contract:
 *  - POSTs to https://fcm.googleapis.com/v1/projects/<id>/messages:send via OHTTP.
 *  - Body bytes are exactly buildFcmMessageBody(deviceToken).
 *  - Bearer token comes from the OAuth2 service-account provider.
 *  - 404 / UNREGISTERED triggers the unregister callback.
 *  - Refuses bodies that don't equal TARGETED_PUSH_BODY.
 *  - Refuses empty deviceToken before touching the relay.
 */
import { createOhttpFcmSender } from '../src/notifications/ohttp-fcm';
import { buildFcmMessageBody, TARGETED_PUSH_BODY } from '../src/notifications/targeted-payload';
import type { FcmAccessTokenProvider } from '../src/notifications/fcm-oauth';

interface MockOhttpClient {
  send: jest.Mock;
}

const PROJECT_ID = 'sealed-test-project';

describe('createOhttpFcmSender', () => {
  let mockOhttp: MockOhttpClient;
  let mockTokens: FcmAccessTokenProvider;

  beforeEach(() => {
    mockOhttp = { send: jest.fn().mockResolvedValue({ status: 200, body: Buffer.from('{}') }) };
    mockTokens = { getAccessToken: jest.fn().mockResolvedValue('access-token-xyz') };
  });

  function makeSender(onInvalidToken?: (token: string) => void) {
    return createOhttpFcmSender({
      ohttp: mockOhttp as never,
      projectId: PROJECT_ID,
      accessTokenProvider: mockTokens,
      onInvalidToken,
    });
  }

  it('posts to /v1/projects/<id>/messages:send with the OAuth bearer token', async () => {
    const sender = makeSender();
    await sender.send({
      deviceToken: 'fcm-token-aaa',
      body: TARGETED_PUSH_BODY,
      platform: 'android',
    });

    const req = mockOhttp.send.mock.calls[0][0];
    expect(req.method).toBe('POST');
    expect(req.url).toBe(
      `https://fcm.googleapis.com/v1/projects/${PROJECT_ID}/messages:send`,
    );
    expect(req.headers.authorization).toBe('Bearer access-token-xyz');
    expect(req.headers['content-type']).toBe('application/json');
  });

  it('body equals buildFcmMessageBody(deviceToken) — frozen notification block', async () => {
    const sender = makeSender();
    await sender.send({
      deviceToken: 'fcm-token-bbb',
      body: TARGETED_PUSH_BODY,
      platform: 'android',
    });

    const req = mockOhttp.send.mock.calls[0][0];
    const expected = Buffer.from(buildFcmMessageBody('fcm-token-bbb'), 'utf8');
    expect(Buffer.isBuffer(req.body)).toBe(true);
    expect(req.body.equals(expected)).toBe(true);

    // Sanity: body contains the frozen notification block + token, and nothing else.
    const parsed = JSON.parse(req.body.toString('utf8'));
    expect(parsed).toEqual({
      message: {
        token: 'fcm-token-bbb',
        notification: { title: 'Sealed', body: TARGETED_PUSH_BODY },
      },
    });
    expect(parsed.message).not.toHaveProperty('data');
    expect(parsed.message).not.toHaveProperty('android');
    expect(parsed.message).not.toHaveProperty('apns');
  });

  it('refuses to emit a body that does not match the frozen TARGETED_PUSH_BODY', async () => {
    const sender = makeSender();
    await expect(
      sender.send({
        deviceToken: 'fcm-token-ccc',
        body: 'a different body',
        platform: 'android',
      }),
    ).rejects.toThrow(/frozen/i);
    expect(mockOhttp.send).not.toHaveBeenCalled();
  });

  it('rejects empty deviceToken without making a request', async () => {
    const sender = makeSender();
    await expect(
      sender.send({
        deviceToken: '',
        body: TARGETED_PUSH_BODY,
        platform: 'android',
      }),
    ).rejects.toThrow(/deviceToken/);
    expect(mockOhttp.send).not.toHaveBeenCalled();
  });

  it('returns ok:true on 2xx', async () => {
    mockOhttp.send.mockResolvedValueOnce({ status: 200, body: Buffer.from('{}') });
    const sender = makeSender();
    const result = await sender.send({
      deviceToken: 'fcm-token-ok',
      body: TARGETED_PUSH_BODY,
      platform: 'android',
    });
    expect(result).toEqual({ ok: true, status: 200 });
  });

  it('invokes onInvalidToken on 404 UNREGISTERED', async () => {
    mockOhttp.send.mockResolvedValueOnce({
      status: 404,
      body: Buffer.from(
        JSON.stringify({
          error: {
            code: 404,
            message: 'Requested entity was not found.',
            status: 'NOT_FOUND',
            details: [
              {
                '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError',
                errorCode: 'UNREGISTERED',
              },
            ],
          },
        }),
      ),
    });

    const onInvalidToken = jest.fn();
    const sender = makeSender(onInvalidToken);
    const result = await sender.send({
      deviceToken: 'fcm-token-dead',
      body: TARGETED_PUSH_BODY,
      platform: 'android',
    });

    expect(result).toEqual({ ok: false, status: 404 });
    expect(onInvalidToken).toHaveBeenCalledWith('fcm-token-dead');
  });

  it('does NOT invoke onInvalidToken on 5xx server errors', async () => {
    mockOhttp.send.mockResolvedValueOnce({ status: 503, body: Buffer.from('{}') });
    const onInvalidToken = jest.fn();
    const sender = makeSender(onInvalidToken);
    const result = await sender.send({
      deviceToken: 'fcm-token-eee',
      body: TARGETED_PUSH_BODY,
      platform: 'android',
    });
    expect(result).toEqual({ ok: false, status: 503 });
    expect(onInvalidToken).not.toHaveBeenCalled();
  });

  it('returns ok:false status:0 when OHTTP relay throws', async () => {
    mockOhttp.send.mockRejectedValueOnce(new Error('relay down'));
    const sender = makeSender();
    const result = await sender.send({
      deviceToken: 'fcm-token-fff',
      body: TARGETED_PUSH_BODY,
      platform: 'android',
    });
    expect(result).toEqual({ ok: false, status: 0 });
  });

  it('returns ok:false status:0 when the access-token provider throws', async () => {
    mockTokens.getAccessToken = jest.fn().mockRejectedValueOnce(new Error('oauth down'));
    const sender = makeSender();
    const result = await sender.send({
      deviceToken: 'fcm-token-ggg',
      body: TARGETED_PUSH_BODY,
      platform: 'android',
    });
    expect(result).toEqual({ ok: false, status: 0 });
    expect(mockOhttp.send).not.toHaveBeenCalled();
  });

  it('rejects construction with empty projectId', () => {
    expect(() =>
      createOhttpFcmSender({
        ohttp: mockOhttp as never,
        projectId: '',
        accessTokenProvider: mockTokens,
      }),
    ).toThrow();
  });
});
