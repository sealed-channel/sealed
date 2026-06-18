/**
 * Shared chain-event types for the push pipeline.
 *
 * Originally lived in `push-fanout.ts`. After the legacy view_key_hash and
 * blinded paths were retired, the only surviving consumers are the Algorand
 * watcher (emitter side) and the targeted fanout (consumer side); keeping the
 * types here avoids re-introducing a dependency on the deleted module.
 */
import type { EventEmitter } from 'events';

/**
 * Chain message event emitted on `newMessage` by the watcher.
 */
export interface AlgorandMessageEvent {
  /** 32 raw bytes from app-call arg[1]. */
  recipientTag: Buffer;
  /** 32 raw bytes — X25519 ephemeral pub from sender. */
  senderEphemeralPubkey: Buffer;
  /** Opaque encrypted message body. */
  ciphertext: Buffer;
  /** For debugging/logging only. */
  messageId: string;
  timestamp: number;
  // Optional fields populated by the real AlgoKit Subscriber (and the mock):
  appId?: bigint;
  txId?: string;
  confirmedRound?: bigint;
  sender?: string;
}

/**
 * Token decryption callback wired to the dispatcher keypair.
 */
export type TokenDecryptFn = (encryptedToken: Buffer) => string;

/**
 * Mock watcher used in dev (`ALGORAND_WATCHER_MODE=mock-dev`). Emits a single
 * synthetic `newMessage` event one second after construction so end-to-end
 * push wiring can be exercised without an Algorand connection.
 *
 * Production code never reaches this path — `index.ts` refuses to boot
 * `mock-dev` when `NODE_ENV=production`.
 */
export function createMockAlgorandWatcher(): EventEmitter {
  // Late require so this file stays importable from environments that don't
  // ship the events polyfill.
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { EventEmitter: EE } = require('events') as { EventEmitter: typeof EventEmitter };
  const emitter = new EE();
  setTimeout(() => {
    const mockEvent: AlgorandMessageEvent = {
      recipientTag: Buffer.alloc(32, 1),
      senderEphemeralPubkey: Buffer.alloc(32, 2),
      ciphertext: Buffer.from('mock-ciphertext'),
      messageId: 'mock-msg-1',
      timestamp: Date.now(),
    };
    emitter.emit('newMessage', mockEvent);
  }, 1000);
  return emitter;
}
