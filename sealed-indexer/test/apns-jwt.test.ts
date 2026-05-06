/**
 * Tests for APNs JWT provider with caching and rotation.
 */

import { createApnsJwtProvider, validateApnsEnvVars } from '../src/notifications/apns-jwt';
import jwt from 'jsonwebtoken';
import { writeFileSync, mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

describe('APNs JWT Provider', () => {
  let tempDir: string;
  let keyPath: string;

  // Mock ES256 private key for testing (valid P-256 key format)
  const mockPrivateKey = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgYour32ByteLGvPaF
TxvgRSSzrlfVLg8wyNYl8dLh5LqhRANCAAS+rQRbdxAh5T1n2g3JQ3+ZK7O1iWxu
tJPhvhYKm6SXDGJNmKWm4H8cKKGKe8JQdHRkLPjqBSoJPsKpUejBNLLE
-----END PRIVATE KEY-----`;

  beforeEach(() => {
    // Create temporary directory and key file
    tempDir = mkdtempSync(join(tmpdir(), 'apns-jwt-test-'));
    keyPath = join(tempDir, 'test-key.p8');
    writeFileSync(keyPath, mockPrivateKey);
  });

  afterEach(() => {
    // Clean up temporary files
    rmSync(tempDir, { recursive: true });
  });

  describe('createApnsJwtProvider', () => {
    it('should create a JWT provider with valid options', () => {
      const provider = createApnsJwtProvider({
        keyPath,
        keyId: 'TESTKEY123',
        teamId: 'TEAMID1234',
      });

      expect(provider).toHaveProperty('getToken');
      expect(typeof provider.getToken).toBe('function');
    });

    it('should throw error if key file does not exist', () => {
      expect(() => {
        createApnsJwtProvider({
          keyPath: '/nonexistent/key.p8',
          keyId: 'TESTKEY123',
          teamId: 'TEAMID1234',
        });
      }).toThrow('Failed to read APNs private key');
    });

    it('should generate valid JWT with correct claims and header', () => {
      // Mock jwt.sign for testing since we're using a test key
      const mockJwtSign = jest.spyOn(jwt, 'sign').mockReturnValue('mock.jwt.token' as any);

      const provider = createApnsJwtProvider({
        keyPath,
        keyId: 'TESTKEY123',
        teamId: 'TEAMID1234',
      });

      const token = provider.getToken();

      expect(token).toBe('mock.jwt.token');
      expect(mockJwtSign).toHaveBeenCalledWith(
        expect.objectContaining({
          iss: 'TEAMID1234',
        }),
        expect.any(String),
        expect.objectContaining({
          algorithm: 'ES256',
          header: expect.objectContaining({
            alg: 'ES256',
            kid: 'TESTKEY123',
          }),
          expiresIn: '55m',
        })
      );

      mockJwtSign.mockRestore();
    });

    it('should cache token and return same token on subsequent calls', () => {
      // Mock jwt.sign for testing
      const mockJwtSign = jest.spyOn(jwt, 'sign').mockReturnValue('cached.jwt.token' as any);

      const provider = createApnsJwtProvider({
        keyPath,
        keyId: 'TESTKEY123',
        teamId: 'TEAMID1234',
      });

      const token1 = provider.getToken();
      const token2 = provider.getToken();

      expect(token1).toBe(token2);
      expect(token1).toBe('cached.jwt.token');
      // Should only call jwt.sign once due to caching
      expect(mockJwtSign).toHaveBeenCalledTimes(1);

      mockJwtSign.mockRestore();
    });

    it('should refresh token after cache expiry', (done) => {
      // Mock jwt.sign for testing
      let callCount = 0;
      const mockJwtSign = jest.spyOn(jwt, 'sign').mockImplementation(() => {
        callCount++;
        return `refreshed.jwt.token.${callCount}` as any;
      });

      // Mock the internal cache expiry by manipulating time
      const originalDateNow = Date.now;
      Date.now = jest.fn(() => originalDateNow());

      const provider = createApnsJwtProvider({
        keyPath,
        keyId: 'TESTKEY123',
        teamId: 'TEAMID1234',
      });

      const token1 = provider.getToken();

      // Advance time past cache expiry (50 minutes + 1 second)
      Date.now = jest.fn(() => originalDateNow() + (50 * 60 + 1) * 1000);

      const token2 = provider.getToken();

      expect(token1).not.toBe(token2);
      expect(token1).toBe('refreshed.jwt.token.1');
      expect(token2).toBe('refreshed.jwt.token.2');
      expect(mockJwtSign).toHaveBeenCalledTimes(2);

      // Restore original Date.now and mock
      Date.now = originalDateNow;
      mockJwtSign.mockRestore();
      done();
    });
  });

  describe('validateApnsEnvVars', () => {
    const originalEnv = process.env;

    beforeEach(() => {
      jest.resetModules();
      process.env = { ...originalEnv };
    });

    afterEach(() => {
      process.env = originalEnv;
    });

    it('should always throw when env vars are missing', () => {
      process.env.NODE_ENV = 'development';
      delete process.env.APNS_KEY_PATH;
      delete process.env.APNS_KEY_ID;
      delete process.env.APNS_TEAM_ID;
      delete process.env.APNS_BUNDLE_ID;

      expect(() => validateApnsEnvVars()).toThrow(
        'Missing required APNs environment variables: APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID'
      );
    });

    it('should throw in production when env vars are missing', () => {
      process.env.NODE_ENV = 'production';
      delete process.env.APNS_KEY_PATH;
      delete process.env.APNS_KEY_ID;
      delete process.env.APNS_TEAM_ID;
      delete process.env.APNS_BUNDLE_ID;

      expect(() => validateApnsEnvVars()).toThrow(
        'Missing required APNs environment variables: APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID'
      );
    });

    it('should not throw when all env vars are present', () => {
      process.env.NODE_ENV = 'production';
      process.env.APNS_KEY_PATH = '/path/to/key.p8';
      process.env.APNS_KEY_ID = 'TESTKEY123';
      process.env.APNS_TEAM_ID = 'TEAMID1234';
      process.env.APNS_BUNDLE_ID = 'com.example.app';

      expect(() => validateApnsEnvVars()).not.toThrow();
    });
  });
});