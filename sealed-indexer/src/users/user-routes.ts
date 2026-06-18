/**
 * Express router for user directory endpoints.
 *
 * Mounted at /user in app.ts when opts.userDirectory is present.
 *
 * Routes:
 *   GET /:wallet/pq-pubkey  — fetch ML-KEM-512 public key + on-chain hash for a wallet.
 */
import { Router, Request, Response } from 'express';
import { createHash } from 'crypto';
import { z } from 'zod';
import type { UserDirectoryStore } from './user-store';

// 58-char Algorand base32 address (A-Z, 2-7)
const algoAddrSchema = z.string().regex(/^[A-Z2-7]{58}$/, 'must be 58-char Algorand base32 address');

export function createUserRoutes(store: UserDirectoryStore): Router {
  const r = Router();

  /**
   * GET /:wallet/pq-pubkey
   *
   * Returns:
   *   200  { pqPubkey: base64, pqPubkeyHash: hex(sha256), publishedAtRound: number }
   *   400  { error: 'Invalid wallet address' }
   *   404  { error: 'NOT_PUBLISHED' }   — no row, or row with pq_pubkey IS NULL
   */
  r.get('/:wallet/pq-pubkey', (req: Request, res: Response) => {
    const parsed = algoAddrSchema.safeParse(req.params.wallet);
    if (!parsed.success) {
      return res.status(400).json({ error: 'Invalid wallet address' });
    }

    const entry = store.byOwner(parsed.data);
    if (!entry || !entry.pqPubkey) {
      return res.status(404).json({ error: 'NOT_PUBLISHED' });
    }

    const pqPubkeyHash = createHash('sha256').update(entry.pqPubkey).digest('hex');

    return res.json({
      pqPubkey: entry.pqPubkey.toString('base64'),
      pqPubkeyHash,
      publishedAtRound: entry.pqPublishedRound ?? 0,
    });
  });

  return r;
}
