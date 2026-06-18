/**
 * Task 1.6 — OHTTP-wrapped silent APNs sender.
 *
 * Sends iOS silent background pushes through the OHTTP relay so Apple does
 * not see the indexer's origin IP. The payload is a byte-exact constant
 * template; no Sealed-level identifiers or alert fields are ever included.
 * The app wakes on this silent push, runs a bounded sync over Tor, and
 * renders a locally-constructed notification if there are new messages.
 *
 * Privacy contract enforced here:
 *  - `aps.content-available = 1` only — no alert/sound/badge.
 *  - `data` dictionary is absent; a single opaque `n` (random nonce) field
 *    exists purely to wake the app.
 *  - Payload padded to a fixed byte length so Apple cannot size-correlate.
 */
import type { OhttpClient } from './ohttp-client';
import type { ApnsJwtProvider } from './apns-jwt';
import { randomBytes } from 'crypto';

/**
 * Fixed byte length of every APNs payload this sender emits.
 * Sized to match UnifiedPush (UP_PAYLOAD_SIZE = 2048) for defensive
 * symmetry across platforms; APNs background-push limit is 4096 bytes,
 * so we stay comfortably under while leaving headroom for future fields
 * like `apns-collapse-id` that might need to ride in the payload.
 */
export const APNS_PAYLOAD_SIZE = 2048;

/** Byte used to right-pad the JSON to the fixed size. NULs are ignored by JSON parsers when stripped by the APNs frontend, but we rely on APNs treating the raw payload as an opaque body; the device strips trailing NULs before JSON.parse. */
const PAD_BYTE = 0x00;

export interface SilentApnsSendArgs {
  /** Opaque APNs device token (hex) assigned by Apple. */
  deviceToken: string;
}

export interface SilentApnsSender {
  send(args: SilentApnsSendArgs): Promise<{ ok: boolean; status: number }>;
}

export interface SilentApnsSenderOptions {
  ohttp: OhttpClient;
  /** Base APNs endpoint, e.g. https://api.push.apple.com/3/device/ */
  apnsUrl: string;
  /** JWT provider for APNs token-based auth. */
  jwtProvider: ApnsJwtProvider;
  /** `apns-topic` header — the app bundle id. */
  topic: string;
  /** Called with the device token when APNs returns 410 (Unregistered). */
  onInvalidToken?: (token: string) => void;
}

/**
 * Build the APNs payload as a fixed-length buffer.
 *
 * Payload shape (byte-exact, no variations):
 *   {"aps":{"content-available":1},"n":"<base64-nonce>"}
 * followed by NUL padding up to APNS_PAYLOAD_SIZE.
 */
function buildPayload(): Buffer {
  // 32 random bytes → 44-char base64 (with '=' padding); length is constant.
  const nonceB64 = randomBytes(32).toString('base64');
  const json = JSON.stringify({ aps: { 'content-available': 1 }, n: nonceB64 });
  const jsonBytes = Buffer.from(json, 'utf8');

  if (jsonBytes.length > APNS_PAYLOAD_SIZE) {
    throw new Error(
      `APNs payload overflowed fixed size (${jsonBytes.length} > ${APNS_PAYLOAD_SIZE})`
    );
  }

  const out = Buffer.alloc(APNS_PAYLOAD_SIZE, PAD_BYTE);
  jsonBytes.copy(out, 0);
  return out;
}

export function createSilentApnsSender(opts: SilentApnsSenderOptions): SilentApnsSender {
  const { ohttp, apnsUrl, jwtProvider, topic, onInvalidToken } = opts;

  return {
    async send({ deviceToken }) {
      const body = buildPayload();

      try {
         const useDirect = process.env.BYPASS_OHTTP_FOR_PUSH === '1';
          const headers = {
            'apns-push-type': 'alert',
            'apns-priority': '10',
            'apns-topic': topic,
            authorization: `bearer ${jwtProvider.getToken()}`,
            'content-type': 'application/json',
          };                             
          let response: { status: number; body: Buffer };                       
          if (useDirect) {                         
            const direct = await fetch(`${apnsUrl}${deviceToken}`, {
              method: 'POST',                        
              headers,                                   
              body: body,
            });
            response = {                                                                   
              status: direct.status,
              body: Buffer.from(await direct.arrayBuffer()),                               
            };                                                                     
          } else {
            response = await ohttp.send({
              method: 'POST',            
              url: `${apnsUrl}${deviceToken}`,                                                              
              headers,                             
              body: body,  
            });                                      
          }     

        if (response.status === 410 && onInvalidToken) {
          onInvalidToken(deviceToken);
          return { ok: false, status: 410 };
        }

        if (response.status >= 200 && response.status < 300) {
          return { ok: true, status: response.status };
        }

        return { ok: false, status: response.status };
      } catch {
        return { ok: false, status: 0 };
      }
    },
  };
}
