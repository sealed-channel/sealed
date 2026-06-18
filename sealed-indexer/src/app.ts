import express, { Express, Request, Response } from 'express';
import helmet from 'helmet';
import { createHmac, timingSafeEqual } from 'crypto';
import * as http from 'http';
import { URL } from 'url';
import { z } from 'zod';
import { createTargetedPushTokenStore } from './push/targeted-store';
import { requireTorOrigin } from './push/middleware';
import { createLegacyDirectoryStore } from './legacy/legacy-directory';
import { derivePublicKey, validateX25519Key } from './notifications/view-keys';
import type { UserDirectoryStore } from './users/user-store';
import { createUserRoutes } from './users/user-routes';
import { createUsernameRoutes } from './users/username-routes';
import type { RootsStore } from './roots/roots-store';
import { createRootsRoutes } from './roots/roots-routes';
import pino from 'pino';

/**
 * Build the Express app for the Tor indexer.
 *
 * Push surface area after Phase B:
 *   - POST /push/register-targeted   (opt-in alert mode)
 *   - POST /push/unregister-targeted
 *
 * The legacy `view_key_hash`-based endpoints and the blinded fanout endpoints
 * have been removed. Push Notifications is the only push path.
 *
 * Intentionally no HTTP polling or sync routes (plan decision D2).
 */
export interface CreateAppOptions {
  /**
   * Dispatcher X25519 public key (32 bytes). When provided, served at
   * GET /dispatcher/public-key as base64 so Flutter clients can seal push
   * tokens for it. When absent, the route returns 503.
   */
  dispatcherPubKey?: Buffer;
  /**
   * Live user directory (populated by `users/user-watcher.ts` from on-chain
   * `claimUsername` / `publishKeys` calls). When provided, mounts
   * GET /user/:wallet/pq-pubkey. When absent, the route returns 503.
   */
  userDirectory?: UserDirectoryStore;
  /**
   * SNARK-anchored Merkle-root registry. When provided, mounts
   *   GET  /roots                 (public, OHTTP-cacheable)
   *   POST /admin/roots/:root/leaves  (admin-only leaf upload, when
   *                                   `adminToken` is also set)
   * When absent, the routes return 503.
   */
  rootsStore?: RootsStore;
  /**
   * Static bearer token gating `POST /admin/roots/:root/leaves`. When unset,
   * the admin route returns 503 even if `rootsStore` is provided.
   */
  adminToken?: string;
  /**
   * Upstream base URL of the monetization-v1 preimage-server sidecar.
   * When set, mounts a streaming proxy at `GET /delivery/:hex` that forwards
   * to `<preimageUpstreamUrl>/delivery/:hex`. When absent, /delivery/:hex
   * returns 503. The sidecar itself stays on the internal docker net; this
   * proxy is the only path through which LP buyers reach it via the OHTTP
   * relay (which only targets the indexer's public Host header).
   */
  preimageUpstreamUrl?: string;
}

