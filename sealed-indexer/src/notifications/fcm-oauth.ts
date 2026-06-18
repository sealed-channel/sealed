/**
 * FCM OAuth2 service-account access-token provider.
 *
 * FCM HTTP v1 requires a short-lived OAuth2 bearer token derived from a
 * Google service-account JSON key. The flow:
 *
 *  1. Sign a JWT with the service account's RSA private key, claiming the
 *     `https://www.googleapis.com/auth/firebase.messaging` scope and
 *     `https://oauth2.googleapis.com/token` audience.
 *  2. POST to the OAuth2 token endpoint (urn:ietf:params:oauth:grant-type:
 *     jwt-bearer) and receive an `access_token` valid ~3600s.
 *  3. Cache the token for ~55min, then refresh.
 *
 * Deliberately uses raw `jsonwebtoken` + `fetch`, NOT `firebase-admin` or
 * `@google-cloud/*` — see test/no-google-sdk.test.ts.
 */
import jwt from 'jsonwebtoken';

const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const FCM_JWT_TTL_SECONDS = 3600;
const FCM_CACHE_TTL_SECONDS = 55 * 60;

export interface ServiceAccountKey {
  client_email: string;
  private_key: string;
  token_uri: string;
}

export interface FcmAccessTokenProvider {
  getAccessToken(): Promise<string>;
}

export interface FcmAccessTokenProviderOptions {
  serviceAccount: ServiceAccountKey;
  fetchImpl?: typeof fetch;
  /** Override clock for testing. Returns seconds since epoch. */
  nowSeconds?: () => number;
}

interface CachedToken {
  accessToken: string;
  expiresAt: number;
}

interface TokenEndpointResponse {
  access_token?: string;
  expires_in?: number;
  error?: string;
  error_description?: string;
}

export function createFcmAccessTokenProvider(
  opts: FcmAccessTokenProviderOptions,
): FcmAccessTokenProvider {
  const { serviceAccount } = opts;
  const fetchImpl = opts.fetchImpl ?? fetch;
  const nowSeconds = opts.nowSeconds ?? (() => Math.floor(Date.now() / 1000));

  if (!serviceAccount.client_email || !serviceAccount.private_key || !serviceAccount.token_uri) {
    throw new Error(
      'serviceAccount must include client_email, private_key, and token_uri',
    );
  }

  let cached: CachedToken | null = null;
  let inflight: Promise<string> | null = null;

  function signAssertion(): string {
    const iat = nowSeconds();
    const payload = {
      iss: serviceAccount.client_email,
      scope: FCM_SCOPE,
      aud: serviceAccount.token_uri,
      iat,
      exp: iat + FCM_JWT_TTL_SECONDS,
    };
    return jwt.sign(payload, serviceAccount.private_key, { algorithm: 'RS256' });
  }

  async function fetchNewToken(): Promise<string> {
    const assertion = signAssertion();
    const params = new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    });

    const response = await fetchImpl(serviceAccount.token_uri, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: params.toString(),
    });

    if (!response.ok) {
      throw new Error(`FCM OAuth token exchange failed with status ${response.status}`);
    }

    const json = (await response.json()) as TokenEndpointResponse;
    if (!json.access_token) {
      const reason = json.error_description ?? json.error ?? 'no access_token in response';
      throw new Error(`FCM OAuth token exchange returned no access_token: ${reason}`);
    }

    cached = {
      accessToken: json.access_token,
      expiresAt: nowSeconds() + FCM_CACHE_TTL_SECONDS,
    };
    return json.access_token;
  }

  return {
    async getAccessToken(): Promise<string> {
      const now = nowSeconds();
      if (cached && now < cached.expiresAt) {
        return cached.accessToken;
      }
      if (inflight) {
        return inflight;
      }
      inflight = fetchNewToken().finally(() => {
        inflight = null;
      });
      return inflight;
    },
  };
}
