/**
 * Roots registry HTTP routes (SPEC-snark-redeem-B §6 / Task 6).
 *
 *   GET  /roots                            — public, cacheable, OHTTP-friendly.
 *   POST /admin/roots/:root/leaves         — admin-only leaf-set upload.
 *
 * OHTTP-friendliness contract for GET /roots:
 *   - Identical request bytes → identical response bytes. We sort + stringify
 *     ourselves rather than relying on Express's default `res.json` (which
 *     would still be stable today but does not promise stability).
 *   - No `Set-Cookie`, no `Vary` on identity headers, no `Authorization`
 *     echoing, no per-request timestamps. The handler explicitly strips any
 *     `Vary` Express / helmet might attach.
 *   - `Cache-Control: public, max-age=60` so OHTTP relay caches can dedupe
 *     concurrent fetches from different clients into one origin hit.
 *
 * Admin auth follows the simplest pattern that fits this codebase: a static
 * bearer token via `ADMIN_TOKEN` env var, compared with `timingSafeEqual`.
 * The codebase has no existing signature-based admin route (the Firebase
 * service-account key in admin-account.json is for FCM, not request auth).
 * If/when we add chain-signed admin auth this is the one place to swap.
 */
import { Router, Request, Response, NextFunction } from 'express';
import { timingSafeEqual } from 'crypto';
import { z } from 'zod';
import type { Logger } from 'pino';
import type { RootsStore } from './roots-store';

const hex64 = z.string().regex(/^[a-f0-9]{64}$/, 'must be 64-char lowercase hex');

const leavesUploadSchema = z.object({
  // `root` in the body is optional; we cross-check against the path param.
  root: hex64.optional(),
  leaves: z.array(hex64).max(1_048_576),
});

const rootRegisterSchema = z.object({
  denomination: z.number().int().positive(),
  postedRound: z.number().int().nonnegative(),
});

export interface CreateRootsRoutesOptions {
  store: RootsStore;
  logger: Logger;
  /** Static admin bearer token. When omitted, the admin route returns 503. */
  adminToken?: string;
}

export interface RootsRouters {
  /** Mount at `/roots`. Public, OHTTP-cacheable GET. */
  publicRouter: Router;
  /** Mount at `/admin/roots`. Admin POST for leaf uploads. */
  adminRouter: Router;
}

