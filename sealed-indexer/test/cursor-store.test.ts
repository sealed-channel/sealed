/**
 * Unit tests for the SQLite-backed Algorand cursor store.
 */

import { mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { createCursorStore } from '../src/notifications/cursor-store';

describe('CursorStore', () => {
  let dir: string;
  let dbPath: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'cursor-test-'));
    dbPath = join(dir, 'indexer.db');
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it('returns null before any round is set', () => {
    const store = createCursorStore(dbPath);
    try {
      expect(store.getRound()).toBeNull();
    } finally {
      store.close();
    }
  });

  it('round-trips a uint64-sized round', () => {
    const store = createCursorStore(dbPath);
    try {
      const big = 9_223_372_036_854_775_800n; // > Number.MAX_SAFE_INTEGER
      store.setRound(big);
      expect(store.getRound()).toBe(big);
    } finally {
      store.close();
    }
  });

  it('persists across reopen (AC4)', () => {
    const s1 = createCursorStore(dbPath);
    s1.setRound(42n);
    s1.close();

    const s2 = createCursorStore(dbPath);
    try {
      expect(s2.getRound()).toBe(42n);
    } finally {
      s2.close();
    }
  });

  it('upserts onto a single row', () => {
    const store = createCursorStore(dbPath);
    try {
      store.setRound(1n);
      store.setRound(2n);
      store.setRound(3n);
      expect(store.getRound()).toBe(3n);
    } finally {
      store.close();
    }
  });

  it('rejects negative rounds', () => {
    const store = createCursorStore(dbPath);
    try {
      expect(() => store.setRound(-1n)).toThrow();
    } finally {
      store.close();
    }
  });
});
