import { createPushSender } from '../src/notifications/push-sender';
import { NotificationData } from '../src/notifications/payload';

// Mock OhttpClient interface
interface MockOhttpClient {
  send: jest.Mock;
}

describe('createPushSender', () => {
  let mockOhttp: MockOhttpClient;
  let mockOnInvalidToken: jest.Mock;
  const fcmProjectUrl = 'https://fcm.googleapis.com/v1/projects/test-project/messages:send';

  beforeEach(() => {
    mockOhttp = {
      send: jest.fn()
    };
    mockOnInvalidToken = jest.fn();
  });

  const validData: NotificationData = {
    message_id: 'msg_123',
    conversation_wallet: 'wallet_456',
    account_pubkey: 'pubkey_789'
  };

  it('happy path: sends notification via OHTTP and returns success', async () => {
    // Mock successful OHTTP response
    mockOhttp.send.mockResolvedValue({
      status: 200,
      body: Buffer.from(JSON.stringify({ name: 'projects/test/messages/123' }))
    });

    const sender = createPushSender({
      ohttp: mockOhttp,
      fcmProjectUrl,
      onInvalidToken: mockOnInvalidToken
    });

    const result = await sender.send({
      token: 'valid_token',
      platform: 'android',
      data: validData
    });

    // Verify success result
    expect(result).toEqual({ ok: true, status: 200 });

    // Verify OHTTP call
    expect(mockOhttp.send).toHaveBeenCalledTimes(1);
    const call = mockOhttp.send.mock.calls[0][0];

    expect(call.method).toBe('POST');
    expect(call.url).toBe(fcmProjectUrl);
    expect(call.headers).toEqual({
      'Content-Type': 'application/json'
    });

    // Verify payload structure
    const bodyStr = call.body.toString();
    const parsedBody = JSON.parse(bodyStr);

    expect(parsedBody.message.token).toBe('valid_token');
    expect(parsedBody.message.notification.title).toBe('New Encrypted Message');
    expect(parsedBody.message.notification.body).toBe('You have a new message.');
    expect(parsedBody.message.data).toEqual(validData);

    expect(mockOnInvalidToken).not.toHaveBeenCalled();
  });

  it('handles UNREGISTERED token error and calls onInvalidToken', async () => {
    // Mock FCM UNREGISTERED error response
    mockOhttp.send.mockResolvedValue({
      status: 404,
      body: Buffer.from(JSON.stringify({
        error: {
          details: [{
            errorCode: 'UNREGISTERED'
          }]
        }
      }))
    });

    const sender = createPushSender({
      ohttp: mockOhttp,
      fcmProjectUrl,
      onInvalidToken: mockOnInvalidToken
    });

    const result = await sender.send({
      token: 'invalid_token',
      platform: 'ios',
      data: validData
    });

    expect(result).toEqual({ ok: false, status: 404 });
    expect(mockOnInvalidToken).toHaveBeenCalledWith('invalid_token');
  });

  it('handles OHTTP relay down gracefully', async () => {
    // Mock OHTTP client throwing (relay down)
    mockOhttp.send.mockRejectedValue(new Error('Network error'));

    const sender = createPushSender({
      ohttp: mockOhttp,
      fcmProjectUrl,
      onInvalidToken: mockOnInvalidToken
    });

    const result = await sender.send({
      token: 'some_token',
      platform: 'android',
      data: validData
    });

    expect(result).toEqual({ ok: false, status: 0 });
    expect(mockOnInvalidToken).not.toHaveBeenCalled();
  });

  it('prevents secret data leakage via allowlist protection', async () => {
    mockOhttp.send.mockResolvedValue({
      status: 200,
      body: Buffer.from('{}')
    });

    const sender = createPushSender({
      ohttp: mockOhttp,
      fcmProjectUrl
    });

    // Try to slip in extra data
    const maliciousData = {
      ...validData,
      secret: 'should_not_appear',
      note: 'algorand_bytes'
    } as any;

    await sender.send({
      token: 'token',
      platform: 'android',
      data: maliciousData
    });

    const call = mockOhttp.send.mock.calls[0][0];
    const bodyStr = call.body.toString();

    // Body must NOT contain the secret data
    expect(bodyStr).not.toContain('should_not_appear');
    expect(bodyStr).not.toContain('algorand_bytes');
    expect(bodyStr).not.toContain('secret');
    expect(bodyStr).not.toContain('note');

    // Should only contain whitelisted keys
    const parsedBody = JSON.parse(bodyStr);
    expect(Object.keys(parsedBody.message.data)).toEqual([
      'message_id',
      'conversation_wallet',
      'account_pubkey'
    ]);
  });
});