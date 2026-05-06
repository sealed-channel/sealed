/**
 * Constant-text visible-alert push payloads for the Push Notifications system.
 *
 * Privacy contract (locked, enforced by tests):
 *  - Body text is the constant string "You got a new encrypted message".
 *    NO sender, message id, ciphertext, or chain metadata is ever included.
 *  - No silent push, no data-only message: a visible alert is the entire
 *    point — silent paths get throttled by iOS / killed by Android OEMs.
 *  - The exact payload bytes for both iOS and Android are constants, so
 *    Apple/Google see indistinguishable per-message wakeups.
 *
 * The string MUST stay byte-exact across server, iOS app, and Android app.
 * Production tests assert payload immutability so an accidental edit fails
 * loudly in CI.
 */

export const TARGETED_PUSH_BODY = 'You got a new encrypted message';

/**
 * APNs alert payload (visible). `mutable-content: 1` is intentionally absent:
 * we DO NOT want notification-service-extensions decrypting anything in the
 * push provider's environment. The app handles content locally on tap.
 */
export const TARGETED_APNS_PAYLOAD: Readonly<{
  aps: { alert: { body: string }; sound: string };
}> = Object.freeze({
  aps: Object.freeze({
    alert: Object.freeze({ body: TARGETED_PUSH_BODY }),
    sound: 'default',
  }),
}) as never;

/**
 * FCM HTTP v1 message body (`notification` key, NOT `data`). Using `notification`
 * forces FCM to render a system-tray entry even when the app is killed, which
 * is the whole point.
 */
export const TARGETED_FCM_NOTIFICATION: Readonly<{ title: string; body: string }> =
  Object.freeze({
    title: 'Sealed',
    body: TARGETED_PUSH_BODY,
  });

/**
 * Build the JSON-serialized FCM v1 message body for a single token. Because
 * `TARGETED_FCM_NOTIFICATION` is the only content, the resulting bytes are
 * identical for every recipient except the `token` field.
 */
export function buildFcmMessageBody(token: string): string {
  if (!token || token.trim() === '') {
    throw new Error('FCM token must not be empty');
  }
  return JSON.stringify({
    message: {
      token,
      notification: TARGETED_FCM_NOTIFICATION,
    },
  });
}

/**
 * Serialize the APNs visible-alert payload. Identical bytes for every push.
 */
export function buildApnsBody(): Buffer {
  return Buffer.from(JSON.stringify(TARGETED_APNS_PAYLOAD), 'utf8');
}
