/**
 * Tests for the targeted-push payload constants. The body text and payload
 * shapes are part of Sealed's privacy contract — any change that drops
 * `TARGETED_PUSH_BODY`, adds a `data` field, or flips iOS to silent mode
 * must fail loudly.
 */
import {
  TARGETED_PUSH_BODY,
  TARGETED_APNS_PAYLOAD,
  TARGETED_FCM_NOTIFICATION,
  buildApnsBody,
  buildFcmMessageBody,
} from '../src/notifications/targeted-payload';

describe('targeted-payload immutability', () => {
  it('exposes the exact constant body string', () => {
    expect(TARGETED_PUSH_BODY).toBe('You got a new encrypted message');
  });

  it('APNs payload is a visible alert with no silent flags', () => {
    expect(TARGETED_APNS_PAYLOAD).toEqual({
      aps: { alert: { body: TARGETED_PUSH_BODY }, sound: 'default' },
    });
    const aps = TARGETED_APNS_PAYLOAD.aps as Record<string, unknown>;
    expect(aps['content-available']).toBeUndefined();
    expect(aps['mutable-content']).toBeUndefined();
  });

  it('APNs payload is deeply frozen', () => {
    expect(Object.isFrozen(TARGETED_APNS_PAYLOAD)).toBe(true);
    expect(Object.isFrozen(TARGETED_APNS_PAYLOAD.aps)).toBe(true);
    expect(Object.isFrozen(TARGETED_APNS_PAYLOAD.aps.alert)).toBe(true);
    expect(() => {
      // Frozen object — assignment must throw in strict mode (jest/ts-jest).
      (TARGETED_APNS_PAYLOAD as { aps: { alert: { body: string } } }).aps.alert.body =
        'attacker injected';
    }).toThrow();
  });

  it('FCM notification is the constant title+body, no data dictionary', () => {
    expect(TARGETED_FCM_NOTIFICATION).toEqual({
      title: 'Sealed',
      body: TARGETED_PUSH_BODY,
    });
    expect(Object.isFrozen(TARGETED_FCM_NOTIFICATION)).toBe(true);
  });

  it('buildApnsBody returns the exact serialized JSON', () => {
    const expected = JSON.stringify({
      aps: { alert: { body: TARGETED_PUSH_BODY }, sound: 'default' },
    });
    expect(buildApnsBody().toString('utf8')).toBe(expected);
  });

  it('buildFcmMessageBody embeds only token + notification — no data field', () => {
    const body = buildFcmMessageBody('abc123');
    const parsed = JSON.parse(body);
    expect(parsed).toEqual({
      message: {
        token: 'abc123',
        notification: { title: 'Sealed', body: TARGETED_PUSH_BODY },
      },
    });
    expect(parsed.message.data).toBeUndefined();
  });

  it('buildFcmMessageBody rejects empty tokens', () => {
    expect(() => buildFcmMessageBody('')).toThrow();
    expect(() => buildFcmMessageBody('  ')).toThrow();
  });
});
