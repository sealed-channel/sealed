/**
 * Express router for username search + availability endpoints.
 *
 * Mounted at /username in app.ts when opts.userDirectory is present. Backed
 * by the same UserDirectoryStore that user-watcher populates from
 * claimUsername / publishKeys txns.
 *
 * Routes:
 *   GET /username/search?q=&limit=     — fuzzy search, returns ranked hits
 *   GET /username/:name/available      — true if no row currently owns the name
 */
import { Router, Request, Response } from 'express';
import { z } from 'zod';
import type { UserDirectoryStore } from './user-store';

// Username grammar matches the contract: 3..20 chars, lowercase alnum + underscore,
// no leading/trailing underscore (leading digit allowed).
const usernameSchema = z
  .string()
  .regex(/^[a-z0-9][a-z0-9_]*[a-z0-9]$/, 'must match username grammar')
  .min(3)
  .max(20);

export function createUsernameRoutes(store: UserDirectoryStore): Router {
  const r = Router();

  /**
   * GET /search?q=<query>&limit=<n>
   *
   * 200 { query, count, results: [{ username, wallet, bio }] }
   * (bio is display-only payload — search matches usernames, never bios)
   * 400 on missing/invalid query
   */
  r.get('/search', (req: Request, res: Response) => {
    const rawQ = (req.query.q as string | undefined)?.trim();
    if (!rawQ) {
      return res.status(400).json({ error: 'q query param required' });
    }
    const limit = Math.min(50, Math.max(1, Number(req.query.limit ?? 20) | 0));

    const hits = store.search(rawQ, limit);
    const results = hits
      .filter((h) => h.username !== null)
      .map((h) => ({ username: h.username, wallet: h.ownerPubkey, bio: h.bio }));

    return res.json({ query: rawQ, count: results.length, results });
  });

  /**
   * GET /:name/available
   *
   * 200 { available: boolean }
   * 400 on invalid grammar
   */
  r.get('/:name/available', (req: Request, res: Response) => {
    const parsed = usernameSchema.safeParse(req.params.name.toLowerCase());
    if (!parsed.success) {
      return res.status(400).json({ error: 'Invalid username format' });
    }
    // Exact search on the store. Trigram path may rank exact matches first;
    // grab the top result and check equality.
    const hits = store.search(parsed.data, 5);
    const taken = hits.some(
      (h) => h.username && h.username.toLowerCase() === parsed.data,
    );
    return res.json({ available: !taken });
  });

  return r;
}
