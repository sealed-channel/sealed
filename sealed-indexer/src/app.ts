import express, { Express, Request, Response } from 'express';
import helmet from 'helmet';
import { createHmac, timingSafeEqual } from 'crypto';
import { z } from 'zod';
import { createTargetedPushTokenStore } from './push/targeted-store';
import { requireTorOrigin } from './push/middleware';
import { createLegacyDirectoryStore } from './legacy/legacy-directory';
import { derivePublicKey, validateX25519Key } from './notifications/view-keys';
import type { UserDirectoryStore, UserDirectoryEntry } from './users/user-store';

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
   * `set_username` calls). When provided, GET /user/by-owner/:owner and
   * GET /user/search are mounted under `requireTorOrigin`. When absent, the
   * routes return 503 — the indexer is push-only.
   */
  userDirectory?: UserDirectoryStore;
}

export function createApp(opts: CreateAppOptions = {}): Express {
  const app = express();

  app.set('trust proxy', false);
  app.use(helmet());
  app.use(express.json());

  // Initialize push token store (targeted-only post Phase B).
  const dbPath = process.env.INDEXER_DB_PATH || './indexer.db';
  const targetedStore = createTargetedPushTokenStore(dbPath);

  // Read-through directory of legacy (pre-Algorand) usernames imported
  // from the old indexer-service. Marked `legacy: true` on every response
  // so clients render them dimmed and don't try to message them.
  const legacyDir = createLegacyDirectoryStore(dbPath);

  const legacyUsernameSchema = z
    .string()
    .min(1)
    .max(64)
    .regex(/^[A-Za-z0-9_.-]+$/);
  const legacyOwnerSchema = z.string().min(1).max(128);
  const legacySearchSchema = z.object({
    q: legacyUsernameSchema,
    limit: z.coerce.number().int().min(1).max(100).optional(),
  });

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
  });

  const targetedUnregisterSchema = z.object({
    blinded_id: hex64,
  });

  app.get('/health', (_req: Request, res: Response) => {
    res.json({ service: 'sealed-tor-indexer', status: 'ok' });
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
    '/push/register-targeted',
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
        });

        // Audit log: blinded_id + platform only. NEVER view_priv / view_pub /
        // enc_token.
        // eslint-disable-next-line no-console
        console.log(
          JSON.stringify({
            evt: 'push.register-targeted',
            blinded_id: parsed.blinded_id,
            platform: parsed.platform,
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
    '/push/unregister-targeted',
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

  // Live user directory (populated from on-chain set_username calls). Tor-only
  // because revealing "wallet X is being looked up by IP Y" leaks the social
  // graph the rest of the indexer is designed to hide.
  const userOwnerSchema = z.string().min(1).max(128);
  const userSearchSchema = z.object({
    q: z.string().min(1).max(64),
    limit: z.coerce.number().int().min(1).max(50).optional(),
  });

  function entryToJson(entry: UserDirectoryEntry) {
    const out: Record<string, unknown> = {
      username: entry.username,
      ownerPubkey: entry.ownerPubkey,
      encryptionPubkey: entry.encryptionPubkey.toString('base64'),
      scanPubkey: entry.scanPubkey.toString('base64'),
      registeredAt: entry.registeredAt,
    };
    // Search-time only: present on results from `userDirectory.search`,
    // absent on `byOwner` lookups. Additive — old clients ignore them.
    if (entry.score !== undefined) out.score = entry.score;
    if (entry.matchType !== undefined) out.matchType = entry.matchType;
    return out;
  }

  app.get(
    '/user/by-owner/:ownerPubkey',
    requireTorOrigin,
    (req: Request, res: Response) => {
      if (!opts.userDirectory) {
        return res.status(503).json({ error: 'User directory not configured' });
      }
      try {
        const ownerPubkey = userOwnerSchema.parse(req.params.ownerPubkey);
        const entry = opts.userDirectory.byOwner(ownerPubkey);
        if (!entry) return res.status(404).json({ error: 'User not found' });
        return res.json(entryToJson(entry));
      } catch (error) {
        if (error instanceof z.ZodError) {
          return res.status(400).json({ error: 'Invalid owner pubkey' });
        }
        return res.status(500).json({ error: 'Internal server error' });
      }
    },
  );

  app.get('/user/search', requireTorOrigin, (req: Request, res: Response) => {
    if (!opts.userDirectory) {
      return res.status(503).json({ error: 'User directory not configured' });
    }
    try {
      const { q, limit } = userSearchSchema.parse(req.query);
      const entries = opts.userDirectory.search(q, limit ?? 20);
      return res.json({
        query: q,
        count: entries.length,
        users: entries.map(entryToJson),
      });
    } catch (error) {
      if (error instanceof z.ZodError) {
        return res.status(400).json({ error: 'Invalid query' });
      }
      return res.status(500).json({ error: 'Internal server error' });
    }
  });

  app.get('/legacy/by-username/:name', (req: Request, res: Response) => {
    try {
      const username = legacyUsernameSchema.parse(req.params.name);
      const entry = legacyDir.byUsername(username);
      if (!entry) return res.status(404).json({ error: 'Not Found' });
      return res.json({ ...entry, legacy: true });
    } catch (error) {
      if (error instanceof z.ZodError) {
        return res.status(400).json({ error: 'Invalid username' });
      }
      return res.status(500).json({ error: 'Internal server error' });
    }
  });

  app.get('/legacy/by-owner/:owner', (req: Request, res: Response) => {
    try {
      const owner = legacyOwnerSchema.parse(req.params.owner);
      const entries = legacyDir.byOwner(owner);
      return res.json({
        owner,
        users: entries.map(e => ({ ...e, legacy: true })),
      });
    } catch (error) {
      if (error instanceof z.ZodError) {
        return res.status(400).json({ error: 'Invalid owner' });
      }
      return res.status(500).json({ error: 'Internal server error' });
    }
  });

  app.get('/legacy/search', (req: Request, res: Response) => {
    try {
      const { q, limit } = legacySearchSchema.parse(req.query);
      const entries = legacyDir.search(q, limit ?? 20);
      return res.json({
        query: q,
        users: entries.map(e => ({ ...e, legacy: true })),
      });
    } catch (error) {
      if (error instanceof z.ZodError) {
        return res.status(400).json({ error: 'Invalid query' });
      }
      return res.status(500).json({ error: 'Internal server error' });
    }
  });

  app.use((_req: Request, res: Response) => {
    res.status(404).json({ error: 'Not Found' });
  });

  return app;
}
