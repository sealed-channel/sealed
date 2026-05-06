/**
 * APNs ES256 provider-JWT signer with caching and rotation.
 *
 * Apple requires provider JWTs to have ≤60min TTL. This module signs ES256 JWTs
 * with the required claims and headers, caches them for ~50min, then refreshes.
 *
 * Environment variables:
 * - APNS_KEY_PATH: Path to .p8 PEM private key file
 * - APNS_KEY_ID: Key ID from Apple Developer Portal
 * - APNS_TEAM_ID: Team ID (issuer)
 * - APNS_BUNDLE_ID: App bundle identifier
 */

import jwt from 'jsonwebtoken';
import { readFileSync } from 'fs';

// APNs JWT configuration constants
const APNS_JWT_TTL_MINUTES = 55; // Apple allows up to 60min TTL, we use 55min for safety margin
const APNS_CACHE_TTL_SECONDS = 50 * 60; // Cache expires 50 minutes from now (leaving 5min buffer)

export interface ApnsJwtProvider {
  getToken(): string;
}

export interface ApnsJwtProviderOptions {
  keyPath: string;
  keyId: string;
  teamId: string;
}

interface CachedToken {
  token: string;
  expiresAt: number;
}

export function createApnsJwtProvider(opts: ApnsJwtProviderOptions): ApnsJwtProvider {
  const { keyPath, keyId, teamId } = opts;

  // Load the private key at initialization
  let privateKey: string;
  try {
    privateKey = readFileSync(keyPath, 'utf8');
  } catch (error) {
    throw new Error('Failed to read APNs private key file');
  }

  let cachedToken: CachedToken | null = null;

  function generateToken(): CachedToken {
    const now = Math.floor(Date.now() / 1000);

    // JWT payload - Apple requires iss only, let jsonwebtoken set iat via expiresIn
    const payload = {
      iss: teamId,
    };

    // JWT header - Apple requires ES256 algorithm and kid
    const header = {
      alg: 'ES256' as const,
      kid: keyId,
    };

    // Sign with ES256 algorithm using the private key
    const token = jwt.sign(payload, privateKey, {
      algorithm: 'ES256',
      header,
      expiresIn: `${APNS_JWT_TTL_MINUTES}m`,
    });

    // Cache expires leaving buffer before JWT exp
    const expiresAt = now + APNS_CACHE_TTL_SECONDS;

    return { token, expiresAt };
  }

  function getToken(): string {
    const now = Math.floor(Date.now() / 1000);

    // Return cached token if still valid
    if (cachedToken && now < cachedToken.expiresAt) {
      return cachedToken.token;
    }

    // Generate new token and cache it
    cachedToken = generateToken();
    return cachedToken.token;
  }

  return { getToken };
}

// Validate environment variables at module load time in production
export function validateApnsEnvVars(): void {
  const requiredVars = ['APNS_KEY_PATH', 'APNS_KEY_ID', 'APNS_TEAM_ID', 'APNS_BUNDLE_ID'];
  const missing = requiredVars.filter(varName => !process.env[varName]);

  if (missing.length > 0) {
    throw new Error(`Missing required APNs environment variables: ${missing.join(', ')}`);
  }
}