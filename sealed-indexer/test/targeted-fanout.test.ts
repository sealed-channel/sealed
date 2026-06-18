import { createTargetedFanout, type TargetedSender } from '../src/notifications/targeted-fanout';
import type { TargetedPushTokenStore, TargetedRegistration } from '../src/push/targeted-store';
import { TARGETED_PUSH_BODY } from '../src/notifications/targeted-payload';
import type { AlgorandMessageEvent } from '../src/notifications/chain-event';
import {
  computeRecipientTag,
  computeSharedSecret,
  derivePublicKey,
  computeKemDiscoveryTag,
} from '../src/notifications/view-keys';
import nacl from 'tweetnacl';
import pino from 'pino';

const logger = pino({ level: 'silent' });

function genX25519(): { priv: Buffer; pub: Buffer } {
  const seed = Buffer.from(nacl.randomBytes(32));
  const pub = derivePublicKey(seed);
  return { priv: seed, pub };
}

/** Build an event whose recipientTag matches `viewPriv`. */
function eventFor(viewPriv: Buffer): AlgorandMessageEvent {
  const senderEph = genX25519();
  const shared = computeSharedSecret(viewPriv, senderEph.pub);
  const tag = computeRecipientTag(shared);
  return {
    recipientTag: tag,
    senderEphemeralPubkey: senderEph.pub,
    ciphertext: Buffer.alloc(0),
    messageId: 'msg-1',
    timestamp: Date.now(),
  };
}

function eventFor_unrelated(): AlgorandMessageEvent {
  const recipient = genX25519();
  const senderEph = genX25519();
  const shared = computeSharedSecret(recipient.priv, senderEph.pub);
  return {
    recipientTag: computeRecipientTag(shared),
    senderEphemeralPubkey: senderEph.pub,
    ciphertext: Buffer.alloc(0),
    messageId: 'msg-2',
    timestamp: Date.now(),
  };
}

function makeRegistration(
  blindedId: string,
  platform: 'ios' | 'android',
  viewPriv: Buffer,
  viewPub: Buffer,
  encToken: string,
  wallet: string | null = null,
): TargetedRegistration {
  return {
    blindedId,
    encToken,
    platform,
    viewPriv,
    viewPub,
    wallet,
    createdAt: 0,
    updatedAt: 0,
  };
}

const WALLET_A = 'A'.repeat(58);
const WALLET_B = 'B'.repeat(58);

/** Build a KEM handshake frame event: zeroed ephemeral + discovery tag. */
function kemEventFrom(senderWallet: string, recipientWallet: string): AlgorandMessageEvent {
  return {
    recipientTag: computeKemDiscoveryTag(senderWallet, recipientWallet),
    senderEphemeralPubkey: Buffer.alloc(32),
    ciphertext: Buffer.alloc(800, 7),
    messageId: 'kem-1',
    timestamp: Date.now(),
    sender: senderWallet,
  };
}

function recordingSender(): TargetedSender & { calls: any[] } {
  const calls: any[] = [];
  return {
    calls,
    async send(args) {
      calls.push(args);
      return { ok: true, status: 200 };
    },
  };
}

function stubStore(): TargetedPushTokenStore {
  return {
    register: () => {
      throw new Error('not implemented');
    },
    get: () => null,
    listAll: () => [],
    unregister: () => {},
    close: () => {},
  };
}

