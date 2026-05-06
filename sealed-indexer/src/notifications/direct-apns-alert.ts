/**
 * Direct (non-OHTTP) visible-alert APNs sender.
 *
 * Drop-in replacement for `createAlertApnsSender` (the OHTTP-wrapped variant)
 * for environments where the OHTTP gateway in front of the indexer does NOT
 * allow `api.push.apple.com` / `api.sandbox.push.apple.com` as targets and
 * therefore returns 403 ("Target forbidden on gateway") for every push.
 *
 * Privacy trade-off (intentional, opt-in via env):
 *   - Apple sees the indexer's egress IP and the timing of every push.
 *   - The push body is still the frozen TARGETED_PUSH_BODY constant — Apple
 *     learns "indexer woke this device token" and nothing about the message,
 *     sender, or chain event.
 *   - Body must equal TARGETED_PUSH_BODY (same invariant as the OHTTP sender).
 *
 * APNs requires HTTP/2 — `fetch` and `undici` http/1 do not work. We use
 * Node's built-in `http2` module with a single long-lived session, reused
 * across pushes. The session is lazily created on first send and recreated
 * after `close`/`error`.
 */
import * as http2 from 'http2';
import { URL } from 'url';
import type { Logger } from 'pino';
import type { ApnsJwtProvider } from './apns-jwt';
import type { TargetedSender, TargetedDispatchArgs } from './targeted-fanout';
import { buildApnsBody, TARGETED_PUSH_BODY } from './targeted-payload';

export interface DirectAlertApnsSenderOptions {
  /** Base APNs endpoint, e.g. https://api.sandbox.push.apple.com/3/device/ */
  apnsUrl: string;
  /** JWT provider for APNs token-based auth. */
  jwtProvider: ApnsJwtProvider;
  /** `apns-topic` header — the app bundle id. */
  topic: string;
  /** Called with the device token when APNs returns 410 (Unregistered). */
  onInvalidToken?: (token: string) => void;
  /** Optional structured logger. */
  logger?: Logger;
  /** Per-request timeout in ms. Default 10_000. */
  requestTimeoutMs?: number;
}

interface SessionHolder {
  session: http2.ClientHttp2Session | null;
  origin: string;
  pathPrefix: string;
}

export function createDirectAlertApnsSender(
  opts: DirectAlertApnsSenderOptions,
): TargetedSender {
  const {
    apnsUrl,
    jwtProvider,
    topic,
    onInvalidToken,
    logger,
    requestTimeoutMs = 10_000,
  } = opts;

  // Parse the configured endpoint into origin + path prefix exactly once.
  // Example: https://api.sandbox.push.apple.com:443/3/device/  →
  //   origin = https://api.sandbox.push.apple.com:443
  //   pathPrefix = /3/device/
  const parsed = new URL(apnsUrl);
  const origin = `${parsed.protocol}//${parsed.host}`;
  const pathPrefix = parsed.pathname.endsWith('/')
    ? parsed.pathname
    : `${parsed.pathname}/`;

  const holder: SessionHolder = { session: null, origin, pathPrefix };

  function getSession(): http2.ClientHttp2Session {
    if (holder.session && !holder.session.closed && !holder.session.destroyed) {
      return holder.session;
    }
    const s = http2.connect(holder.origin);
    s.on('error', (err) => {
      logger?.warn({ err: err.message, origin: holder.origin }, 'direct-apns: session error');
      if (holder.session === s) holder.session = null;
    });
    s.on('close', () => {
      if (holder.session === s) holder.session = null;
    });
    s.on('goaway', (code) => {
      logger?.info({ code, origin: holder.origin }, 'direct-apns: session goaway');
      if (holder.session === s) holder.session = null;
    });
    holder.session = s;
    return s;
  }

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
      const t0 = Date.now();
      const path = `${pathPrefix}${deviceToken}`;

      logger?.debug(
        { tokenPrefix, topic, payloadBytes: payload.length, origin: holder.origin },
        'direct-apns: sending push (no OHTTP)',
      );

      let session: http2.ClientHttp2Session;
      try {
        session = getSession();
      } catch (err) {
        const sendMs = Date.now() - t0;
        const msg = err instanceof Error ? err.message : String(err);
        logger?.error({ err, tokenPrefix, sendMs, message: msg }, 'direct-apns: connect failed');
        return { ok: false, status: 0 };
      }

      return await new Promise<{ ok: boolean; status?: number }>((resolve) => {
        let settled = false;
        const settle = (v: { ok: boolean; status?: number }) => {
          if (settled) return;
          settled = true;
          resolve(v);
        };

        let req: http2.ClientHttp2Stream;
        try {
          req = session.request({
            ':method': 'POST',
            ':path': path,
            'apns-push-type': 'alert',
            'apns-priority': '10',
            'apns-topic': topic,
            authorization: `bearer ${jwtProvider.getToken()}`,
            'content-type': 'application/json',
            'content-length': String(payload.length),
          });
        } catch (err) {
          const sendMs = Date.now() - t0;
          const msg = err instanceof Error ? err.message : String(err);
          logger?.error({ err, tokenPrefix, sendMs, message: msg }, 'direct-apns: request init failed');
          // Force a fresh session next time.
          holder.session = null;
          settle({ ok: false, status: 0 });
          return;
        }

        req.setTimeout(requestTimeoutMs, () => {
          logger?.warn({ tokenPrefix, requestTimeoutMs }, 'direct-apns: request timed out');
          try { req.close(http2.constants.NGHTTP2_CANCEL); } catch { /* noop */ }
          settle({ ok: false, status: 0 });
        });

        let status = 0;
        const chunks: Buffer[] = [];

        req.on('response', (headers) => {
          const s = headers[':status'];
          if (typeof s === 'number') status = s;
        });
        req.on('data', (chunk: Buffer) => chunks.push(chunk));
        req.on('error', (err) => {
          const sendMs = Date.now() - t0;
          logger?.error(
            { err: err.message, tokenPrefix, sendMs },
            'direct-apns: stream error',
          );
          settle({ ok: false, status: 0 });
        });
        req.on('end', () => {
          const sendMs = Date.now() - t0;
          const respBody = Buffer.concat(chunks);

          if (status === 410) {
            logger?.warn(
              { tokenPrefix, sendMs, status: 410 },
              'direct-apns: token unregistered (410) — invalidating',
            );
            if (onInvalidToken) onInvalidToken(deviceToken);
            settle({ ok: false, status: 410 });
            return;
          }

          if (status >= 200 && status < 300) {
            logger?.debug(
              { tokenPrefix, sendMs, status },
              'direct-apns: push accepted by APNs',
            );
            settle({ ok: true, status });
            return;
          }

          logger?.warn(
            {
              tokenPrefix,
              sendMs,
              status,
              bodySnippet: respBody.subarray(0, 256).toString('utf8'),
            },
            'direct-apns: APNs returned non-2xx',
          );
          settle({ ok: false, status });
        });

        req.end(payload);
      });
    },
  };
}
