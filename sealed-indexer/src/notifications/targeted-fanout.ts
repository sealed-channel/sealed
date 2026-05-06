/**
 * Push Notifications fanout (Task #9).
 *
 * Privacy trade-off (disclosed at registration): the indexer holds view_priv
 * for opted-in users and trial-decrypts every chain event to find matches.
 * For matching registrations it dispatches exactly one visible-alert push
 * with the constant body "You got a new encrypted message" via APNs (iOS) or
 * FCM (Android). Non-matching registrations are not woken.
 *
 * Contracts:
 *  - Body text is `TARGETED_PUSH_BODY` and nothing else. Tests pin the string.
 *  - No silent push. No data-only payload. No per-event metadata.
 *  - One push per matched registration per event (no fanout to all).
 */
import type { Logger } from 'pino';
import type { EventEmitter } from 'events';
import type { TargetedPushTokenStore, TargetedRegistration } from '../push/targeted-store';
import type { AlgorandMessageEvent, TokenDecryptFn } from './chain-event';
import { isMessageForViewKey } from './view-keys';
import { TARGETED_PUSH_BODY } from './targeted-payload';

export interface TargetedDispatchArgs {
  deviceToken: string;
  body: string;
  platform: 'ios' | 'android';
}

export interface TargetedSender {
  /** Send a visible-alert push. MUST use the body provided verbatim. */
  send(args: TargetedDispatchArgs): Promise<{ ok: boolean; status?: number }>;
}

export interface TargetedFanoutOptions {
  store: TargetedPushTokenStore;
  decryptToken: TokenDecryptFn;
  apnsSender: TargetedSender;
  fcmSender: TargetedSender;
  logger: Logger;
  algorandWatcher?: EventEmitter;
  /** Override registration source (used by tests). */
  listAllRegistrations?: () => TargetedRegistration[];
}

export interface TargetedFanout {
  start(): void;
  stop(): void;
  /** Public for direct testing — handles a single chain event. */
  handle(event: AlgorandMessageEvent): Promise<void>;
}

export function createTargetedFanout(opts: TargetedFanoutOptions): TargetedFanout {
  const {
    store,
    decryptToken,
    apnsSender,
    fcmSender,
    logger,
    algorandWatcher,
    listAllRegistrations,
  } = opts;

  let started = false;

  function listRegs(): TargetedRegistration[] {
    return listAllRegistrations ? listAllRegistrations() : store.listAll();
  }

  async function handle(event: AlgorandMessageEvent): Promise<void> {
    if (event.recipientTag.length !== 32 || event.senderEphemeralPubkey.length !== 32) {
      logger.warn(
        { txId: event.txId, msgId: event.messageId },
        'targeted-fanout: malformed crypto material — dropping',
      );
      return;
    }

    const regs = listRegs();
    const tagPrefix = event.recipientTag.subarray(0, 4).toString('hex');
    const ephPrefix = event.senderEphemeralPubkey.subarray(0, 4).toString('hex');
    const t0 = Date.now();
    logger.info(
      {
        txId: event.txId,
        msgId: event.messageId,
        round: event.confirmedRound?.toString(),
        appId: event.appId?.toString(),
        recipientTagPrefix: tagPrefix,
        senderEphPrefix: ephPrefix,
        regCount: regs.length,
      },
      'targeted-fanout: handling chain event',
    );

    if (regs.length === 0) {
      logger.debug({ txId: event.txId }, 'targeted-fanout: no registrations to scan');
      return;
    }

    let matchCount = 0;
    let dispatched = 0;
    let dispatchOk = 0;

    for (const reg of regs) {
      // viewPub prefix lets you cross-reference against the sender's logged
      // "🔑 Recipient scan pubkey:" line in the Flutter client. If the sender's
      // scan_pub does not match any registered view_pub here, the sender either
      // used the Ed25519→X25519 wallet fallback (recipient never published
      // scan_pub on-chain) or the recipient's published scan_pub is stale.
      const viewPubPrefix = reg.viewPub.subarray(0, 4).toString('hex');
      logger.debug(
        {
          blindedId: reg.blindedId,
          platform: reg.platform,
          viewPubPrefix,
          txId: event.txId,
        },
        'targeted-fanout: trial-decrypt registration',
      );
      let isMatch = false;
      try {
        isMatch = isMessageForViewKey(
          reg.viewPriv,
          event.senderEphemeralPubkey,
          event.recipientTag,
        );
      } catch (err) {
        logger.warn(
          { err, blindedId: reg.blindedId },
          'targeted-fanout: trial-decrypt threw — skipping registration',
        );
        continue;
      }
      if (!isMatch) continue;
      matchCount++;

      let deviceToken: string;
      try {
        deviceToken = decryptToken(Buffer.from(reg.encToken, 'base64'));
      } catch (err) {
        logger.error(
          { err, blindedId: reg.blindedId },
          'targeted-fanout: token decrypt failed — skipping registration',
        );
        continue;
      }

      const tokenPrefix = deviceToken.slice(0, 8);
      logger.info(
        {
          blindedId: reg.blindedId,
          platform: reg.platform,
          tokenPrefix,
          txId: event.txId,
        },
        'targeted-fanout: match found — dispatching push',
      );

      const sender = reg.platform === 'ios' ? apnsSender : fcmSender;
      const sendT0 = Date.now();
      dispatched++;
      try {
        const result = await sender.send({
          deviceToken,
          body: TARGETED_PUSH_BODY,
          platform: reg.platform,
        });
        const sendMs = Date.now() - sendT0;
        if (!result.ok) {
          logger.warn(
            {
              blindedId: reg.blindedId,
              platform: reg.platform,
              tokenPrefix,
              status: result.status,
              sendMs,
              txId: event.txId,
            },
            'targeted-fanout: sender returned not-ok',
          );
        } else {
          dispatchOk++;
          logger.info(
            {
              blindedId: reg.blindedId,
              platform: reg.platform,
              tokenPrefix,
              status: result.status,
              sendMs,
              txId: event.txId,
            },
            'targeted-fanout: push dispatched ok',
          );
        }
      } catch (err) {
        const sendMs = Date.now() - sendT0;
        logger.error(
          {
            err,
            blindedId: reg.blindedId,
            platform: reg.platform,
            tokenPrefix,
            sendMs,
            txId: event.txId,
          },
          'targeted-fanout: send threw',
        );
      }
    }

    logger.info(
      {
        txId: event.txId,
        regCount: regs.length,
        matchCount,
        dispatched,
        dispatchOk,
        totalMs: Date.now() - t0,
      },
      'targeted-fanout: event complete',
    );
  }

  function start(): void {
    if (started) return;
    started = true;
    if (algorandWatcher) {
      // Event name MUST match the watcher's emit ('newMessage') and the other
      // two fanouts. The earlier 'message' string was a bug — it never fired.
      algorandWatcher.on('newMessage', (event: AlgorandMessageEvent) => {
        handle(event).catch((err) => {
          logger.error({ err }, 'targeted-fanout: handle rejected');
        });
      });
    }
  }

  function stop(): void {
    started = false;
    if (algorandWatcher) {
      algorandWatcher.removeAllListeners('newMessage');
    }
  }

  return { start, stop, handle };
}
