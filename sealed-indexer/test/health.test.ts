import request from 'supertest';
import { createApp } from '../src/app';

describe('health endpoint', () => {
  it('returns 200 with service + status', async () => {
    const app = createApp();
    const res = await request(app).get('/health');

    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      service: 'sealed-tor-indexer',
      status: 'ok',
    });
  });

  it('does not expose HTTP polling / sync endpoints (D2)', async () => {
    const app = createApp();

    // These routes existed on the clearnet indexer. They must NOT exist here.
    const poll = await request(app).get('/api/messages');
    const sync = await request(app).get('/api/sync-state');

    expect(poll.status).toBe(404);
    expect(sync.status).toBe(404);
  });
});
