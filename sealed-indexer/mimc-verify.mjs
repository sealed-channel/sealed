import algosdk from 'algosdk';
import { mimcBN254, toHex } from '/tmp/mimc-bn254-ref.mjs';

const token = 'a'.repeat(64);
const algod = new algosdk.Algodv2(token, 'http://127.0.0.1', '4001');
const kmd = new algosdk.Kmd(token, 'http://127.0.0.1', '4002');

async function fundedAccount() {
  const { wallets } = await kmd.listWallets();
  const w = wallets.find((x) => x.name === 'unencrypted-default-wallet');
  const init = await kmd.initWalletHandle(w.id, '');
  const h = init.wallet_handle_token;
  const lk = await kmd.listKeys(h);
  const addresses = lk.addresses;
  let best = null, bestBal = -1n;
  for (const a of addresses) {
    const info = await algod.accountInformation(a).do();
    const bal = BigInt(info.amount);
    if (bal > bestBal) { bestBal = bal; best = a; }
  }
  const ek = await kmd.exportKey(h, '', best);
  return { addr: best, sk: ek.private_key };
}

const hexToBytes = (hex) => Uint8Array.from(hex.match(/../g).map((b) => parseInt(b, 16)));

// Build TEAL that pushes the given input bytes, runs mimc, logs the result.
function buildTeal(inputHex) {
  return `#pragma version 11
pushbytes 0x${inputHex}
mimc BN254Mp110
log
int 1
return
`;
}

async function avmHash(acct, inputHex) {
  const teal = buildTeal(inputHex);
  const compiled = await algod.compile(teal).do();
  const program = new Uint8Array(Buffer.from(compiled.result, 'base64'));
  // clear program: trivial approve
  const clearCompiled = await algod.compile('#pragma version 11\nint 1\nreturn\n').do();
  const clearProgram = new Uint8Array(Buffer.from(clearCompiled.result, 'base64'));

  const sp = await algod.getTransactionParams().do();
  const txn = algosdk.makeApplicationCreateTxnFromObject({
    sender: acct.addr,
    suggestedParams: sp,
    onComplete: algosdk.OnApplicationComplete.NoOpOC,
    approvalProgram: program,
    clearProgram,
    numLocalInts: 0, numLocalByteSlices: 0, numGlobalInts: 0, numGlobalByteSlices: 0,
  });
  const signed = txn.signTxn(acct.sk);
  const stxn = algosdk.decodeSignedTransaction(signed);

  const req = new algosdk.modelsv2.SimulateRequest({
    extraOpcodeBudget: 320000,
    txnGroups: [
      new algosdk.modelsv2.SimulateRequestTransactionGroup({
        txns: [stxn],
      }),
    ],
  });
  const res = await algod.simulateTransactions(req).do();
  const grp = res.txnGroups[0];
  if (grp.failureMessage) throw new Error('SIM FAIL: ' + grp.failureMessage);
  const logs = grp.txnResults[0].txnResult.logs || [];
  if (!logs.length) throw new Error('no logs produced');
  return new Uint8Array(logs[0]);
}

async function main() {
  const acct = await fundedAccount();
  console.log('funded sender:', acct.addr, '\n');

  const Z32 = '00'.repeat(32);
  const ONE = '00'.repeat(31) + '01';
  const TWO = '00'.repeat(31) + '02';
  // value near p: p-1
  const P = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
  const pMinus1 = (P - 1n).toString(16).padStart(64, '0');
  // an arbitrary IN-RANGE field element (< p): take deadbeef... reduced mod p.
  const arbRaw = BigInt('0xdeadbeefcafebabe00112233445566778899aabbccddeeff123456789abcdef0');
  const ARB = (arbRaw % P).toString(16).padStart(64, '0');

  const vectors = [
    ['single zero (32B)', Z32],
    ['single one (32B)', ONE],
    ['arbitrary in-range (32B)', ARB],
    ['near p: p-1 (32B)', pMinus1],
    ['two blocks 1||2 (64B)', ONE + TWO],
    ['two blocks arb||p-1 (64B)', ARB + pMinus1],
  ];

  console.log('| vector | input (hex, truncated) | AVM out | JS out | MATCH |');
  console.log('|---|---|---|---|---|');
  let allMatch = true;
  for (const [name, hex] of vectors) {
    const avm = await avmHash(acct, hex);
    const js = mimcBN254(hexToBytes(hex));
    const avmHex = toHex(avm);
    const jsHex = toHex(js);
    const match = avmHex === jsHex;
    if (!match) allMatch = false;
    const inShort = hex.length > 24 ? hex.slice(0, 16) + '..' + hex.slice(-8) : hex;
    console.log(`| ${name} | ${inShort} | ${avmHex} | ${jsHex} | ${match ? 'YES' : '*** NO ***'} |`);
  }
  console.log('\nALL MATCH:', allMatch ? 'YES' : 'NO');
  if (!allMatch) process.exitCode = 1;
}

main().catch((e) => { console.error('FATAL:', e.message); process.exitCode = 2; });
