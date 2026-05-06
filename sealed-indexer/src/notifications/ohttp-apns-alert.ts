/**
 * OHTTP-wrapped visible-alert APNs sender (targeted-push opt-in mode).
 *
 * Sibling of `createSilentApnsSender` for the Push Notifications system. Implements
 * `TargetedSender` from `targeted-fanout.ts`. Differences from the silent
 * sender are intentional and locked under tests:
 *
 *  - `apns-push-type: alert`     (silent uses `background`)
 *  - `apns-priority: 10`         (silent uses 5; alerts must be high-priority
 *                                 or APNs delays/coalesces them)
 *  - Body = `buildApnsBody()`    (frozen `aps.alert` payload, identical bytes
 *                                 for every push; silent uses padded random
 *                                 content-available payload)
 *
 * Same OHTTP envelope, same JWT auth, same `apns-topic`, same 410
 * → unregister wiring.
 */
import type { Logger } from 'pino';
import type { OhttpClient } from './ohttp-client';
import type { ApnsJwtProvider } from './apns-jwt';
import type { TargetedSender, TargetedDispatchArgs } from './targeted-fanout';
import { buildApnsBody, TARGETED_PUSH_BODY } from './targeted-payload';

export interface AlertApnsSenderOptions {
  ohttp: OhttpClient;
  /** Base APNs endpoint, e.g. https://api.push.apple.com/3/device/ */
  apnsUrl: string;
  /** JWT provider for APNs token-based auth. */
  jwtProvider: ApnsJwtProvider;
  /** `apns-topic` header — the app bundle id. */
  topic: string;
  /** Called with the device token when APNs returns 410 (Unregistered). */
  onInvalidToken?: (token: string) => void;
  /** Optional structured logger. Falls back to console when absent (tests). */
  logger?: Logger;
}

export function createAlertApnsSender(opts: AlertApnsSenderOptions): TargetedSender {
  const { ohttp, apnsUrl, jwtProvider, topic, onInvalidToken, logger } = opts;

  return {
    async send(args: TargetedDispatchArgs): Promise<{ ok: boolean; status?: number }> {
      const { deviceToken, body } = args;

      if (!deviceToken || deviceToken.trim() === '') {
        throw new Error('deviceToken must not be empty');
      }
      if (body !== TARGETED_PUSH_BODY) {
        throw new Error(
          'visible-alert APNs body must equal the frozen TARGETED_PUSH_BODY constant',
        );
      }

      const payload = buildApnsBody();
      const tokenPrefix = deviceToken.slice(0, 8);
      const url = `${apnsUrl}${deviceToken}`;
      const t0 = Date.now();

      logger?.debug(
        { tokenPrefix, topic, payloadBytes: payload.length },
        'alert-apns: sending push via OHTTP',
      );

      try {
        const response = await ohttp.send({
          method: 'POST',
          url,
          headers: {
            'apns-push-type': 'alert',
            'apns-priority': '10',
            'apns-topic': topic,
            authorization: `bearer ${jwtProvider.getToken()}`,
            'content-type': 'application/json',
          },
          body: payload,
        });

        const sendMs = Date.now() - t0;

        if (response.status === 410) {
          logger?.warn(
            { tokenPrefix, sendMs, status: 410 },
            'alert-apns: token unregistered (410) — invalidating',
          );
          if (onInvalidToken) {
            onInvalidToken(deviceToken);
          }
          return { ok: false, status: 410 };
        }

        if (response.status >= 200 && response.status < 300) {
          logger?.debug(
            { tokenPrefix, sendMs, status: response.status },
            'alert-apns: push accepted by gateway',
          );
          return { ok: true, status: response.status };
        }

        logger?.warn(
          {
            tokenPrefix,
            sendMs,
            status: response.status,
            bodySnippet: response.body.subarray(0, 256).toString('utf8'),
          },
          'alert-apns: gateway returned non-2xx',
        );
        return { ok: false, status: response.status };
      } catch (err) {
        const sendMs = Date.now() - t0;
        const msg = err instanceof Error ? err.message : String(err);
        if (logger) {
          logger.error(
            { err, tokenPrefix, sendMs, message: msg },
            'alert-apns: ohttp.send threw',
          );
        } else {
          // eslint-disable-next-line no-console
          console.warn('[alert-apns] ohttp.send threw:', msg);
        }
        return { ok: false, status: 0 };
      }
    },
  };
}
