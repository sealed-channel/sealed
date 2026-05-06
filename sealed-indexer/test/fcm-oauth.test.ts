/**
 * Tests for FCM OAuth2 service-account token provider.
 *
 * Contract:
 *  - Signs a JWT with RS256 using the service account's private_key.
 *  - JWT claims are { iss: client_email, scope: firebase.messaging, aud:
 *    token_uri, iat, exp = iat + 3600 }.
 *  - POSTs to token_uri with grant_type jwt-bearer and form-encoded assertion.
 *  - Caches the access_token for ~55min, refreshes after.
 *  - Coalesces concurrent calls into one in-flight request.
 *  - Throws on token endpoint failure.
 */
import { createFcmAccessTokenProvider } from '../src/notifications/fcm-oauth';
import { generateKeyPairSync } from 'crypto';
import jwt from 'jsonwebtoken';

function makeServiceAccount() {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', {
    modulusLength: 2048,
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    publicKeyEncoding: { type: 'spki', format: 'pem' },
  });
  return {
    serviceAccount: {
      client_email: 'test@sealed.iam.gserviceaccount.com',
      private_key: privateKey,
      token_uri: 'https://oauth2.googleapis.com/token',
    },
    publicKey,
  };
}

describe('createFcmAccessTokenProvider', () => {
  it('signs a JWT with the service-account private key and required claims', async () => {
    const { serviceAccount, publicKey } = makeServiceAccount();
    const fetchImpl = jest.fn(async (_url, init: { body: string }) => {
      const params = new URLSearchParams(init.body);
      expect(params.get('grant_type')).toBe('urn:ietf:params:oauth:grant-type:jwt-bearer');
      const assertion = params.get('assertion')!;

      const decoded = jwt.verify(assertion, publicKey, { algorithms: ['RS256'] }) as {
        iss: string;
        scope: string;
        aud: string;
        iat: number;
        exp: number;
      };
      expect(decoded.iss).toBe(serviceAccount.client_email);
      expect(decoded.scope).toBe('https://www.googleapis.com/auth/firebase.messaging');
      expect(decoded.aud).toBe(serviceAccount.token_uri);
      expect(decoded.exp - decoded.iat).toBe(3600);

      return new Response(JSON.stringify({ access_token: 'tok-1', expires_in: 3600 }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    });

    const provider = createFcmAccessTokenProvider({
      serviceAccount,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    expect(await provider.getAccessToken()).toBe('tok-1');
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it('caches the token across calls within the cache TTL', async () => {
    const { serviceAccount } = makeServiceAccount();
    let now = 1_000_000;
    const fetchImpl = jest.fn(
      async () =>
        new Response(JSON.stringify({ access_token: 'tok-cached', expires_in: 3600 }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        }),
    );

    const provider = createFcmAccessTokenProvider({
      serviceAccount,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      nowSeconds: () => now,
    });

    expect(await provider.getAccessToken()).toBe('tok-cached');
    now += 60 * 30;
    expect(await provider.getAccessToken()).toBe('tok-cached');
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it('refreshes after the cache TTL expires', async () => {
    const { serviceAccount } = makeServiceAccount();
    let now = 1_000_000;
    let n = 0;
    const fetchImpl = jest.fn(async () => {
      n += 1;
      return new Response(
        JSON.stringify({ access_token: `tok-${n}`, expires_in: 3600 }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      );
    });

    const provider = createFcmAccessTokenProvider({
      serviceAccount,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      nowSeconds: () => now,
    });

    expect(await provider.getAccessToken()).toBe('tok-1');
    now += 60 * 56;
    expect(await provider.getAccessToken()).toBe('tok-2');
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it('coalesces concurrent calls into one in-flight request', async () => {
    const { serviceAccount } = makeServiceAccount();
    let resolveFetch: (r: Response) => void = () => undefined;
    const fetchImpl = jest.fn(
      () =>
        new Promise<Response>((resolve) => {
          resolveFetch = resolve;
        }),
    );

    const provider = createFcmAccessTokenProvider({
      serviceAccount,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    const a = provider.getAccessToken();
    const b = provider.getAccessToken();
    const c = provider.getAccessToken();

    resolveFetch(
      new Response(JSON.stringify({ access_token: 'tok-once', expires_in: 3600 }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    );

    expect(await a).toBe('tok-once');
    expect(await b).toBe('tok-once');
    expect(await c).toBe('tok-once');
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it('throws when the token endpoint returns non-2xx', async () => {
    const { serviceAccount } = makeServiceAccount();
    const fetchImpl = jest.fn(
      async () =>
        new Response(JSON.stringify({ error: 'invalid_grant' }), {
          status: 400,
          headers: { 'content-type': 'application/json' },
        }),
    );

    const provider = createFcmAccessTokenProvider({
      serviceAccount,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    await expect(provider.getAccessToken()).rejects.toThrow(/400/);
  });

  it('throws when the token endpoint returns 200 but no access_token', async () => {
    const { serviceAccount } = makeServiceAccount();
    const fetchImpl = jest.fn(
      async () =>
        new Response(
          JSON.stringify({ error: 'unauthorized_client', error_description: 'bad sig' }),
          { status: 200, headers: { 'content-type': 'application/json' } },
        ),
    );

    const provider = createFcmAccessTokenProvider({
      serviceAccount,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    await expect(provider.getAccessToken()).rejects.toThrow(/no access_token/i);
  });

  it('rejects construction with missing service-account fields', () => {
    expect(() =>
      createFcmAccessTokenProvider({
        serviceAccount: {
          client_email: '',
          private_key: 'x',
          token_uri: 'y',
        },
      }),
    ).toThrow();
  });
});
