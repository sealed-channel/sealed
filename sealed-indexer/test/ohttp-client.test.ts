import { createOhttpClient, OhttpClient } from '../src/notifications/ohttp-client';

describe('createOhttpClient', () => {
  let mockFetch: jest.Mock;
  let mockKeyConfigFetcher: jest.Mock;
  const relayUrl = 'https://ohttp-relay.example.com';
  const fakeConfigBuffer = Buffer.from('fake_key_config_32_bytes_minimum!');

  beforeEach(() => {
    mockFetch = jest.fn();
    mockKeyConfigFetcher = jest.fn().mockResolvedValue(fakeConfigBuffer);
  });

  it('creates a client with send function', () => {
    const client = createOhttpClient({
      relayUrl,
      keyConfigFetcher: mockKeyConfigFetcher
    });

    expect(client).toBeDefined();
    expect(typeof client.send).toBe('function');
  });

  it('calls fetch with correct OHTTP relay parameters', async () => {
    // Mock successful relay response
    mockFetch.mockResolvedValue({
      ok: true,
      status: 200,
      arrayBuffer: jest.fn().mockResolvedValue(new ArrayBuffer(0))
    });

    const client = createOhttpClient({
      relayUrl,
      keyConfigFetcher: mockKeyConfigFetcher,
      fetchImpl: mockFetch
    });

    await client.send({
      method: 'POST',
      url: 'https://fcm.googleapis.com/v1/test',
      headers: { 'Content-Type': 'application/json' },
      body: Buffer.from('{"test": "data"}')
    });

    // Verify fetch was called with relay URL and correct content type
    expect(mockFetch).toHaveBeenCalledTimes(1);
    const [url, options] = mockFetch.mock.calls[0];

    expect(url).toBe(relayUrl);
    expect(options.method).toBe('POST');
    expect(options.headers['Content-Type']).toBe('message/ohttp-req');
    expect(options.body).toBeInstanceOf(Uint8Array);

    // Verify key config was fetched
    expect(mockKeyConfigFetcher).toHaveBeenCalledTimes(1);
  });

  it('handles relay error gracefully', async () => {
    mockFetch.mockResolvedValue({
      ok: false,
      status: 500
    });

    const client = createOhttpClient({
      relayUrl,
      keyConfigFetcher: mockKeyConfigFetcher,
      fetchImpl: mockFetch
    });

    await expect(client.send({
      method: 'POST',
      url: 'https://test.com',
      headers: {},
      body: Buffer.from('test')
    })).rejects.toThrow('OHTTP client error');
  });

  // TODO: add round-trip test once we have the relay's keyconfig fixture
  // For now we skip full HPKE encrypt/decrypt verification as it requires
  // proper key material and the relay's private key handling.
});