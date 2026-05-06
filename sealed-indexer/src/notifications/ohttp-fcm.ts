/**
 * OHTTP-wrapped FCM HTTP v1 visible-alert sender (targeted-push opt-in mode).
 *
 * Implements `TargetedSender` for Android. Posts to FCM HTTP v1
 * (`/v1/projects/<id>/messages:send`) through the OHTTP relay so Google does
 * not see the indexer's origin IP — only that *some* OHTTP relay client is
 * delivering pushes for project X.
 *
 * Privacy contract enforced here:
 *  - Body bytes are exactly `buildFcmMessageBody(token)` — the frozen
 *    `notification` block + `token`. No `data` block. No per-event metadata.
 *  - Uses raw `fetch` + `jsonwebtoken` for OAuth2 — no firebase-admin, no
 *    @google-cloud/* (see test/no-google-sdk.test.ts).
 *  - 404 / UNREGISTERED responses trigger the unregister callback so dead
 *    Android tokens are pruned.
 */
import type { Logger } from 'pino';
import type { OhttpClient } from './ohttp-client';
import type { FcmAccessTokenProvider } from './fcm-oauth';
import type { TargetedSender, TargetedDispatchArgs } from './targeted-fanout';
import { buildFcmMessageBody, TARGETED_PUSH_BODY } from './targeted-payload';

export interface OhttpFcmSenderOptions {
  ohttp: OhttpClient;
  /** Google project id used in the FCM v1 URL path. */
  projectId: string;
  /** OAuth2 access-token provider (service-account JWT exchange). */
  accessTokenProvider: FcmAccessTokenProvider;
  /** Called with the device token when FCM returns 404 / UNREGISTERED. */
  onInvalidToken?: (token: string) => void;
  /** Override the FCM endpoint base (default: googleapis). */
  endpointBase?: string;
  /** Optional structured logger. Falls back to silent when absent (tests). */
  logger?: Logger;
}

const DEFAULT_FCM_BASE = 'https://fcm.googleapis.com';

interface FcmErrorResponse {
  error?: {
    code?: number;
    message?: string;
    status?: string;
    details?: Array<{ errorCode?: string }>;
  };
}

/**
 * Detect FCM's "this token is dead" condition. Per the v1 API, a 404 with
 * `error.details[].errorCode === 'UNREGISTERED'` (or the legacy `status:
 * NOT_FOUND` / `UNREGISTERED`) indicates the app instance is gone and the
 * token must be removed from the server's registration store.
 */
function isUnregistered(status: number, body: Buffer): boolean {
  if (status !== 404) return false;
  try {
    const parsed = JSON.parse(body.toString('utf8')) as FcmErrorResponse;
    const err = parsed.error ?? {};
    if (err.status === 'NOT_FOUND' || err.status === 'UNREGISTERED') return true;
    if (Array.isArray(err.details)) {
      for (const d of err.details) {
        if (d?.errorCode === 'UNREGISTERED') return true;
      }
    }
    return true; // bare 404 from FCM v1 — treat as unregistered conservatively
  } catch {
    return true;
  }
}

export function createOhttpFcmSender(opts: OhttpFcmSenderOptions): TargetedSender {
  const { ohttp, projectId, accessTokenProvider, onInvalidToken, logger } = opts;
  const endpointBase = opts.endpointBase ?? DEFAULT_FCM_BASE;

  if (!projectId || projectId.trim() === '') {
    throw new Error('FCM projectId must not be empty');
  }

  const url = `${endpointBase}/v1/projects/${projectId}/messages:send`;

  return {
    async send(args: TargetedDispatchArgs): Promise<{ ok: boolean; status?: number }> {
      const { deviceToken, body } = args;

      if (!deviceToken || deviceToken.trim() === '') {
        throw new Error('deviceToken must not be empty');
      }
      if (body !== TARGETED_PUSH_BODY) {
        throw new Error(
          'visible-alert FCM body must equal the frozen TARGETED_PUSH_BODY constant',
        );
      }

      const tokenPrefix = deviceToken.slice(0, 8);

      let accessToken: string;
      try {
        accessToken = await accessTokenProvider.getAccessToken();
      } catch (err) {
        logger?.error(
          { err, tokenPrefix, projectId },
          'ohttp-fcm: failed to obtain OAuth2 access token',
        );
        return { ok: false, status: 0 };
      }

      const payload = Buffer.from(buildFcmMessageBody(deviceToken), 'utf8');
      const t0 = Date.now();

      logger?.debug(
        { tokenPrefix, projectId, payloadBytes: payload.length },
        'ohttp-fcm: sending push via OHTTP',
      );

      try {
       const useDirect = process.env.BYPASS_OHTTP_FOR_PUSH === '1';
          let response: { status: number; body: Buffer };
          if (useDirect) {                               
            const direct = await fetch(url, {
              method: 'POST',
              headers: {                                                                   
                authorization: `Bearer ${accessToken}`,
                'content-type': 'application/json',                                        
              },                                                                   
              body: payload,
            });
            response = {
              status: direct.status,
              body: Buffer.from(await direct.arrayBuffer()),
            };
          } else {
            response = await ohttp.send({
              method: 'POST',
              url,
              headers: {
                authorization: `Bearer ${accessToken}`,
                'content-type': 'application/json',
              },
              body: payload,
            });
          }


        const sendMs = Date.now() - t0;

        if (isUnregistered(response.status, response.body)) {
          logger?.warn(
            { tokenPrefix, sendMs, status: response.status },
            'ohttp-fcm: token unregistered — invalidating',
          );
          if (onInvalidToken) {
            onInvalidToken(deviceToken);
          }
          return { ok: false, status: response.status };
        }

        if (response.status >= 200 && response.status < 300) {
          logger?.debug(
            { tokenPrefix, sendMs, status: response.status },
            'ohttp-fcm: push accepted by FCM',
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
          'ohttp-fcm: FCM returned non-2xx',
        );
        return { ok: false, status: response.status };
      } catch (err) {
        const sendMs = Date.now() - t0;
        logger?.error(
          { err, tokenPrefix, sendMs, projectId },
          'ohttp-fcm: ohttp.send threw',
        );
        return { ok: false, status: 0 };
      }
    },
  };
}
