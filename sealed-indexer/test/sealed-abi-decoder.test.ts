/**
 * Tests for sealed-abi-decoder.
 *
 * Verifies the boot-time selector map matches algosdk's ABIMethod.getSelector
 * for every method declared in Sealed.arc56.json. Provides confidence the
 * dispatcher will route real on-chain calls correctly.
 */

import algosdk from 'algosdk';
import {
  decodeAbiCall,
  knownMethodNames,
  selectorHexForMethod,
} from '../src/notifications/sealed-abi-decoder';

function selectorOf(signature: string): Uint8Array {
  return new algosdk.ABIMethod(algosdk.ABIMethod.fromSignature(signature).toJSON()).getSelector();
}

describe('sealed-abi-decoder', () => {
  it('exposes all methods from the Sealed ARC-56 spec', () => {
    const names = knownMethodNames();
    expect(names).toEqual(
      expect.arrayContaining([
        'createApplication',
        'registerCommitment',
        'redeem',
        'sendMessage',
        'claimUsername',
        'releaseUsername',
        'resolveUsername',
        'pruneExpired',
        'getCredits',
        'withdrawTreasury',
        'setTreasury',
        'publishKeys',
        'getUserProfile',
        'getUserKeys',
      ]),
    );
  });

  it('decodes sendMessage by selector', () => {
    const selector = selectorOf('sendMessage(byte[32],byte[])void');
    const tag = new Uint8Array(32);
    const ct = new Uint8Array([0x00, 0x05, 1, 2, 3, 4, 5]); // length-prefixed byte[]
    const decoded = decodeAbiCall([selector, tag, ct]);
    expect(decoded).not.toBeNull();
    expect(decoded?.method).toBe('sendMessage');
    expect(decoded?.signature).toBe('sendMessage(byte[32],byte[])void');
    expect(decoded?.args.length).toBe(2);
    expect(decoded?.args[0]).toEqual(tag);
  });

  it('decodes claimUsername (byte[])', () => {
    expect(
      decodeAbiCall([
        selectorOf('claimUsername(byte[])void'),
        new Uint8Array([0, 5, 0x40, 0x40, 0x40, 0x40, 0x40]),
      ])?.method,
    ).toBe('claimUsername');
  });

  it('decodes admin methods (registerCommitment, setTreasury, withdrawTreasury)', () => {
    expect(decodeAbiCall([selectorOf('registerCommitment(byte[],uint64)void'), new Uint8Array(2), new Uint8Array(8)])?.method).toBe('registerCommitment');
    expect(decodeAbiCall([selectorOf('setTreasury(address)void'), new Uint8Array(32)])?.method).toBe('setTreasury');
    expect(decodeAbiCall([selectorOf('withdrawTreasury(uint64,address)void'), new Uint8Array(8), new Uint8Array(32)])?.method).toBe('withdrawTreasury');
  });

  it('returns null for unknown selector', () => {
    const bogus = new Uint8Array([0xde, 0xad, 0xbe, 0xef]);
    expect(decodeAbiCall([bogus, new Uint8Array(32)])).toBeNull();
  });

  it('returns null for empty / undefined appArgs', () => {
    expect(decodeAbiCall(undefined)).toBeNull();
    expect(decodeAbiCall([])).toBeNull();
  });

  it('returns null when selector slot is not 4 bytes', () => {
    expect(decodeAbiCall([new Uint8Array([1, 2, 3])])).toBeNull();
    expect(decodeAbiCall([new Uint8Array(5)])).toBeNull();
  });

  it('selectorHexForMethod returns 8-hex-char selector for known methods', () => {
    const hex = selectorHexForMethod('sendMessage');
    expect(hex).toMatch(/^[0-9a-f]{8}$/);
    const expected = Buffer.from(selectorOf('sendMessage(byte[32],byte[])void')).toString('hex');
    expect(hex).toBe(expected);
  });

  it('returns null from selectorHexForMethod on unknown method', () => {
    expect(selectorHexForMethod('notARealMethod')).toBeNull();
  });
});