export function createApp(opts: CreateAppOptions = {}): Express {
  const app = express();

  app.set('trust proxy', false);
  app.use(helmet());
  app.use(express.json());

  // Initialize push token store (targeted-only post Phase B).
  const dbPath = process.env.INDEXER_DB_PATH || './indexer.db';
  const targetedStore = createTargetedPushTokenStore(dbPath);

  const hex64 = z.string().regex(/^[a-f0-9]{64}$/, 'Must be 64 lowercase hex characters');

  // Push Notifications registration (opt-in). Server holds view_priv to trial-decrypt
  // chain events and dispatch one visible-alert push per match. Two
  // cryptographic proofs are enforced at the route level so a client cannot:
  //   1. claim someone else's view_pub  (derivePublicKey check)
  //   2. register one user's view_priv under another user's blinded_id
  //      (HMAC consistency check)
  const targetedRegisterSchema = z.object({
    blinded_id: hex64,
    enc_token: z.string().min(1, 'enc_token cannot be empty'),
    platform: z.enum(['ios', 'android']),
    view_priv: hex64,
    view_pub: hex64,
    // Optional recipient wallet (58-char Algorand base32). Enables the KEM
    // first-contact push branch. Privacy: the indexer already holds view_priv
    // (opt-in disclosed); the wallet additionally links device↔wallet. The KEM
    // discovery tag is itself public (derivable from any two addresses) and the
    // push is a constant-text wake only — no message metadata. Stored
    // as-claimed (no crypto binding yet); see KEM-push hardening note below.
    wallet: z
      .string()
      .regex(/^[A-Z2-7]{58}$/, 'wallet must be a 58-char Algorand address')
      .optional(),
  });

  const targetedUnregisterSchema = z.object({
    blinded_id: hex64,
  });

  app.get('/health', (_req: Request, res: Response) => {
    res.json({ service: 'sealed-tor-indexer', status: 'ok' });
  });

  // Streaming proxy to the monetization-v1 preimage-server sidecar.
  // The sidecar is on the internal docker net only; the OHTTP relay targets
  // the indexer's public Host, so this proxy is the LP buyer's only path to
  // fetch their delivery ciphertext. Behaviour mirrors the sidecar's own
  // `/delivery/:hex` exactly (404 on unknown, 200 + ciphertext otherwise,
  // Cache-Control: no-store always).
  const DELIVERY_HEX_RE = /^[0-9a-fA-F]{64}$/;
  app.get('/delivery/:hex', (req: Request, res: Response) => {
    res.set('Cache-Control', 'no-store');
    if (!opts.preimageUpstreamUrl) {
      res.status(503).type('text/plain').send('preimage proxy not configured');
      return;
    }
    const hex = req.params.hex ?? '';
    if (!DELIVERY_HEX_RE.test(hex)) {
      res.status(404).type('text/plain').send('not found');
      return;
    }
    forwardToPreimageServer(opts.preimageUpstreamUrl, hex.toLowerCase(), res);
  });

  // Proxy the sidecar's `GET /stock` ({ available }) so the LP can pre-check
  // inventory before a buyer pays. Same upstream as /delivery; JSON passthrough.
  app.get('/stock', (_req: Request, res: Response) => {
    res.set('Cache-Control', 'no-store');
    if (!opts.preimageUpstreamUrl) {
      res.status(503).type('text/plain').send('preimage proxy not configured');
      return;
    }
    forwardStockToPreimageServer(opts.preimageUpstreamUrl, res);
  });

  app.get('/dispatcher/public-key', (_req: Request, res: Response) => {
    if (!opts.dispatcherPubKey) {
      return res.status(503).json({ error: 'Dispatcher public key not configured' });
    }
    return res.json({
      public_key: opts.dispatcherPubKey.toString('base64'),
      algorithm: 'x25519',
      version: 'sealed-push-token-v1',
    });
  });

  app.post(
    '/push/register',
    requireTorOrigin,
    (req: Request, res: Response) => {
      // Hold view_priv only inside this handler. Cleared in `finally` so the
      // raw bytes don't sit in a closure for the GC to flush whenever.
      let viewPrivBuf: Buffer | null = null;
      let viewPubBuf: Buffer | null = null;
      try {
        const parsed = targetedRegisterSchema.parse(req.body);

        viewPrivBuf = Buffer.from(parsed.view_priv, 'hex');
        viewPubBuf = Buffer.from(parsed.view_pub, 'hex');

        if (!validateX25519Key(viewPrivBuf) || !validateX25519Key(viewPubBuf)) {
          return res.status(400).json({ error: 'Invalid view key bytes' });
        }

        // Proof 1: derivePublicKey(view_priv) === view_pub
        const derived = derivePublicKey(viewPrivBuf);
        if (
          derived.length !== viewPubBuf.length ||
          !timingSafeEqual(derived, viewPubBuf)
        ) {
          return res
            .status(400)
            .json({ error: 'Invalid keypair: view_pub does not match view_priv' });
        }

        // Proof 2: HMAC(view_priv, "push-v1") === blinded_id
        const expectedBlindedHex = createHmac('sha256', viewPrivBuf)
          .update('push-v1')
          .digest('hex');
        const expectedBuf = Buffer.from(expectedBlindedHex, 'hex');
        const providedBuf = Buffer.from(parsed.blinded_id, 'hex');
        if (
          expectedBuf.length !== providedBuf.length ||
          !timingSafeEqual(expectedBuf, providedBuf)
        ) {
          return res
            .status(400)
            .json({ error: 'Invalid blinded_id: not consistent with view_priv' });
        }

        targetedStore.register({
          blindedId: parsed.blinded_id,
          encToken: parsed.enc_token,
          platform: parsed.platform,
          viewPriv: viewPrivBuf,
          viewPub: viewPubBuf,
          wallet: parsed.wallet ?? null,
        });

        // Audit log: blinded_id + platform + whether a wallet was supplied
        // (KEM-push opt-in). NEVER the wallet value, view_priv / view_pub /
        // enc_token.
        // eslint-disable-next-line no-console
        console.log(
          JSON.stringify({
            evt: 'push.register-targeted',
            blinded_id: parsed.blinded_id,
            platform: parsed.platform,
            kem_push: parsed.wallet !== undefined,
          }),
        );

        return res.json({ ok: true });
      } catch (error) {
        if (error instanceof z.ZodError) {
          return res
            .status(400)
            .json({ error: 'Validation failed', details: error.issues });
        }
        if (error instanceof Error && error.message.startsWith('Invalid ')) {
          return res.status(400).json({ error: error.message });
        }
        return res.status(500).json({ error: 'Internal server error' });
      } finally {
        // Zero out the in-memory view_priv copy before letting the buffer
        // become unreferenced. Best-effort — the parsed string in `req.body`
        // is still GC-eligible memory that we can't reach.
        if (viewPrivBuf) viewPrivBuf.fill(0);
        if (viewPubBuf) viewPubBuf.fill(0);
      }
    },
  );

  app.post(
    '/push/unregister',
    requireTorOrigin,
    (req: Request, res: Response) => {
      try {
        const { blinded_id } = targetedUnregisterSchema.parse(req.body);
        targetedStore.unregister(blinded_id);
        // eslint-disable-next-line no-console
        console.log(
          JSON.stringify({ evt: 'push.unregister-targeted', blinded_id }),
        );
        return res.json({ ok: true });
      } catch (error) {
        if (error instanceof z.ZodError) {
          return res
            .status(400)
            .json({ error: 'Validation failed', details: error.issues });
        }
        return res.status(500).json({ error: 'Internal server error' });
      }
    },
  );



  if (opts.userDirectory) {
    app.use('/user', createUserRoutes(opts.userDirectory));
    app.use('/username', createUsernameRoutes(opts.userDirectory));
  } else {
    app.use('/user', (_req: Request, res: Response) => {
      res.status(503).json({ error: 'User directory not configured' });
    });
    app.use('/username', (_req: Request, res: Response) => {
      res.status(503).json({ error: 'User directory not configured' });
    });
  }

  if (opts.rootsStore) {
    const rootsLogger = pino({ level: process.env.LOG_LEVEL ?? 'info' }).child({
      component: 'roots-routes',
    });
    const { publicRouter, adminRouter } = createRootsRoutes({
      store: opts.rootsStore,
      logger: rootsLogger,
      adminToken: opts.adminToken,
    });
    app.use('/roots', publicRouter);
    app.use('/admin/roots', adminRouter);
  } else {
    app.use('/roots', (_req: Request, res: Response) => {
      res.status(503).json({ error: 'Roots registry not configured' });
    });
    app.use('/admin/roots', (_req: Request, res: Response) => {
      res.status(503).json({ error: 'Roots registry not configured' });
    });
  }

  app.use((_req: Request, res: Response) => {
    res.status(404).json({ error: 'Not Found' });
  });

  return app;
}