export function createRootsRoutes(opts: CreateRootsRoutesOptions): RootsRouters {
  const publicRouter = Router();
  const adminRouter = Router();
  const { store, logger, adminToken } = opts;

  // ---------------------------------------------------------------------------
  // GET /roots — public, cacheable.
  // ---------------------------------------------------------------------------
  publicRouter.get('/', (_req: Request, res: Response) => {
    const list = store.list();
    // Deterministic ordering for byte-stable cache keys: roots store already
    // returns rows ordered by (posted_round, root); leaves are returned in
    // upload index order. We freeze both here so a future store refactor
    // can't silently break OHTTP cache hits.
    const body = list
      .slice()
      .sort((a, b) =>
        a.postedRound !== b.postedRound
          ? a.postedRound - b.postedRound
          : a.root < b.root
            ? -1
            : a.root > b.root
              ? 1
              : 0,
      )
      .map((row) => ({
        root: row.root,
        denomination: row.denomination,
        postedRound: row.postedRound,
        leaves: row.leaves,
      }));

    const json = JSON.stringify(body);
    // Helmet sets various headers we want to keep (X-Content-Type-Options,
    // etc.). We only need to strip cache-defeating ones and forbid identity
    // Vary leakage.
    res.removeHeader('Set-Cookie');
    res.removeHeader('Vary');
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'public, max-age=60');
    res.status(200).send(json);
  });

  // ---------------------------------------------------------------------------
  // POST /admin/roots/:root — admin-only manual root registration.
  // Use when chain-watcher not running (e.g. local dev, or before T6 watcher
  // wiring). Body: { denomination, postedRound }. Idempotent via upsert.
  // ---------------------------------------------------------------------------
  adminRouter.post(
    '/:root',
    requireAdmin(adminToken),
    (req: Request, res: Response) => {
      const rootParam = req.params.root;
      if (!/^[a-f0-9]{64}$/.test(rootParam)) {
        return res.status(400).json({ error: 'INVALID_ROOT' });
      }
      let parsed;
      try {
        parsed = rootRegisterSchema.parse(req.body);
      } catch (err) {
        if (err instanceof z.ZodError) {
          return res.status(400).json({ error: 'VALIDATION_FAILED', details: err.issues });
        }
        throw err;
      }
      try {
        store.upsertRoot({
          root: rootParam,
          denomination: parsed.denomination,
          postedRound: parsed.postedRound,
        });
        return res.status(200).json({ ok: true });
      } catch (err) {
        logger.error(
          { err, rootPrefix: rootParam.slice(0, 8) },
          'roots-routes: upsertRoot failed',
        );
        return res.status(500).json({ error: 'INTERNAL' });
      }
    },
  );

  // ---------------------------------------------------------------------------
  // POST /admin/roots/:root/leaves — admin-only leaf upload.
  // ---------------------------------------------------------------------------
  adminRouter.post(
    '/:root/leaves',
    requireAdmin(adminToken),
    (req: Request, res: Response) => {
      const rootParam = req.params.root;
      if (!/^[a-f0-9]{64}$/.test(rootParam)) {
        return res.status(400).json({ error: 'INVALID_ROOT' });
      }
      let parsed;
      try {
        parsed = leavesUploadSchema.parse(req.body);
      } catch (err) {
        if (err instanceof z.ZodError) {
          return res.status(400).json({ error: 'VALIDATION_FAILED', details: err.issues });
        }
        throw err;
      }
      if (parsed.root && parsed.root !== rootParam) {
        return res.status(400).json({ error: 'ROOT_MISMATCH' });
      }
      try {
        store.setLeaves(rootParam, parsed.leaves);
      } catch (err) {
        if (err instanceof Error && err.message === 'UNKNOWN_ROOT') {
          return res.status(404).json({ error: 'UNKNOWN_ROOT' });
        }
        logger.error(
          { err, rootPrefix: rootParam.slice(0, 8) },
          'roots-routes: setLeaves failed',
        );
        return res.status(500).json({ error: 'INTERNAL' });
      }
      // Log only counts + prefix — never the admin identity or full root.
      logger.info(
        { rootPrefix: rootParam.slice(0, 8), leafCount: parsed.leaves.length },
        'roots-routes: admin uploaded leaves',
      );
      return res.json({ ok: true, leafCount: parsed.leaves.length });
    },
  );

  return { publicRouter, adminRouter };
}

/**
 * Bearer-token middleware. When `adminToken` is unset the route returns 503,
 * matching the indexer's pattern for "feature not configured" (see
 * /dispatcher/public-key).
 *
 * We compare with `timingSafeEqual` to keep this constant-time even though
 * a static token leaks nothing useful on its own — habits matter.
 */
function requireAdmin(adminToken?: string) {
  return (req: Request, res: Response, next: NextFunction): void => {
    if (!adminToken) {
      res.status(503).json({ error: 'ADMIN_NOT_CONFIGURED' });
      return;
    }
    const header = req.header('authorization') ?? '';
    const match = /^Bearer (.+)$/i.exec(header);
    if (!match) {
      res.status(401).json({ error: 'UNAUTHORIZED' });
      return;
    }
    const provided = Buffer.from(match[1]);
    const expected = Buffer.from(adminToken);
    if (
      provided.length !== expected.length ||
      !timingSafeEqual(provided, expected)
    ) {
      res.status(401).json({ error: 'UNAUTHORIZED' });
      return;
    }
    next();
  };
}
