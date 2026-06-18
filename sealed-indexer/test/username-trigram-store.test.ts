import Database from 'better-sqlite3';
import { createUsernameTrigramStore } from '../src/users/username-trigram-store';

function mem() {
  return new Database(':memory:');
}

describe('UsernameTrigramStore — substring search', () => {
  it('finds usernames sharing a trigram', () => {
    const db = mem();
    const store = createUsernameTrigramStore(':unused:', { db });
    store.upsert('alice', 'ADDR_A');
    store.upsert('calvin', 'ADDR_C');
    store.upsert('bob', 'ADDR_B');
    store.upsert('talia', 'ADDR_T');

    const hits = store.search('ali', 20).map((h) => h.username).sort();
    expect(hits).toEqual(expect.arrayContaining(['alice', 'talia']));
    // 'calvin' contains "cal" but NOT "ali" — should not match.
    expect(hits).not.toContain('calvin');
    expect(hits).not.toContain('bob');
  });

  it('returns empty for nonexistent trigram', () => {
    const db = mem();
    const store = createUsernameTrigramStore(':unused:', { db });
    store.upsert('alice', 'ADDR_A');
    expect(store.search('xyz')).toEqual([]);
  });

  it('case-folds queries and stored names', () => {
    const db = mem();
    const store = createUsernameTrigramStore(':unused:', { db });
    store.upsert('AlIcE', 'ADDR_A');
    const hits = store.search('LIC');
    expect(hits.map((h) => h.username)).toEqual(['alice']);
  });

  it('upsert replaces an existing address for the same username', () => {
    const db = mem();
    const store = createUsernameTrigramStore(':unused:', { db });
    store.upsert('alice', 'ADDR_OLD');
    store.upsert('alice', 'ADDR_NEW');
    const hits = store.search('alic');
    expect(hits.length).toBe(1);
    expect(hits[0].address).toBe('ADDR_NEW');
  });

  it('delete removes a row', () => {
    const db = mem();
    const store = createUsernameTrigramStore(':unused:', { db });
    store.upsert('alice', 'ADDR_A');
    store.upsert('bob', 'ADDR_B');
    store.delete('alice');
    expect(store.search('alic')).toEqual([]);
    expect(store.search('bob').map((h) => h.username)).toEqual(['bob']);
  });

  it('clamps limit to [1, 50]', () => {
    const db = mem();
    const store = createUsernameTrigramStore(':unused:', { db });
    for (let i = 0; i < 60; i++) store.upsert(`user${i}xyz`, `A${i}`);
    expect(store.search('xyz', 1000).length).toBeLessThanOrEqual(50);
    expect(store.search('xyz', 0).length).toBeGreaterThan(0);
  });

  it('short (≤2 char) query falls back to LIKE prefix', () => {
    const db = mem();
    const store = createUsernameTrigramStore(':unused:', { db });
    store.upsert('al', 'ADDR_A');
    store.upsert('alex', 'ADDR_X');
    store.upsert('bob', 'ADDR_B');
    const hits = store.search('al').map((h) => h.username).sort();
    expect(hits).toEqual(['al', 'alex']);
  });

  it('neutralises FTS5 punctuation in query', () => {
    const db = mem();
    const store = createUsernameTrigramStore(':unused:', { db });
    store.upsert('alice', 'ADDR_A');
    // Punctuation should not blow up the parser.
    expect(() => store.search('ali"ce')).not.toThrow();
    expect(() => store.search('ali()')).not.toThrow();
  });

  it('count() reports row total', () => {
    const db = mem();
    const store = createUsernameTrigramStore(':unused:', { db });
    expect(store.count()).toBe(0);
    store.upsert('alice', 'A');
    store.upsert('bob', 'B');
    expect(store.count()).toBe(2);
    store.delete('alice');
    expect(store.count()).toBe(1);
  });
});
