/**
 * Push notification sender that routes FCM/APNs through OHTTP relay.
 */

import { buildNotificationPayload, NotificationData } from './payload';
import type { OhttpClient } from './ohttp-client';

export interface PushSender {
  send(args: {
    token: string;
    platform: 'ios' | 'android';
    data: NotificationData;
  }): Promise<{ ok: boolean; status: number }>;
}

export interface PushSenderOptions {
  ohttp: OhttpClient;
  fcmProjectUrl: string;
  onInvalidToken?: (token: string) => void;
}

/**
 * Creates a push sender that uses OHTTP to send FCM notifications.
 * APNs routing is handled through FCM - no separate APNs endpoint.
 */
export function createPushSender(opts: PushSenderOptions): PushSender {
  const { ohttp, fcmProjectUrl, onInvalidToken } = opts;

  return {
    async send({ token, platform, data }) {
      try {
        // Build the canonical FCM payload
        const payload = buildNotificationPayload(platform, token, data);
        const body = Buffer.from(JSON.stringify(payload));

        // Send via OHTTP relay
        const response = await ohttp.send({
          method: 'POST',
          url: fcmProjectUrl,
          headers: {
            'Content-Type': 'application/json'
          },
          body
        });

        // Handle FCM error responses
        if (response.status === 404 || response.status === 400) {
          // Check if it's an UNREGISTERED token error
          try {
            const errorBody = JSON.parse(response.body.toString());
            const isUnregistered = errorBody?.error?.details?.some(
              (detail: any) => detail.errorCode === 'UNREGISTERED'
            );

            if (isUnregistered && onInvalidToken) {
              // Log invalid token removal
              console.warn(`Invalid FCM token detected: ${token}`);
              onInvalidToken(token);
            }
          } catch {
            // Ignore JSON parsing errors in error responses
          }

          return { ok: false, status: response.status };
        }

        // Success for 2xx responses
        if (response.status >= 200 && response.status < 300) {
          return { ok: true, status: response.status };
        }

        // Other error status codes
        return { ok: false, status: response.status };

      } catch (error) {
        // OHTTP relay down or other network error
        return { ok: false, status: 0 };
      }
    }
  };
}