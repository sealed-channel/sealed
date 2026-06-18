/**
 * Verifies method selectors used in username-watcher.ts against
 * algosdk.ABIMethod.fromSignature — prevents silent selector drift
 * if the contract method signatures change.
 */
import algosdk from 'algosdk';

function selectorOf(sig: string): Buffer {
  return Buffer.from(algosdk.ABIMethod.fromSignature(sig).getSelector());
}

describe('UsernameRegistry method selectors', () => {
  it('claimUsername(byte[],byte[])void', () => {
    expect(selectorOf('claimUsername(byte[],byte[])void')).toEqual(
      Buffer.from([0x7f, 0xd7, 0xa1, 0x4b]),
    );
  });

  it('releaseUsername(byte[])void', () => {
    expect(selectorOf('releaseUsername(byte[])void')).toEqual(
      Buffer.from([0xb4, 0xe2, 0x0f, 0x0c]),
    );
  });

  it('renameUsername(byte[],byte[],byte[])void', () => {
    expect(selectorOf('renameUsername(byte[],byte[],byte[])void')).toEqual(
      Buffer.from([0xa3, 0x37, 0xdc, 0x8b]),
    );
  });

  it('sweepExpiredCooldown(byte[])void', () => {
    expect(selectorOf('sweepExpiredCooldown(byte[])void')).toEqual(
      Buffer.from([0x7f, 0xb4, 0x34, 0x05]),
    );
  });
});
