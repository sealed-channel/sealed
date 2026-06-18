import { AddressInfo } from 'node:net';
import * as http from 'node:http';
import request from 'supertest';
import { createApp } from '../src/app';

/**
 * Spin up a tiny in-process HTTP server that impersonates the
 * preimage-server. Returns base URL and helpers to control what it serves.
 */
function startFakeUpstream(handler: (req: http.IncomingMessage, res: http.ServerResponse) => void): Promise<{
  url: string;
  close: () => Promise<void>;
}> {
  return new Promise((resolve, reject) => {
    const srv = http.createServer(handler);
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address() as AddressInfo;
      resolve({
        url: `http://127.0.0.1:${addr.port}`,
        close: () =>
          new Promise((closeResolve) => {
            srv.close(() => closeResolve());
          }),
      });
    });
    srv.on('error', reject);
  });
}

const HEX64 = 'a'.repeat(64);

describe('indexer delivery proxy', () => {
  describe('when preimageUpstreamUrl is unset', () => {
    test('GET /delivery/:hex returns 503', async () => {
      const app = createApp({});
      const res = await request(app).get(`/delivery/${HEX64}`);
      expect(res.status).toBe(503);
      expect(res.headers['cache-control']).toBe('no-store');
    });
  });

  describe('input validation', () => {
    test('rejects non-hex path with 404 before touching upstream', async () => {
      let calls = 0;
      const fake = await startFakeUpstream((_req, res) => {
        calls++;
        res.statusCode = 200;
        res.end();
      });
      try {
        const app = createApp({ preimageUpstreamUrl: fake.url });
        const res = await request(app).get('/delivery/not-hex');
        expect(res.status).toBe(404);
        expect(res.text).toBe('not found');
        expect(res.headers['cache-control']).toBe('no-store');
        expect(calls).toBe(0);
      } finally {
        await fake.close();
      }
    });

    test('rejects wrong-length hex with 404 before touching upstream', async () => {
      let calls = 0;
      const fake = await startFakeUpstream((_req, res) => {
        calls++;
        res.end();
      });
      try {
        const app = createApp({ preimageUpstreamUrl: fake.url });
        const res = await request(app).get(`/delivery/${'a'.repeat(63)}`);
        expect(res.status).toBe(404);
        expect(calls).toBe(0);
      } finally {
        await fake.close();
      }
    });
  });

  describe('happy path', () => {
    test('streams upstream 200 ciphertext to the client', async () => {
      const body = Buffer.from([0x01, 0x02, 0x03, 0x04, 0x05]);
      const seenPaths: string[] = [];
      const fake = await startFakeUpstream((req, res) => {
        seenPaths.push(req.url ?? '');
        res.statusCode = 200;
        res.setHeader('content-type', 'application/octet-stream');
        res.end(body);
      });
      try {
        const app = createApp({ preimageUpstreamUrl: fake.url });
        const res = await request(app).get(`/delivery/${HEX64}`);
        expect(res.status).toBe(200);
        expect(res.headers['cache-control']).toBe('no-store');
        expect(res.headers['content-type']).toMatch(/^application\/octet-stream/);
        expect(Buffer.from(res.body).equals(body)).toBe(true);
        expect(seenPaths).toEqual([`/delivery/${HEX64}`]);
      } finally {
        await fake.close();
      }
    });

    test('normalises uppercase hex before proxying', async () => {
      const body = Buffer.from([9]);
      const seenPaths: string[] = [];
      const fake = await startFakeUpstream((req, res) => {
        seenPaths.push(req.url ?? '');
        res.statusCode = 200;
        res.end(body);
      });
      try {
        const app = createApp({ preimageUpstreamUrl: fake.url });
        const res = await request(app).get(`/delivery/${HEX64.toUpperCase()}`);
        expect(res.status).toBe(200);
        expect(seenPaths[0]).toBe(`/delivery/${HEX64}`); // lowercased
      } finally {
        await fake.close();
      }
    });
  });

  describe('upstream failure modes', () => {
    test('upstream 404 collapses to a uniform 404 + no body echo', async () => {
      const fake = await startFakeUpstream((_req, res) => {
        res.statusCode = 404;
        res.setHeader('content-type', 'application/json');
        res.end(JSON.stringify({ secret: 'leaked-detail' }));
      });
      try {
        const app = createApp({ preimageUpstreamUrl: fake.url });
        const res = await request(app).get(`/delivery/${HEX64}`);
        expect(res.status).toBe(404);
        expect(res.text).toBe('not found');
        expect(res.text.includes('leaked-detail')).toBe(false);
      } finally {
        await fake.close();
      }
    });

    test('upstream 5xx also collapses to 404 (no upstream detail surfaced)', async () => {
      const fake = await startFakeUpstream((_req, res) => {
        res.statusCode = 500;
        res.end('boom');
      });
      try {
        const app = createApp({ preimageUpstreamUrl: fake.url });
        const res = await request(app).get(`/delivery/${HEX64}`);
        expect(res.status).toBe(404);
        expect(res.text).toBe('not found');
      } finally {
        await fake.close();
      }
    });

    test('unreachable upstream surfaces 502', async () => {
      // Pick an unlikely port (no listener).
      const app = createApp({ preimageUpstreamUrl: 'http://127.0.0.1:1' });
      const res = await request(app).get(`/delivery/${HEX64}`);
      expect(res.status).toBe(502);
      expect(res.text).toBe('preimage upstream unreachable');
    });

    test('malformed upstream URL returns 503', async () => {
      const app = createApp({ preimageUpstreamUrl: 'not a url' });
      const res = await request(app).get(`/delivery/${HEX64}`);
      expect(res.status).toBe(503);
    });
  });
});
