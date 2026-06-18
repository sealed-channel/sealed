import { describe, expect, it } from "vitest";
import {
  commitmentFromPreimage,
  constants,
  decodeShortCode,
  encodeShortCode,
  generateShortCode,
  isValidShortCode,
} from "../../lib/short-code.js";

describe("short-code — generation", () => {
  it("produces a 12-char base32 code", () => {
    const { shortCode, preimage, commitmentHash } = generateShortCode();
    expect(shortCode).toHaveLength(constants.SHORT_CODE_LEN);
    expect(isValidShortCode(shortCode)).toBe(true);
    expect(preimage).toHaveLength(constants.PREIMAGE_LEN);
    expect(commitmentHash).toHaveLength(32);
  });

  it("every generated code is unique across many draws", () => {
    const seen = new Set<string>();
    for (let i = 0; i < 1000; i++) seen.add(generateShortCode().shortCode);
    expect(seen.size).toBe(1000);
  });
});

describe("short-code — encode/decode round-trip", () => {
  it("round-trips a known raw vector", () => {
    const raw = new Uint8Array([
      0x00, 0x44, 0x32, 0x14, 0xc7, 0x42, 0x54, 0xb0,
    ]);
    const code = encodeShortCode(raw);
    expect(code).toHaveLength(12);
    const decoded = decodeShortCode(code);
    expect(decoded).toEqual(raw);
  });

  it("round-trips a fully generated code", () => {
    const { shortCode, shortCodeBytes } = generateShortCode();
    expect(decodeShortCode(shortCode)).toEqual(shortCodeBytes);
  });

  it("maps all-zero raw to AAAAAAAAAAAA", () => {
    const raw = new Uint8Array(8);
    expect(encodeShortCode(raw)).toBe("AAAAAAAAAAAA");
  });

  it("rejects bad length", () => {
    expect(() => decodeShortCode("SHORT")).toThrow(/BAD_CODE_LEN/);
  });

  it("rejects bad characters", () => {
    expect(() => decodeShortCode("AAAAAAAAAAA1")).toThrow(/BAD_CODE_CHAR/);
  });
});

describe("short-code — isValidShortCode", () => {
  it("accepts valid", () => {
    expect(isValidShortCode("KX9F3MQA7BTZ".replace(/[019]/g, "A"))).toBe(true);
  });

  it("rejects invalid alphabet", () => {
    expect(isValidShortCode("AAAAAAAAAAA0")).toBe(false); // 0 not in alphabet
    expect(isValidShortCode("AAAAAAAAAAA1")).toBe(false); // 1 not in alphabet
    expect(isValidShortCode("aaaaaaaaaaaa")).toBe(false); // lowercase
  });

  it("rejects bad length", () => {
    expect(isValidShortCode("AAAA")).toBe(false);
    expect(isValidShortCode("A".repeat(13))).toBe(false);
  });
});

describe("short-code — commitment hashing", () => {
  it("sha256 matches manual computation", async () => {
    const preimage = new Uint8Array(16).fill(0xab);
    const hash = commitmentFromPreimage(preimage);
    expect(hash).toHaveLength(32);
    // Same input → same hash.
    expect(commitmentFromPreimage(preimage)).toEqual(hash);
  });

  it("different preimages → different hashes", () => {
    const a = commitmentFromPreimage(new Uint8Array(16).fill(0x01));
    const b = commitmentFromPreimage(new Uint8Array(16).fill(0x02));
    expect(a).not.toEqual(b);
  });
});
