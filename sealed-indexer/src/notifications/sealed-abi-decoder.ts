/**
 * Sealed ABI selector decoder.
 *
 * Boot-time: load `Sealed.arc56.json`, compute 4-byte selectors for every
 * method, build a (selector → method) map. Watcher dispatches on this map
 * instead of legacy shape-heuristic arg parsing.
 *
 * Selector = first 4 bytes of sha512/256("methodName(arg,arg)retType").
 * ARC4 standard; matches `algosdk.ABIMethod.getSelector()`.
 *
 * decodeAbiCall(appArgs) returns:
 *   { method: 'sendMessage', args: Uint8Array[], returnType: 'void' }
 * or null when:
 *   - appArgs missing/empty,
 *   - appArgs[0] not 4 bytes,
 *   - selector not in map (= not a Sealed-known method).
 *
 * The decoder does NOT decode arg bodies (length-prefixed byte[] etc.). It
 * surfaces raw arg slots so each call site can ABI-decode only what it needs.
 */

import algosdk from 'algosdk';

import sealedArc56 from './sealed.arc56.json';

export interface Arc56Method {
  name: string;
  args: ReadonlyArray<{ type: string; name?: string }>;
  returns: { type: string };
}

export interface DecodedAbiCall {
  /** Method name as declared in Sealed.arc56.json. */
  method: string;
  /** ABI signature, e.g. `sendMessage(byte[32],byte[])void`. */
  signature: string;
  /** Raw application args slice WITHOUT the leading selector. */
  args: ReadonlyArray<Uint8Array>;
  /** Declared return type. */
  returnType: string;
}

const SELECTOR_LEN = 4;

function buildSelectorMap(methods: ReadonlyArray<Arc56Method>): Map<string, Arc56Method> {
  const map = new Map<string, Arc56Method>();
  for (const m of methods) {
    const sig = `${m.name}(${m.args.map((a) => a.type).join(',')})${m.returns.type}`;
    const selectorBuf = new algosdk.ABIMethod({
      name: m.name,
      args: m.args.map((a) => ({ type: a.type, name: a.name ?? '' })),
      returns: { type: m.returns.type },
    }).getSelector();
    const key = Buffer.from(selectorBuf).toString('hex');
    if (map.has(key)) {
      throw new Error(`sealed-abi-decoder: selector collision for ${sig}`);
    }
    map.set(key, { ...m, name: m.name });
    // Store signature alongside via prototype attach — readable by tests.
    Object.defineProperty(map.get(key), '__signature__', {
      value: sig,
      enumerable: false,
    });
  }
  return map;
}

const arc56 = sealedArc56 as unknown as { methods: ReadonlyArray<Arc56Method> };
const selectorMap = buildSelectorMap(arc56.methods);

/** Reverse lookup helper for tests / logging. */
export function selectorHexForMethod(methodName: string): string | null {
  for (const [hex, m] of selectorMap.entries()) {
    if (m.name === methodName) return hex;
  }
  return null;
}

/** All known method names (stable order from arc56). */
export function knownMethodNames(): ReadonlyArray<string> {
  return arc56.methods.map((m) => m.name);
}

export function decodeAbiCall(
  appArgs: ReadonlyArray<Uint8Array> | undefined,
): DecodedAbiCall | null {
  if (!appArgs || appArgs.length === 0) return null;
  const selector = appArgs[0];
  if (selector.length !== SELECTOR_LEN) return null;
  const key = Buffer.from(selector).toString('hex');
  const method = selectorMap.get(key);
  if (!method) return null;
  const sig =
    (method as Arc56Method & { __signature__?: string }).__signature__ ??
    `${method.name}(${method.args.map((a) => a.type).join(',')})${method.returns.type}`;
  return {
    method: method.name,
    signature: sig,
    args: appArgs.slice(1),
    returnType: method.returns.type,
  };
}
