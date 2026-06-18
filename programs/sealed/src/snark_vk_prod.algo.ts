// AUTO-GENERATED from circuits/keys/vk_prod.json by circuits/scripts/gen-vk-bytes.mjs
// DO NOT EDIT. Regenerate with: cd circuits && node scripts/gen-vk-bytes.mjs
// Tag: PROD    Curve: BN254 (bn128)    nPublic: 4
//
// Byte layout (AVM EC opcodes, BN254):
//   G1 = X(32B) || Y(32B)
//   G2 = X0(32B) || X1(32B) || Y0(32B) || Y1(32B)

import { Bytes, bytes, uint64 } from '@algorandfoundation/algorand-typescript'

export const SNARK_VK_TAG = 'PROD' as const

export const VK_ALPHA_1: bytes = Bytes.fromHex('2d4d9aa7e302d9df41749d5507949d05dbea33fbb16c643b22f599a2be6df2e214bedd503c37ceb061d8ec60209fe345ce89830a19230301f076caff004d1926')
export const VK_BETA_2: bytes  = Bytes.fromHex('0e187847ad4c798374d0d6732bf501847dd68bc0e071241e0213bc7fc13db7ab0967032fcbf776d1afc985f88877f182d38480a653f2decaa9794cbc3bf3060c1739c1b1a457a8c7313123d24d2f9192f896b7c63eea05a9d57f06547ad0cec8304cfbd1e08a704a99f5e847d93f8c3caafddec46b7a0d379da69a4d112346a7')
export const VK_GAMMA_2: bytes = Bytes.fromHex('1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c212c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b')
export const VK_DELTA_2: bytes = Bytes.fromHex('15a8bd5f01508ba499eed0127ebd592dcfa60a6abb79a6e5ae2c0048b8a166152ff3fccd7d9ea0dd7f8b5f7532b3d74a058849f899ebf4ef3a5ac0223064fbc010da2b7cc28b9b6ad5b546e776859b6db4286234e3acc1a07cb9c0bde0ace57111e38726da4c53ba31e092ffa323b90a9c5e3ffe0eaa397982ae4aadda382cc2')

// IC[0] is the "free" term; IC[i+1] is multiplied by publicInputs[i].
export const VK_IC_0: bytes = Bytes.fromHex('0c943ef22a1ff74b3aa3d78670d0139db71c00fc560a8e5b77a75c13aff6265720d0043be1518552696eff881f1ec0edc125d2146c35b422e06163ed95a35b2c')
export const VK_IC_1: bytes = Bytes.fromHex('2fa28a87ba71b8348fcf1c7b7f9ca6fe5729f4b59a1e936bdeff6b54ad6c976021e811d075a2901d3284f28a11676576a521b8bc8b388fda9669989a7db19bcc')
export const VK_IC_2: bytes = Bytes.fromHex('219bdfa7324fe5864390d4936a9f25ca90dd2b14626e37a43553aaa25deb548f2994db08d0750e0f9460c575b3d099ac292c895b9f48bf7ac2516d355cc79758')
export const VK_IC_3: bytes = Bytes.fromHex('06df461d63c1a4faf85f599ec4e0d58b5275372e8476cfa02478472e7043fa7f2fd920701d2c251fa3dacfee339a223172d651d3e17db1f0d2c5171038ccbe6c')
export const VK_IC_4: bytes = Bytes.fromHex('1e7468e4fdfbf3f264ba1afaaa1ba394becfa5f6e0903d37f40fa8eac6fc931b01f3083ee29e572b5c7067b01ad4dded675546345b342b0e4ca8fe21693feeac')

export const VK_IC_LEN: uint64 = 5
export const VK_NPUBLIC: uint64 = 4
