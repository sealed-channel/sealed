import { buildNotificationPayload, NotificationData } from '../src/notifications/payload';

describe('buildNotificationPayload', () => {
  const validData: NotificationData = {
    message_id: 'msg_123',
    conversation_wallet: 'wallet_456',
    account_pubkey: 'pubkey_789'
  };

  it('builds payload with exact title and body for Android', () => {
    const payload = buildNotificationPayload('android', 'token_123', validData);

    expect(payload.message.notification.title).toBe('New Encrypted Message');
    expect(payload.message.notification.body).toBe('You have a new message.');
    expect(payload.message.token).toBe('token_123');
    expect(payload.message.data).toEqual({
      message_id: 'msg_123',
      conversation_wallet: 'wallet_456',
      account_pubkey: 'pubkey_789'
    });
  });

  it('builds payload with exact title and body for iOS', () => {
    const payload = buildNotificationPayload('ios', 'token_456', validData);

    expect(payload.message.notification.title).toBe('New Encrypted Message');
    expect(payload.message.notification.body).toBe('You have a new message.');
    expect(payload.message.token).toBe('token_456');
    expect(payload.message.data).toEqual({
      message_id: 'msg_123',
      conversation_wallet: 'wallet_456',
      account_pubkey: 'pubkey_789'
    });
  });

  it('D4 guard test: rejects extra keys via allowlist', () => {
    const badData = {
      message_id: 'msg_123',
      conversation_wallet: 'wallet_456',
      account_pubkey: 'pubkey_789',
      secret: 'should_not_appear',
      note: 'algorand_note_bytes'
    };

    // TypeScript should catch this at compile time, but we test runtime protection too
    const payload = buildNotificationPayload('android', 'token', badData as any);

    // Implementation must use allowlist - only the three whitelist keys should appear
    expect(Object.keys(payload.message.data)).toEqual([
      'message_id',
      'conversation_wallet',
      'account_pubkey'
    ]);
    expect(payload.message.data).not.toHaveProperty('secret');
    expect(payload.message.data).not.toHaveProperty('note');
  });

  it('produces deterministic JSON output', () => {
    const payload1 = buildNotificationPayload('android', 'token', validData);
    const payload2 = buildNotificationPayload('android', 'token', validData);

    expect(JSON.stringify(payload1)).toBe(JSON.stringify(payload2));
  });

  it('matches snapshot for iOS platform', () => {
    const payload = buildNotificationPayload('ios', 'test_token', validData);

    expect(payload).toMatchSnapshot();
  });

  it('matches snapshot for Android platform', () => {
    const payload = buildNotificationPayload('android', 'test_token', validData);

    expect(payload).toMatchSnapshot();
  });

  it('iOS and Android have identical notification content', () => {
    const iosPayload = buildNotificationPayload('ios', 'token', validData);
    const androidPayload = buildNotificationPayload('android', 'token', validData);

    expect(iosPayload.message.notification).toEqual(androidPayload.message.notification);
  });
});