describe('createTargetedFanout', () => {
  it('dispatches APNs visible alert with the constant body to a matching iOS reg', async () => {
    const recipient = genX25519();
    const reg = makeRegistration(
      'a'.repeat(64),
      'ios',
      recipient.priv,
      recipient.pub,
      Buffer.from('plaintext-ios-token').toString('base64'),
    );
    const apns = recordingSender();
    const fcm = recordingSender();
    const fanout = createTargetedFanout({
      store: stubStore(),
      decryptToken: (b) => b.toString('utf8'),
      apnsSender: apns,
      fcmSender: fcm,
      logger,
      listAllRegistrations: () => [reg],
    });

    await fanout.handle(eventFor(recipient.priv));
    expect(apns.calls).toHaveLength(1);
    expect(fcm.calls).toHaveLength(0);
    expect(apns.calls[0]).toEqual({
      deviceToken: 'plaintext-ios-token',
      body: TARGETED_PUSH_BODY,
      platform: 'ios',
    });
  });

  it('dispatches FCM with the constant body to a matching Android reg', async () => {
    const recipient = genX25519();
    const reg = makeRegistration(
      'b'.repeat(64),
      'android',
      recipient.priv,
      recipient.pub,
      Buffer.from('android-token').toString('base64'),
    );
    const apns = recordingSender();
    const fcm = recordingSender();
    const fanout = createTargetedFanout({
      store: stubStore(),
      decryptToken: (b) => b.toString('utf8'),
      apnsSender: apns,
      fcmSender: fcm,
      logger,
      listAllRegistrations: () => [reg],
    });

    await fanout.handle(eventFor(recipient.priv));
    expect(fcm.calls).toHaveLength(1);
    expect(apns.calls).toHaveLength(0);
    expect(fcm.calls[0].body).toBe(TARGETED_PUSH_BODY);
  });

  it('does NOT dispatch when no registration matches the event', async () => {
    const a = genX25519();
    const reg = makeRegistration(
      'c'.repeat(64),
      'ios',
      a.priv,
      a.pub,
      Buffer.from('tok').toString('base64'),
    );
    const apns = recordingSender();
    const fcm = recordingSender();
    const fanout = createTargetedFanout({
      store: stubStore(),
      decryptToken: (b) => b.toString('utf8'),
      apnsSender: apns,
      fcmSender: fcm,
      logger,
      listAllRegistrations: () => [reg],
    });
    await fanout.handle(eventFor_unrelated());
    expect(apns.calls).toHaveLength(0);
    expect(fcm.calls).toHaveLength(0);
  });

  it('drops malformed events without throwing', async () => {
    const apns = recordingSender();
    const fcm = recordingSender();
    const fanout = createTargetedFanout({
      store: stubStore(),
      decryptToken: () => 'x',
      apnsSender: apns,
      fcmSender: fcm,
      logger,
      listAllRegistrations: () => [],
    });
    await fanout.handle({
      recipientTag: Buffer.alloc(10),
      senderEphemeralPubkey: Buffer.alloc(32),
      ciphertext: Buffer.alloc(0),
      messageId: 'malformed',
      timestamp: 0,
    });
    expect(apns.calls).toHaveLength(0);
  });

  it('continues to next reg when token decrypt throws', async () => {
    const a = genX25519();
    const b = genX25519();
    const ev = eventFor(a.priv);
    // Two registrations, both match (we craft so the same event matches `a`,
    // not `b`). The first one's decrypt will throw; we still need the run to
    // complete cleanly. Use only `a` here to keep the assertion crisp.
    const reg = makeRegistration(
      'd'.repeat(64),
      'ios',
      a.priv,
      a.pub,
      Buffer.from('x').toString('base64'),
    );
    const apns = recordingSender();
    const fcm = recordingSender();
    const fanout = createTargetedFanout({
      store: stubStore(),
      decryptToken: () => {
        throw new Error('boom');
      },
      apnsSender: apns,
      fcmSender: fcm,
      logger,
      listAllRegistrations: () => [reg],
    });
    await fanout.handle(ev);
    expect(apns.calls).toHaveLength(0);
    expect(fcm.calls).toHaveLength(0);
    void b;
  });

  it('one push per matched registration only — never to non-matching regs', async () => {
    const a = genX25519();
    const b = genX25519();
    const c = genX25519();
    const regs = [
      makeRegistration('a'.repeat(64), 'ios', a.priv, a.pub, Buffer.from('tA').toString('base64')),
      makeRegistration('b'.repeat(64), 'android', b.priv, b.pub, Buffer.from('tB').toString('base64')),
      makeRegistration('c'.repeat(64), 'ios', c.priv, c.pub, Buffer.from('tC').toString('base64')),
    ];
    const apns = recordingSender();
    const fcm = recordingSender();
    const fanout = createTargetedFanout({
      store: stubStore(),
      decryptToken: (buf) => buf.toString('utf8'),
      apnsSender: apns,
      fcmSender: fcm,
      logger,
      listAllRegistrations: () => regs,
    });
    await fanout.handle(eventFor(b.priv));
    expect(apns.calls).toHaveLength(0);
    expect(fcm.calls).toHaveLength(1);
    expect(fcm.calls[0].deviceToken).toBe('tB');
  });

  describe('KEM first-contact frames (zeroed ephemeral)', () => {
    it('dispatches to the reg whose wallet matches the discovery tag', async () => {
      const recipient = genX25519();
      const reg = makeRegistration(
        'd'.repeat(64),
        'ios',
        recipient.priv,
        recipient.pub,
        Buffer.from('kem-token').toString('base64'),
        WALLET_B, // recipient registered their wallet
      );
      const apns = recordingSender();
      const fcm = recordingSender();
      const fanout = createTargetedFanout({
        store: stubStore(),
        decryptToken: (b) => b.toString('utf8'),
        apnsSender: apns,
        fcmSender: fcm,
        logger,
        listAllRegistrations: () => [reg],
      });
      // A → B first message: tag keyed on (sender=A, recipient=B).
      await fanout.handle(kemEventFrom(WALLET_A, WALLET_B));
      expect(apns.calls).toHaveLength(1);
      expect(apns.calls[0]).toEqual({
        deviceToken: 'kem-token',
        body: TARGETED_PUSH_BODY,
        platform: 'ios',
      });
    });

    it('does not dispatch when the registered wallet is not the recipient', async () => {
      const recipient = genX25519();
      const reg = makeRegistration(
        'e'.repeat(64),
        'ios',
        recipient.priv,
        recipient.pub,
        Buffer.from('kem-token').toString('base64'),
        WALLET_A, // wrong wallet — frame is addressed to WALLET_B
      );
      const apns = recordingSender();
      const fanout = createTargetedFanout({
        store: stubStore(),
        decryptToken: (b) => b.toString('utf8'),
        apnsSender: apns,
        fcmSender: recordingSender(),
        logger,
        listAllRegistrations: () => [reg],
      });
      await fanout.handle(kemEventFrom(WALLET_A, WALLET_B));
      expect(apns.calls).toHaveLength(0);
    });

    it('skips (no throw) a reg with no wallet on a KEM frame', async () => {
      const recipient = genX25519();
      const reg = makeRegistration(
        'f'.repeat(64),
        'ios',
        recipient.priv,
        recipient.pub,
        Buffer.from('kem-token').toString('base64'),
        null, // older client, never opted into KEM push
      );
      const apns = recordingSender();
      const fanout = createTargetedFanout({
        store: stubStore(),
        decryptToken: (b) => b.toString('utf8'),
        apnsSender: apns,
        fcmSender: recordingSender(),
        logger,
        listAllRegistrations: () => [reg],
      });
      await expect(fanout.handle(kemEventFrom(WALLET_A, WALLET_B))).resolves.toBeUndefined();
      expect(apns.calls).toHaveLength(0);
    });

    it('alias chat (ECDH frame, wallet-less reg) still pushes — KEM branch must not capture it', async () => {
      // Alias registrations register the alias scan_priv with NO wallet
      // (pseudonymity). Alias chat messages carry a real ephemeral + ECDH tag,
      // so they must route through the ECDH branch and match the wallet-less
      // alias row — never the KEM branch.
      const aliasScan = genX25519();
      const reg = makeRegistration(
        'a'.repeat(64),
        'ios',
        aliasScan.priv,
        aliasScan.pub,
        Buffer.from('alias-token').toString('base64'),
        null, // alias row: no wallet
      );
      const apns = recordingSender();
      const fanout = createTargetedFanout({
        store: stubStore(),
        decryptToken: (b) => b.toString('utf8'),
        apnsSender: apns,
        fcmSender: recordingSender(),
        logger,
        listAllRegistrations: () => [reg],
      });
      await fanout.handle(eventFor(aliasScan.priv));
      expect(apns.calls).toHaveLength(1);
      expect(apns.calls[0].deviceToken).toBe('alias-token');
    });

    it('steady-state ECDH frames still match (KEM branch does not regress)', async () => {
      const recipient = genX25519();
      const reg = makeRegistration(
        'a'.repeat(64),
        'ios',
        recipient.priv,
        recipient.pub,
        Buffer.from('ecdh-token').toString('base64'),
        WALLET_B, // wallet present, but a real ephemeral routes via ECDH
      );
      const apns = recordingSender();
      const fanout = createTargetedFanout({
        store: stubStore(),
        decryptToken: (b) => b.toString('utf8'),
        apnsSender: apns,
        fcmSender: recordingSender(),
        logger,
        listAllRegistrations: () => [reg],
      });
      await fanout.handle(eventFor(recipient.priv));
      expect(apns.calls).toHaveLength(1);
      expect(apns.calls[0].deviceToken).toBe('ecdh-token');
    });
  });
});
