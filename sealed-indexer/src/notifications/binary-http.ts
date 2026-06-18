/**
 * Binary HTTP message framing (RFC 9292).
 *
 * Encodes HTTP requests / decodes HTTP responses into the wire format expected
 * inside an OHTTP encapsulated request. Ported 1:1 from the Flutter client at
 * `sealed_app/lib/remote/ohttp/binary_http.dart` so both sides agree on the
 * exact byte layout.
 *
 * Known-Length Request format (framing indicator 0x00):
 *   varint(method) || method
 *   varint(scheme) || scheme
 *   varint(authority) || authority
 *   varint(path)     || path
 *   varint(headersLen) || headersBlock        (each header: varint(nameLen) name varint(valueLen) value)
 *   varint(contentLen) || content
 *   varint(0)                                  (empty trailers)
 */

export interface BinaryHttpRequest {
  method: string;
  url: string;                      // absolute URL — scheme/authority/path extracted
  headers: Record<string, string>;
  body: Uint8Array;
}

export interface BinaryHttpResponse {
  statusCode: number;
  headers: Record<string, string>;
  body: Uint8Array;
}

export function encodeRequest(req: BinaryHttpRequest): Uint8Array {
  const u = new URL(req.url);
  const out: number[] = [];

  // Framing indicator: 0x00 = Known-Length Request
  out.push(0x00);

  writeVarLenString(out, req.method);
  writeVarLenString(out, u.protocol.replace(/:$/, ''));   // "https" not "https:"

  // Authority: include port only if non-default
  const port = u.port;
  const isDefaultPort =
    (u.protocol === 'https:' && (port === '' || port === '443')) ||
    (u.protocol === 'http:' && (port === '' || port === '80'));
  const authority = isDefaultPort ? u.hostname : `${u.hostname}:${port}`;
  writeVarLenString(out, authority);

  // Path (with query if present)
  const path = (u.pathname || '/') + (u.search || '');
  writeVarLenString(out, path);

  // Headers block — length-prefixed
  const headerBytes = encodeHeaders(req.headers);
  writeVarInt(out, headerBytes.length);
  for (const b of headerBytes) out.push(b);

  // Content — length-prefixed
  writeVarInt(out, req.body.length);
  for (const b of req.body) out.push(b);

  // Empty trailers
  writeVarInt(out, 0);

  return new Uint8Array(out);
}

export function decodeResponse(data: Uint8Array): BinaryHttpResponse {
  let offset = 0;
  if (data.length === 0) {
    throw new Error('bhttp: empty response');
  }

  // Skip any informational (1xx) framings; expect final 0x01 known-length response.
  while (offset < data.length) {
    const framing = data[offset++];
    if (framing === 0x01) {
      const [statusCode, o1] = readVarInt(data, offset);
      offset = o1;

      const [headerBytes, o2] = readVarLenBytes(data, offset);
      offset = o2;
      const headers = decodeHeaders(headerBytes);

      const [body] = readVarLenBytes(data, offset);
      return { statusCode, headers, body };
    }
    if (framing === 0x00) {
      throw new Error('bhttp: expected response, got request framing');
    }
    throw new Error(`bhttp: unknown framing indicator 0x${framing.toString(16)}`);
  }
  throw new Error('bhttp: response truncated');
}

// ---------------------------------------------------------------------------
// Internals — QUIC-style varints (RFC 9000 §16) and length-prefixed fields.
// ---------------------------------------------------------------------------

function writeVarLenString(out: number[], value: string): void {
  const bytes = utf8(value);
  writeVarInt(out, bytes.length);
  for (const b of bytes) out.push(b);
}

function writeVarInt(out: number[], value: number): void {
  if (value < 0x40) {
    out.push(value);
  } else if (value < 0x4000) {
    out.push(0x40 | (value >> 8));
    out.push(value & 0xff);
  } else if (value < 0x40000000) {
    out.push(0x80 | (value >> 24));
    out.push((value >> 16) & 0xff);
    out.push((value >> 8) & 0xff);
    out.push(value & 0xff);
  } else {
    throw new Error(`varint: value too large (${value})`);
  }
}

function readVarInt(data: Uint8Array, offset: number): [number, number] {
  if (offset >= data.length) throw new Error('varint: unexpected end of data');
  const first = data[offset];
  const prefix = first >> 6;
  switch (prefix) {
    case 0:
      return [first, offset + 1];
    case 1:
      if (offset + 2 > data.length) throw new Error('varint: truncated 2-byte');
      return [((first & 0x3f) << 8) | data[offset + 1], offset + 2];
    case 2:
      if (offset + 4 > data.length) throw new Error('varint: truncated 4-byte');
      return [
        ((first & 0x3f) << 24) |
          (data[offset + 1] << 16) |
          (data[offset + 2] << 8) |
          data[offset + 3],
        offset + 4,
      ];
    default:
      throw new Error('varint: 8-byte not supported');
  }
}

function readVarLenBytes(data: Uint8Array, offset: number): [Uint8Array, number] {
  const [len, newOffset] = readVarInt(data, offset);
  if (newOffset + len > data.length) {
    throw new Error(`bhttp: truncated field (need ${len} bytes at ${newOffset})`);
  }
  return [data.subarray(newOffset, newOffset + len), newOffset + len];
}

function encodeHeaders(headers: Record<string, string>): Uint8Array {
  const out: number[] = [];
  for (const [k, v] of Object.entries(headers)) {
    const name = utf8(k.toLowerCase());
    const value = utf8(v);
    writeVarInt(out, name.length);
    for (const b of name) out.push(b);
    writeVarInt(out, value.length);
    for (const b of value) out.push(b);
  }
  return new Uint8Array(out);
}

function decodeHeaders(data: Uint8Array): Record<string, string> {
  const headers: Record<string, string> = {};
  let offset = 0;
  while (offset < data.length) {
    const [nameBytes, o1] = readVarLenBytes(data, offset);
    offset = o1;
    const [valueBytes, o2] = readVarLenBytes(data, offset);
    offset = o2;
    headers[utf8Decode(nameBytes)] = utf8Decode(valueBytes);
  }
  return headers;
}

const TE = new TextEncoder();
const TD = new TextDecoder();
function utf8(s: string): Uint8Array {
  return TE.encode(s);
}
function utf8Decode(b: Uint8Array): string {
  return TD.decode(b);
}