/**
 * Forward a `GET /delivery/<hex>` request to the preimage-server sidecar.
 * Streams the upstream response (status + body) back to the client. Always
 * applies `Cache-Control: no-store` and `Content-Type: application/octet-stream`
 * regardless of what the upstream returns, mirroring the sidecar's own
 * conventions and defending against an upstream that ever forgets them.
 */
function forwardToPreimageServer(
  upstreamBaseUrl: string,
  hex: string,
  res: Response,
): void {
  let target: URL;
  try {
    target = new URL(`/delivery/${hex}`, upstreamBaseUrl);
  } catch {
    res.status(503).type('text/plain').send('preimage proxy misconfigured');
    return;
  }
  const upstreamReq = http.request(
    {
      protocol: target.protocol,
      hostname: target.hostname,
      port: target.port || 80,
      path: target.pathname,
      method: 'GET',
    },
    (upstreamRes) => {
      const status = upstreamRes.statusCode ?? 502;
      if (status === 200) {
        res.status(200);
        res.type('application/octet-stream');
        upstreamRes.pipe(res);
        return;
      }
      // Anything non-200 collapses to a uniform 404 — no upstream error
      // detail surfaces to the caller (matches the sidecar's
      // "never echo input" stance).
      upstreamRes.resume();
      if (!res.headersSent) {
        res.status(404).type('text/plain').send('not found');
      }
    },
  );
  upstreamReq.setTimeout(5_000, () => {
    upstreamReq.destroy(new Error('preimage upstream timeout'));
  });
  upstreamReq.on('error', () => {
    if (!res.headersSent) {
      res.status(502).type('text/plain').send('preimage upstream unreachable');
    }
  });
  upstreamReq.end();
}

/**
 * Forward `GET /stock` to the preimage-server sidecar, streaming its JSON
 * `{ available }` response back. Mirrors forwardToPreimageServer, but passes
 * JSON through (no octet-stream coercion, no 404 collapse).
 */
function forwardStockToPreimageServer(
  upstreamBaseUrl: string,
  res: Response,
): void {
  let target: URL;
  try {
    target = new URL('/stock', upstreamBaseUrl);
  } catch {
    res.status(503).type('text/plain').send('preimage proxy misconfigured');
    return;
  }
  const upstreamReq = http.request(
    {
      protocol: target.protocol,
      hostname: target.hostname,
      port: target.port || 80,
      path: target.pathname,
      method: 'GET',
    },
    (upstreamRes) => {
      const status = upstreamRes.statusCode ?? 502;
      res.status(status === 200 ? 200 : 502);
      res.type('application/json');
      upstreamRes.pipe(res);
    },
  );
  upstreamReq.setTimeout(5_000, () => {
    upstreamReq.destroy(new Error('preimage upstream timeout'));
  });
  upstreamReq.on('error', () => {
    if (!res.headersSent) {
      res.status(502).type('text/plain').send('preimage upstream unreachable');
    }
  });
  upstreamReq.end();
}
